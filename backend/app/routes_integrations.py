"""Integrations page: external systems (deep-link templates, on/off) and the outbox of writes to systems of record.

While a system is off, an executed decision's outbox entry becomes a MANUAL task (someone enters it by hand from the
deep link) and is closed with "Mark entered". Nothing is ever sent to an external system from here.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from .db import fetch, tx
from .deps import actor
from .routes_collab import _me

r = APIRouter(prefix="/api/integrations", tags=["integrations"])


@r.get("")
def overview(user=Depends(actor)):
    systems = fetch("SELECT code, name, purpose, deep_link_template, api_base_url, enabled FROM external_system ORDER BY code")
    outbox = fetch(
        """SELECT o.message_id, o.idempotency_key AS key, o.system_code AS system, o.action, o.status, o.attempts, o.created_at, o.sent_at,
                  f.flight_no, o.decision_id, o.payload,
                  deep_link(o.system_code, o.flight_id, o.scenario_id) AS link
             FROM integration_outbox o LEFT JOIN flight f ON f.flight_id = o.flight_id
            ORDER BY o.created_at DESC LIMIT 200"""
    )
    return {"systems": systems, "outbox": outbox}


class SystemPatch(BaseModel):
    deep_link_template: str | None = None
    enabled: bool | None = None


@r.patch("/systems/{code}")
def patch_system(code: str, b: SystemPatch, user=Depends(actor)):
    """Configure a deep-link template (placeholders {flight_no} {flight_date} {dep} {arr} {reg} {crew_id}) or switch the write API on."""
    with tx(user) as conn:
        if _me(conn, user)["role_code"] not in ("OCC", "ADMIN"):
            raise HTTPException(403, "Only OCC or admin can change integrations")
        if b.deep_link_template is not None:
            t = b.deep_link_template.strip()
            if not t.startswith(("http://", "https://")):
                raise HTTPException(422, "The template must start with http:// or https://")
            conn.execute("UPDATE external_system SET deep_link_template = %s WHERE code = %s", (t, code))
        if b.enabled is not None:
            conn.execute("UPDATE external_system SET enabled = %s WHERE code = %s", (b.enabled, code))
        row = conn.execute("SELECT code, name, deep_link_template, enabled FROM external_system WHERE code = %s", (code,)).fetchone()
    if not row:
        raise HTTPException(404, "Unknown system")
    return row


@r.post("/outbox/{message_id}/entered")
def mark_entered(message_id: int, user=Depends(actor)):
    """The manual task was done in the system of record (for example the diversion entered in aeroMart)."""
    with tx(user) as conn:
        me = _me(conn, user)
        if me["role_code"] not in ("OCC", "DISPATCH", "CREW_CONTROL", "RECOVERY", "ADMIN"):
            raise HTTPException(403, f"Role {me['role_code']} cannot close integration tasks")
        row = conn.execute(
            "UPDATE integration_outbox SET status = 'ACKED', sent_at = now(), response = %s WHERE message_id = %s AND status IN ('MANUAL','PENDING') RETURNING message_id, idempotency_key AS key, status",
            ('{"entered_manually_by": "%s"}' % me["username"], message_id),
        ).fetchone()
    if not row:
        raise HTTPException(409, "That entry is not waiting for a manual task")
    return row


def settle() -> int:
    """Worker step: entries for a system that is switched off become manual tasks. Entries for an enabled system stay
    PENDING (no connector is shipped; this is the hook where one would send them)."""
    with tx() as conn:
        return conn.execute(
            """UPDATE integration_outbox o SET status = 'MANUAL'
                WHERE o.status = 'PENDING' AND EXISTS (SELECT 1 FROM external_system s WHERE s.code = o.system_code AND NOT s.enabled)"""
        ).rowcount
