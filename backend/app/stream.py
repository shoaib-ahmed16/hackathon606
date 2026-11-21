import asyncio
import json
import secrets
import time

import psycopg
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse

from . import config
from .deps import current_user

r = APIRouter(prefix="/api", tags=["live"])

# EventSource cannot send an Authorization header, and a session token in the URL would end up in access logs and browser history.
# So the browser first asks for a ticket (with its normal header): random, valid for 30 seconds, usable once. Only the ticket goes in the URL.
_TICKETS: dict[str, float] = {}
TICKET_TTL = 30


@r.post("/stream/ticket")
def stream_ticket(uid: int = Depends(current_user)):
    now = time.time()
    for k in [k for k, exp in _TICKETS.items() if exp < now]:  # forget expired ones
        _TICKETS.pop(k, None)
    t = secrets.token_urlsafe(24)
    _TICKETS[t] = now + TICKET_TTL
    return {"ticket": t, "expires_in": TICKET_TTL}


@r.get("/stream")
async def stream(ticket: str):
    """Server-Sent Events: relays the DB's NOTIFY fogops_reassess so the UI can refresh instantly. Needs a one-time ticket."""
    if _TICKETS.pop(ticket, 0) < time.time():
        raise HTTPException(401, "Stream ticket missing, used or expired")

    async def gen():
        async with await psycopg.AsyncConnection.connect(config.DSN, autocommit=True) as conn:
            await conn.execute("LISTEN fogops_reassess")
            await conn.execute("LISTEN fogops_updated")
            await conn.execute("LISTEN fogops_notify")
            yield "event: ready\ndata: {}\n\n"
            notifies = conn.notifies(timeout=15)
            while True:
                got = False
                async for n in notifies:
                    got = True
                    name = {'fogops_updated': 'updated', 'fogops_notify': 'notify'}.get(n.channel, 'reassess')
                    yield f"event: {name}\ndata: {json.dumps({'payload': n.payload})}\n\n"
                if not got:
                    yield ": keep-alive\n\n"  # keeps proxies from closing an idle stream
                notifies = conn.notifies(timeout=15)
                await asyncio.sleep(0)

    return StreamingResponse(gen(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
