"""Audit of every user action. Two layers:
  * the database already audits every table change (who changed what: decisions, comments, cases ...);
  * this module records the ACTIONS themselves in the same append-only audit_log: every API call that does
    something (POST/PATCH/DELETE, Ask questions, logins, refused attempts included), with who, when, what and the outcome.
"""
import asyncio
import json
import time

from . import auth
from .db import pool

SENSITIVE = {"password", "token", "authorization"}
MAX_BODY = 2000


def _redact(obj):
    if isinstance(obj, dict):
        return {k: ("***" if k.lower() in SENSITIVE else _redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_redact(v) for v in obj[:50]]
    return obj


def write(user_id, action, entity_type, entity_id, detail, scenario_id=None, case_id=None):
    """Insert one audit row. Never raises: auditing must not break the action it records."""
    try:
        with pool.connection() as conn:
            role = None
            if user_id is not None:
                row = conn.execute("SELECT role_code FROM fogops.app_user WHERE user_id = %s", (user_id,)).fetchone()
                role = row["role_code"] if row else None
            conn.execute(
                """INSERT INTO fogops.audit_log (scenario_time_utc, actor_user_id, actor_role, scenario_id, case_id,
                          entity_type, entity_id, action, after_data)
                   VALUES (CASE WHEN %s::int IS NULL THEN NULL ELSE fogops.scenario_stamp(%s::int) END, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)""",
                (scenario_id, scenario_id, user_id, role, scenario_id, case_id, entity_type, str(entity_id)[:200], action, json.dumps(detail, default=str)),
            )
    except Exception:  # noqa: BLE001
        pass


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


class AuditMiddleware:
    """Pure ASGI (so streaming responses such as the event stream are untouched). Records every state-changing
    API call after it ran: who, what, with which parameters, and the outcome, refusals included."""

    METHODS = ("POST", "PATCH", "PUT", "DELETE")

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in self.METHODS or not scope["path"].startswith("/api/"):
            return await self.app(scope, receive, send)

        body, more = b"", True
        while more:  # read the request body once, then replay it to the endpoint
            msg = await receive()
            if msg["type"] != "http.request":
                break
            body += msg.get("body", b"")
            more = msg.get("more_body", False)
        replayed = False

        async def replay():
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        status = {"code": 0}
        out = bytearray()
        is_login = scope["path"] == "/api/auth/login"

        async def send_wrap(m):
            if m["type"] == "http.response.start":
                status["code"] = m["status"]
            elif m["type"] == "http.response.body" and is_login and len(out) < 4000:
                out.extend(m.get("body", b""))  # only to learn WHO signed in
            await send(m)

        started = time.perf_counter()
        await self.app(scope, replay, send_wrap)

        try:
            from urllib.parse import parse_qsl

            headers = {k.decode().lower(): v.decode() for k, v in scope["headers"]}
            query = dict(parse_qsl(scope.get("query_string", b"").decode()))
            tok = headers.get("authorization", "")[7:] if headers.get("authorization", "").lower().startswith("bearer ") else query.get("token")
            uid = auth.read_token(tok) if tok else None
            if is_login and status["code"] == 200:
                try:
                    uid = json.loads(bytes(out))["user"]["user_id"]
                except (ValueError, KeyError, TypeError):
                    pass
            try:
                parsed = json.loads(body) if body else None
            except ValueError:
                parsed = None
            parsed = _redact(parsed) if isinstance(parsed, (dict, list)) else None
            b = parsed if isinstance(parsed, dict) else {}
            text = json.dumps(parsed, default=str) if parsed else ""
            path = scope["path"]
            detail = {
                "method": scope["method"], "path": path, "query": {k: v for k, v in query.items() if k != "token"},
                "status": status["code"], "ok": status["code"] < 400, "ms": round((time.perf_counter() - started) * 1000),
                "body": ({"username": b.get("username")} if path == "/api/auth/login" else (parsed if len(text) <= MAX_BODY else text[:MAX_BODY])) if parsed else None,
            }
            await asyncio.to_thread(write, uid, scope["method"], "api", path, detail, _int(query.get("scenario_id") or b.get("scenario_id")), _int(query.get("case_id") or b.get("case_id")))
        except Exception:  # noqa: BLE001 - auditing must never break the request
            pass
