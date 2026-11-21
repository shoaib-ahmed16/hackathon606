"""Small self-contained login: PBKDF2 password hashes in fogops.app_credential + HMAC-signed tokens.
No extra dependencies. Set AUTH_SECRET in production (tokens are signed with it)."""
import base64
import hashlib
import hmac
import json
import os
import time

from . import config


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def hash_password(pw: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 200_000)
    return f"pbkdf2${salt.hex()}${dk.hex()}"


def verify_password(pw: str, stored: str) -> bool:
    try:
        _, salt, dk = stored.split("$")
        got = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), 200_000)
        return hmac.compare_digest(got.hex(), dk)
    except ValueError:
        return False


def make_token(user_id: int) -> str:
    body = _b64(json.dumps({"uid": user_id, "exp": int(time.time()) + config.TOKEN_TTL_SEC}).encode())
    sig = _b64(hmac.new(config.AUTH_SECRET.encode(), body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"


def read_token(token: str) -> int | None:
    """Returns the user id, or None when the token is malformed, tampered with or expired."""
    try:
        body, sig = token.split(".")
        want = _b64(hmac.new(config.AUTH_SECRET.encode(), body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, want):
            return None
        data = json.loads(_unb64(body))
        return int(data["uid"]) if data["exp"] > time.time() else None
    except (ValueError, KeyError, TypeError):
        return None
