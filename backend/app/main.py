from contextlib import asynccontextmanager

import psycopg
from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

import asyncio
import logging

from . import audit, auth, config, migrate, routes_ask, routes_audit, routes_auth, routes_collab, routes_console, routes_feed, routes_explorer, routes_integrations, routes_read, routes_rules, routes_write, stream, worker
from .deps import current_user
from .db import fetch, pool


def _ensure_credentials():
    """Create the credential table and give every user without one the demo password."""
    with pool.connection() as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS fogops.app_credential (user_id INT PRIMARY KEY REFERENCES fogops.app_user, "
            "password_hash TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now())"
        )
        missing = conn.execute(
            "SELECT user_id FROM fogops.app_user WHERE user_id NOT IN (SELECT user_id FROM fogops.app_credential)"
        ).fetchall()
        for row in missing:
            conn.execute("INSERT INTO fogops.app_credential (user_id, password_hash) VALUES (%s, %s)", (row["user_id"], auth.hash_password(config.DEMO_PASSWORD)))


@asynccontextmanager
async def lifespan(_):
    try:
        res = migrate.run()  # apply pending backend/migrations/*.sql; no dump/restore needed for schema or logic changes
        logging.getLogger("fogops").info("migrations: applied=%s current=%s", res["applied"], res["current"])
    except Exception:
        logging.getLogger("fogops").exception("MIGRATION FAILED: the database was left at its previous level")
    pool.open()
    _ensure_credentials()
    if health()["schema"] != "current":
        logging.getLogger("fogops").error("DATABASE SCHEMA IS OUTDATED: %s", config.DSN.rsplit("@", 1)[-1])
    task = asyncio.create_task(worker.run()) if config.WORKER_ENABLED else None
    yield
    if task:
        task.cancel()
    pool.close()


app = FastAPI(title="FOOH! API", description="FOOH!: disruption control for airline operations (fog operations and crew duty recovery)", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=config.CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"])
app.add_middleware(audit.AuditMiddleware)
app.include_router(routes_auth.r)  # login is open; everything else needs a signed-in user
app.include_router(routes_read.r, dependencies=[Depends(current_user)])
app.include_router(routes_audit.r, dependencies=[Depends(current_user)])
app.include_router(routes_console.r, dependencies=[Depends(current_user)])
app.include_router(routes_ask.r, dependencies=[Depends(current_user)])
app.include_router(routes_integrations.r)  # integrations page (actor())
app.include_router(routes_rules.r)  # custom rules (actor())
app.include_router(routes_collab.r)  # KPIs, approvals, subscriptions, data requests (actor())
app.include_router(routes_explorer.r)  # data explorer (OCC/ADMIN only, read-only)
app.include_router(routes_feed.r)  # simulated live feed push (resolves the user through actor())
app.include_router(routes_write.r)  # actions resolve the user through actor()
app.include_router(stream.r, dependencies=[Depends(current_user)])


@app.get("/health", tags=["ops"])
def health():
    """UP + whether the database has the current schema (hold/divert engine and LVP columns)."""
    ok = bool(fetch("SELECT 1 AS ok"))
    current = fetch(
        "SELECT to_regproc('fogops.propose_hold_or_divert') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns "
        "WHERE table_schema='fogops' AND table_name='airport_status_event' AND column_name='lvp_in_force') AS ok"
    )[0]["ok"]
    try:
        level = fetch("SELECT max(version) AS v FROM fogops.schema_migration")[0]["v"]
    except psycopg.Error:
        level = None
    return {"status": "UP", "db": ok, "schema": "current" if current else "OUTDATED: rebuild the database from fogops_db", "migration": level}


@app.exception_handler(psycopg.Error)
async def db_error(_: Request, e: psycopg.Error):
    """Turn database guardrails and constraint failures into readable API errors."""
    msg = (e.diag.message_primary if getattr(e, "diag", None) else None) or str(e)
    if isinstance(e, psycopg.errors.RaiseException):  # raised by our triggers/functions
        code = 403 if msg.startswith("Guardrail") or "not authorised" in msg or "human" in msg.lower() else 409
    elif isinstance(e, (psycopg.errors.IntegrityError, psycopg.errors.DataError)):
        code = 422
    else:
        code = 500
    return JSONResponse(status_code=code, content={"detail": msg})
