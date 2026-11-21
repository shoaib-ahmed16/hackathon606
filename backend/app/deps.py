from fastapi import Header, HTTPException, Request

from . import auth, config  # noqa: F401
from .db import fetch


def current_user(request: Request, authorization: str | None = Header(default=None)) -> int:
    """Signed-in app_user id, from the Authorization: Bearer header only. A token in the URL would land in access logs and browser
    history, so it is not accepted (the live stream uses a short-lived one-time ticket instead, see stream.py)."""
    raw = authorization[7:] if authorization and authorization.lower().startswith("bearer ") else None
    uid = auth.read_token(raw) if raw else None
    if uid is None:
        raise HTTPException(401, "Sign in required")
    return uid


def actor(request: Request, authorization: str | None = Header(default=None)) -> str:
    """Same as current_user, as text for fogops.set_actor() (audit + role guardrails see this human)."""
    return str(current_user(request, authorization))


def user_row(uid: int):
    rows = fetch("SELECT user_id, username, display_name, role_code FROM app_user WHERE user_id = %s AND is_active", (uid,))
    return rows[0] if rows else None
