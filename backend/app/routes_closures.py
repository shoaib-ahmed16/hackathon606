"""Closure sets: reusable lists of station closures that can be applied to many simulation scenarios.

A set is only a template. Applying it writes ordinary airport_status_event rows (quality SIMULATED) into each target scenario, so the engine,
views and worker are untouched. LIVE is refused: a closure on the live picture is a person's real input, and status events are never deleted.
Writes are OCC/ADMIN only and go through tx(user) so set_actor, audit triggers and role guardrails see the human.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .db import fetch, tx
from .deps import actor
from .routes_write import _require_role, agent_user_id

r = APIRouter(prefix="/api/closure-sets", tags=["closure-sets"])


class Item(BaseModel):
    iata: str = Field(min_length=3, max_length=3)
    op_status: str
    reopen_after_min: int | None = Field(default=None, ge=0)
    parking_available: int | None = Field(default=None, ge=0)
    reason: str | None = None


class SetBody(BaseModel):
    name: str
    description: str | None = None
    items: list[Item]


class ApplyBody(BaseModel):
    scenario_ids: list[int]


def _clean(b: SetBody) -> list[Item]:
    if not b.name.strip():
        raise HTTPException(422, "A closure set needs a name")
    if not b.items:
        raise HTTPException(422, "A closure set needs at least one station")
    seen = set()
    for it in b.items:
        it.iata = it.iata.upper()
        if it.op_status not in ("OPEN", "RESTRICTED", "CLOSED"):
            raise HTTPException(422, f"{it.iata}: status must be OPEN, RESTRICTED or CLOSED")
        if it.iata in seen:
            raise HTTPException(422, f"{it.iata} appears twice in the set")
        seen.add(it.iata)
    return b.items


def _check_airports(conn, items):
    known = {x["iata"].strip() for x in conn.execute("SELECT iata FROM airport WHERE iata = ANY(%s)", ([i.iata for i in items],)).fetchall()}
    missing = [i.iata for i in items if i.iata not in known]
    if missing:
        raise HTTPException(422, f"Unknown airport: {', '.join(missing)}")


def _insert_items(conn, set_id, items):
    for it in items:
        conn.execute(
            """INSERT INTO closure_set_item (set_id, iata, op_status, reopen_after_min, parking_available, reason)
               VALUES (%s,%s,%s,%s,%s,%s)""",
            (set_id, it.iata, it.op_status, it.reopen_after_min, it.parking_available, it.reason),
        )


def _with_items(rows):
    ids = [x["set_id"] for x in rows]
    items = fetch("SELECT * FROM closure_set_item WHERE set_id = ANY(%s) ORDER BY set_id, iata", (ids,)) if ids else []
    for x in rows:
        x["items"] = [i for i in items if i["set_id"] == x["set_id"]]
    return rows


@r.get("")
def list_sets():
    rows = fetch(
        """SELECT s.*, (SELECT count(*) FROM closure_set_application a WHERE a.set_id = s.set_id) AS applications
             FROM closure_set s ORDER BY s.name"""
    )
    return _with_items(rows)


@r.get("/applications")
def applications(scenario_id: int | None = None):
    """Which sets were applied to which scenario, newest first (optionally for one scenario)."""
    return fetch(
        """SELECT a.*, s.name AS set_name FROM closure_set_application a JOIN closure_set s USING (set_id)
            WHERE (%s::int IS NULL OR a.scenario_id = %s) ORDER BY a.applied_at DESC LIMIT 200""",
        (scenario_id, scenario_id),
    )


@r.post("")
def create_set(b: SetBody, user=Depends(actor)):
    items = _clean(b)
    with tx(user) as conn:
        _require_role(conn, user)
        _check_airports(conn, items)
        if conn.execute("SELECT 1 FROM closure_set WHERE name = %s", (b.name.strip(),)).fetchone():
            raise HTTPException(409, "A closure set with this name already exists")
        row = conn.execute(
            "INSERT INTO closure_set (name, description, created_by) VALUES (%s,%s,%s) RETURNING *",
            (b.name.strip(), b.description, int(user)),
        ).fetchone()
        _insert_items(conn, row["set_id"], items)
    return _with_items([row])[0]


@r.patch("/{set_id}")
def replace_set(set_id: int, b: SetBody, user=Depends(actor)):
    """Replace name, description and all stations of a set. Scenarios it was already applied to keep what was written then."""
    items = _clean(b)
    with tx(user) as conn:
        _require_role(conn, user)
        _check_airports(conn, items)
        if not conn.execute("SELECT 1 FROM closure_set WHERE set_id = %s", (set_id,)).fetchone():
            raise HTTPException(404, "Unknown closure set")
        if conn.execute("SELECT 1 FROM closure_set WHERE name = %s AND set_id <> %s", (b.name.strip(), set_id)).fetchone():
            raise HTTPException(409, "A closure set with this name already exists")
        row = conn.execute(
            "UPDATE closure_set SET name = %s, description = %s WHERE set_id = %s RETURNING *", (b.name.strip(), b.description, set_id)
        ).fetchone()
        conn.execute("DELETE FROM closure_set_item WHERE set_id = %s", (set_id,))
        _insert_items(conn, set_id, items)
    return _with_items([row])[0]


@r.delete("/{set_id}")
def delete_set(set_id: int, user=Depends(actor)):
    with tx(user) as conn:
        _require_role(conn, user)
        if conn.execute("SELECT 1 FROM closure_set_application WHERE set_id = %s", (set_id,)).fetchone():
            raise HTTPException(409, "This set was already applied to a simulation and is kept for the audit trail")
        n = conn.execute("DELETE FROM closure_set WHERE set_id = %s", (set_id,)).rowcount
        if not n:
            raise HTTPException(404, "Unknown closure set")
    return {"deleted": set_id}


def write_set(conn, set_id: int, scenario_id: int, user) -> int:
    """Write one SIMULATED airport_status_event per station of the set into `scenario_id` (inside the caller's transaction).
    Used by the apply endpoint and, when a case is created with a set, by case creation. Never called for a LIVE scenario."""
    stamp = conn.execute("SELECT scenario_now(%s) AS ts", (scenario_id,)).fetchone()["ts"]
    items = conn.execute("SELECT * FROM closure_set_item WHERE set_id = %s ORDER BY iata", (set_id,)).fetchall()
    name = conn.execute("SELECT name FROM closure_set WHERE set_id = %s", (set_id,)).fetchone()["name"]
    for it in items:
        closed = it["op_status"] == "CLOSED"
        conn.execute(
            """INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, lvp_in_force, arrival_capacity_per_hr, parking_available,
                      weather_above_minima, handling_ok, fuel_ok, effective_from_utc, expected_reopen_utc, quality, entered_by, note)
               VALUES (%s,%s,%s,%s,FALSE,%s,%s,%s,%s,%s,%s,%s + make_interval(mins => %s),'SIMULATED',%s,%s)""",
            (scenario_id, it["iata"], it["op_status"], it["reason"] or ("Closed (simulated)" if closed else None),
             0 if closed else None, it["parking_available"],
             None if closed else True, None if closed else True, None if closed else True,
             stamp, stamp, it["reopen_after_min"] if it["reopen_after_min"] is not None else None, int(user),
             f"Closure set: {name}"),
        )
    conn.execute("INSERT INTO closure_set_application (set_id, scenario_id, applied_by, items_written) VALUES (%s,%s,%s,%s)",
                 (set_id, scenario_id, int(user), len(items)))
    return len(items)


def rerun_recommendations(scenario_id: int) -> int:
    """First recommendations for the watched flights of every case in the scenario, written by the non-human agent."""
    n = 0
    with tx(agent_user_id()) as conn:
        rows = conn.execute(
            """SELECT dc.case_id, cf.flight_id FROM disruption_case dc JOIN case_flight cf ON cf.case_id = dc.case_id
                WHERE dc.scenario_id = %s""", (scenario_id,)).fetchall()
        for row in rows:
            with conn.transaction():
                conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (scenario_id, row["case_id"], row["flight_id"]))
                n += 1
    return n


@r.post("/{set_id}/apply")
def apply_set(set_id: int, b: ApplyBody, user=Depends(actor)):
    """Apply one set to one or many simulation scenarios. All-or-nothing validation first (unknown or LIVE scenario refuses the whole call),
    then one transaction per scenario and a recommendation re-run for the watched flights."""
    ids = list(dict.fromkeys(b.scenario_ids))
    if not ids:
        raise HTTPException(422, "Pick at least one simulation")
    with tx(user) as conn:
        _require_role(conn, user)
        if not conn.execute("SELECT 1 FROM closure_set_item WHERE set_id = %s LIMIT 1", (set_id,)).fetchone():
            raise HTTPException(404, "Unknown or empty closure set")
        kinds = {x["scenario_id"]: x["kind"] for x in conn.execute("SELECT scenario_id, kind FROM scenario WHERE scenario_id = ANY(%s)", (ids,)).fetchall()}
    unknown = [i for i in ids if i not in kinds]
    if unknown:
        raise HTTPException(404, f"Unknown scenario: {', '.join(map(str, unknown))}")
    live = [i for i in ids if kinds[i] == "LIVE"]
    if live:
        raise HTTPException(409, "A closure set cannot be applied to the live scenario: closures there stay a person's real input. Use a simulation.")
    results = []
    for sid in ids:
        with tx(user) as conn:
            written = write_set(conn, set_id, sid, user)
        results.append({"scenario_id": sid, "stations": written, "recommendations": rerun_recommendations(sid)})
    return {"set_id": set_id, "applied": results}
