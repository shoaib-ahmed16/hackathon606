from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from . import auth
from .db import fetch
from .deps import current_user, user_row

r = APIRouter(prefix="/api", tags=["auth"])


class Login(BaseModel):
    username: str
    password: str


@r.post("/auth/login")
def login(b: Login):
    rows = fetch(
        """SELECT u.user_id, u.username, u.display_name, u.role_code, c.password_hash
             FROM app_user u JOIN app_credential c USING (user_id)
            WHERE lower(u.username) = lower(%s) AND u.is_active""",
        (b.username.strip(),),
    )
    if not rows or not auth.verify_password(b.password, rows[0]["password_hash"]):
        raise HTTPException(401, "Invalid username or password")
    u = rows[0]
    if u["role_code"] == "AGENT":  # the decision-support agent is a non-human role: no interactive login
        raise HTTPException(403, "The agent account cannot sign in interactively")
    return {"token": auth.make_token(u["user_id"]), "user": {k: u[k] for k in ("user_id", "username", "display_name", "role_code")}}


@r.get("/me")
def me(uid: int = Depends(current_user)):
    u = user_row(uid)
    if not u:
        raise HTTPException(401, "Unknown user")
    return u


@r.post("/auth/logout")
def logout(uid: int = Depends(current_user)):
    """Tokens are stateless; this exists so signing out is recorded in the audit trail."""
    return {"ok": True}
