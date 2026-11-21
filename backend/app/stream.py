import asyncio
import json

import psycopg
from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from . import config

r = APIRouter(prefix="/api", tags=["live"])


@r.get("/stream")
async def stream():
    """Server-Sent Events: relays the DB's NOTIFY fogops_reassess so the UI can refresh instantly."""

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
