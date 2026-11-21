"""Forward-only SQL migrations, applied automatically when the API starts.

Why: the database is restored once from backend/db/init/10_fogops.sql.gz. Every later schema or logic
change lives in backend/migrations/NNN_name.sql and is applied here, so nobody has to dump and restore
the database again. A fresh volume (restored dump) and an existing volume both end up at the same level.

Rules
  - Files are applied in filename order, each in its own transaction, once. Applied files are recorded in
    fogops.schema_migration with a checksum.
  - Never edit a migration that has been applied anywhere: add a new file instead. An edited file is
    reported (checksum mismatch) and is NOT re-applied.
  - Write migrations idempotently where practical (IF NOT EXISTS, CREATE OR REPLACE) because the dump
    already contains objects older than this mechanism.
  - A pg advisory lock stops two API instances from migrating at the same time.
"""
import hashlib
import logging
import pathlib

import psycopg

from . import config

log = logging.getLogger("fogops.migrate")
MIGRATIONS_DIR = pathlib.Path(__file__).resolve().parent.parent / "migrations"
LOCK_KEY = 606_001  # arbitrary, app-wide


def _checksum(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def run() -> dict:
    """Apply pending migrations. Returns {"applied": [...], "mismatched": [...], "current": "<last file>"}."""
    files = sorted(MIGRATIONS_DIR.glob("[0-9][0-9][0-9]_*.sql"))
    applied, mismatched = [], []
    with psycopg.connect(config.DSN, autocommit=True) as conn:
        conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_KEY,))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS fogops.schema_migration ("
                " version TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"
            )
            done = {r[0]: r[1] for r in conn.execute("SELECT version, checksum FROM fogops.schema_migration")}
            for f in files:
                sql = f.read_text()
                if f.name in done:
                    if done[f.name] != _checksum(sql):
                        mismatched.append(f.name)
                        log.error("migration %s was edited after it was applied; add a new file instead", f.name)
                    continue
                with conn.transaction():
                    conn.execute("SET LOCAL search_path = fogops, hist, public")
                    conn.execute(sql)
                    conn.execute("INSERT INTO fogops.schema_migration (version, checksum) VALUES (%s, %s)", (f.name, _checksum(sql)))
                applied.append(f.name)
                log.info("applied migration %s", f.name)
            last = conn.execute("SELECT max(version) FROM fogops.schema_migration").fetchone()[0]
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_KEY,))
    return {"applied": applied, "mismatched": mismatched, "current": last}
