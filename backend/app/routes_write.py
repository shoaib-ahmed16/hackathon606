from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from .db import fetch, live_scenario_id, tx
from .deps import actor

r = APIRouter(prefix="/api", tags=["actions"])


def call(user, fn, *args):
    """Run one DB function as `user` (set_actor first, so audit + role guardrails see the human)."""
    marks = ",".join(["%s"] * len(args))
    with tx(user) as conn:
        return conn.execute(f"SELECT * FROM {fn}({marks})", args).fetchall()


class FlightEvent(BaseModel):
    scenario_id: int | None = None
    source: str = "SIM_FEED"
    message_id: str
    flight_id: int
    event_type: str
    event_ts: datetime
    payload: dict[str, Any] = {}
    seq_no: int | None = None


@r.post("/events/flight")
def flight_event(b: FlightEvent, user=Depends(actor)):
    """Feed message in -> flight state out (dedupe, out-of-order guard and status derivation happen in the DB)."""
    return call(user, "ingest_flight_event", b.scenario_id or live_scenario_id(), b.source, b.message_id, b.flight_id, b.event_type, b.event_ts, Jsonb(b.payload), b.seq_no)


@r.post("/decisions/{decision_id}/execute-diversion")
def execute_diversion(decision_id: int, turnaround_min: int | None = None, user=Depends(actor)):
    """Creates the recovery leg + diversion record and recomputes affected crew legality."""
    return call(user, "execute_diversion", decision_id, turnaround_min)


class Swap(BaseModel):
    scenario_id: int | None = None
    case_id: int | None = None
    duty_id: int
    out_crew_id: int
    in_crew_id: int
    reason: str
    sign_in_utc: datetime | None = None
    report_station: str | None = None
    from_leg_seq: int = 1
    standby_id: int | None = None
    positioning_min: int | None = None
    decision_id: int | None = None  # an APPROVED CREW_REPLACE decision; it is marked EXECUTED


@r.post("/crew/swap")
def swap(b: Swap, user=Depends(actor)):
    """Closes one assignment and opens another (history kept), records the replacement and executes the decision."""
    scn_id = b.scenario_id or live_scenario_id()
    with tx(user) as conn:
        if b.decision_id:
            d = conn.execute("SELECT status, decision_type FROM decision WHERE decision_id = %s", (b.decision_id,)).fetchone()
            if not d or d["status"] != "APPROVED" or d["decision_type"] != "CREW_REPLACE":
                raise HTTPException(409, "The swap needs an APPROVED CREW_REPLACE decision first")
        conn.execute("SELECT swap_crew(%s,%s,%s,%s,%s,%s,%s,%s,'REPLACEMENT')", (scn_id, b.duty_id, b.out_crew_id, b.in_crew_id, b.reason, b.sign_in_utc, b.report_station, b.from_leg_seq))
        if b.case_id:
            conn.execute(
                """INSERT INTO crew_replacement (scenario_id, case_id, duty_id, outgoing_crew_id, incoming_crew_id, standby_id,
                          positioning_from_iata, positioning_to_iata, positioning_mode, positioning_min, new_sign_in_utc, decision_id, status)
                   VALUES (%s,%s,%s,%s,%s,%s,'SHJ',%s,'ROAD',%s,%s,%s,'APPROVED')""",
                (scn_id, b.case_id, b.duty_id, b.out_crew_id, b.in_crew_id, b.standby_id, b.report_station, b.positioning_min, b.sign_in_utc, b.decision_id),
            )
        if b.decision_id:
            conn.execute("UPDATE decision SET status = 'EXECUTED' WHERE decision_id = %s", (b.decision_id,))
    return {"ok": True}


def agent_user_id():
    rows = fetch("SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1")
    if not rows:
        raise HTTPException(500, "No agent user configured")
    return str(rows[0]["user_id"])


@r.post("/flights/{flight_id}/recommend")
def recommend(flight_id: int, case_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """Re-run the hold/divert engine. The engine is a non-human AGENT: it writes the recommendation, never a decision."""
    s = scenario_id or live_scenario_id()
    with tx(agent_user_id()) as conn:
        conn.execute("SELECT compute_flight_legality(%s,%s,'ui')", (s, flight_id))
        return conn.execute("SELECT recommend_for_flight(%s,%s,%s) AS rec_id", (s, case_id, flight_id)).fetchall()


CHECKLIST_ROLES = {"flight_plan_filed": ("DISPATCH", "OCC", "ADMIN"), "load_sheet_ready": ("STATION", "OCC", "ADMIN")}  # who may tick each paperwork item
DIVERSION_FIELDS = {"flight_plan_filed", "load_sheet_ready", "status", "refuel_status", "handling_status", "waiting_for", "pax_onboard", "landed_alt_utc", "on_blocks_alt_utc", "planned_departure_utc", "actual_departure_utc", "turnaround_min_assumed"}


@r.patch("/diversions/{diversion_id}")
def update_diversion(diversion_id: int, body: dict[str, Any], user=Depends(actor)):
    """Station update at the alternate (landed, refuelled, waiting for ...). Audited; feeds 'what is it waiting for'."""
    bad = set(body) - DIVERSION_FIELDS
    if bad or not body:
        raise HTTPException(422, f"Unknown or empty fields: {sorted(bad)}")
    body = dict(body)
    paperwork = {k: bool(body.pop(k)) for k in list(CHECKLIST_ROLES) if k in body}   # flight plan filed / load sheet ready: tick or untick, who + when kept
    with tx(user) as conn:
        if paperwork:
            role = conn.execute("SELECT role_code FROM app_user WHERE user_id = %s", (int(user),)).fetchone()["role_code"]
            for k in paperwork:
                if role not in CHECKLIST_ROLES[k]:
                    raise HTTPException(403, f"Only {' or '.join(CHECKLIST_ROLES[k])} can {'file the flight plan' if k == 'flight_plan_filed' else 'mark the load sheet ready'}")
        parts, vals = [f"{k} = %s" for k in body], list(body.values())
        for k, on in paperwork.items():
            col = "flight_plan_filed" if k == "flight_plan_filed" else "load_sheet_ready"
            parts += [f"{col}_at = {'scenario_stamp(scenario_id)' if on else 'NULL'}", f"{col}_by = %s"]
            vals.append(int(user) if on else None)
        rows = conn.execute(f"UPDATE diversion SET {', '.join(parts)}, updated_by = %s, updated_at = now() WHERE diversion_id = %s RETURNING *", [*vals, int(user), diversion_id]).fetchall()
        if rows and any(paperwork.values()):
            # an OPEN "ask for the flight plan / load sheet" is answered by ticking the item itself
            fields = [f for k, f in (("flight_plan_filed", "FLIGHT_PLAN"), ("load_sheet_ready", "LOAD_SHEET")) if paperwork.get(k)]
            conn.execute(
                """UPDATE data_request SET status = 'ANSWERED', answer = %s, answered_by = %s, answered_at = now()
                    WHERE scenario_id = %s AND flight_id = %s AND field = ANY(%s) AND status = 'OPEN'""",
                (Jsonb({"value": "done", "applied_to": "diversion"}), int(user), rows[0]["scenario_id"], rows[0]["original_flight_id"], fields))
    if not rows:
        raise HTTPException(404, "Unknown diversion")
    return rows


@r.post("/flights/{flight_id}/recompute")
def recompute(flight_id: int, scenario_id: int | None = None, buffer_min: int = 30, user=Depends(actor)):
    """Recompute legality and latest departure (new rows; history is kept, never overwritten)."""
    s = scenario_id or live_scenario_id()
    return {"legality": call(user, "compute_flight_legality", s, flight_id), "latest_departure": call(user, "compute_latest_departure", s, flight_id, buffer_min)}


class Recovery(BaseModel):
    scenario_id: int | None = None
    case_id: int
    window_min: int = 60
    weights: dict[str, float] | None = None


@r.post("/recovery/build")
def build_recovery(b: Recovery, user=Depends(actor)):
    w = Jsonb(b.weights) if b.weights else Jsonb({"fuel": 0.40, "crew": 0.30, "rotation": 0.15, "pax": 0.15})
    return call(user, "build_recovery_plan", b.scenario_id or live_scenario_id(), b.case_id, b.window_min, w)


@r.post("/cases/{case_id}/report")
def report(case_id: int, user=Depends(actor)):
    return call(user, "generate_report", case_id, int(user))


class Clone(BaseModel):
    source_scenario_id: int | None = None
    name: str
    kind: str = "WHATIF"
    overrides: dict[str, Any] = {}


@r.post("/scenarios/clone")
def clone(b: Clone, user=Depends(actor)):
    """What-if: isolated copy of flight state, crew and calculations."""
    return call(user, "clone_scenario", b.source_scenario_id or live_scenario_id(), b.name, b.kind, Jsonb(b.overrides))


# Human workflow rows are plain INSERTs; guardrail triggers enforce roles and status transitions.
# Only these tables are writable, and columns are checked against the real table definition.
# Only what the screens write through here, and only for the roles that do it (the database guardrails still apply on top).
# Recommendations, cases and watch lists are NOT writable from outside: the engine and the dedicated endpoints own them.
HUMANS = {"OCC", "DISPATCH", "CREW_CONTROL", "STATION", "RECOVERY", "ADMIN"}
WRITABLE = {
    "decision": HUMANS - {"STATION"},
    "case_comment": HUMANS,
    "airport_status_event": HUMANS,
    "flight_fuel_estimate": HUMANS - {"STATION"},
    "crew_replacement": {"OCC", "CREW_CONTROL", "ADMIN"},
}


@r.post("/records/{table}")
def insert_record(table: str, body: dict[str, Any], user=Depends(actor)):
    if table not in WRITABLE:
        raise HTTPException(404, f"Table not writable: {table}")
    with tx(user) as conn:
        _require_role(conn, user, tuple(sorted(WRITABLE[table])))
        cols = {c["column_name"] for c in conn.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='fogops' AND table_name=%s", (table,)).fetchall()}
        bad = set(body) - cols
        if bad or not body:
            raise HTTPException(422, f"Unknown or empty columns: {sorted(bad)}")
        names = ",".join(f'"{k}"' for k in body)
        marks = ",".join(["%s"] * len(body))
        vals = [Jsonb(v) if isinstance(v, (dict, list)) else v for v in body.values()]
        return conn.execute(f"INSERT INTO fogops.{table} ({names}) VALUES ({marks}) RETURNING *", vals).fetchall()


class NewCase(BaseModel):
    scenario_id: int | None = None
    title: str
    hub_iata: str = "SHJ"
    from_utc: datetime
    to_utc: datetime
    cause: str = "FOG"
    simulate_fog: bool = False  # adds a clearly-labelled SIMULATED fog status so recommendations have something to react to
    reopen_after_min: int = 120


@r.post("/cases/create")
def create_case(b: NewCase, user=Depends(actor)):
    """New disruption case whose watch list is every flight arriving at the hub inside the window (real flights, real crew)."""
    scn_id = b.scenario_id or live_scenario_id()
    hub = b.hub_iata.upper()
    if b.to_utc <= b.from_utc:
        raise HTTPException(422, "The window must end after it starts")
    with tx(user) as conn:
        # Simulated fog is written at SCENARIO level and airport status can never be deleted, so on the LIVE picture
        # it would leak into every other LIVE case. Run it in its own what-if copy instead.
        src = conn.execute("SELECT kind FROM scenario WHERE scenario_id = %s", (scn_id,)).fetchone()
        if not src:
            raise HTTPException(404, "Unknown scenario")
        if b.simulate_fog and src["kind"] == "LIVE":
            scn_id = conn.execute("SELECT clone_scenario(%s, %s, 'WHATIF') AS id", (scn_id, f"WHATIF {b.title.strip() or hub} {datetime.utcnow():%d%b %H:%M:%S}")).fetchone()["id"]
        case = conn.execute(
            "INSERT INTO disruption_case (scenario_id, title, hub_iata, cause, phase, opened_by) VALUES (%s,%s,%s,%s,'MONITORING',%s) RETURNING *",
            (scn_id, b.title.strip(), hub, b.cause, int(user)),
        ).fetchone()
        n = conn.execute(
            """INSERT INTO case_flight (case_id, flight_id, fog_exposure)
               SELECT %s, f.flight_id, %s FROM flight f
                WHERE f.arr_iata = %s AND f.flight_kind = 'SCHEDULED' AND f.sta_utc >= %s AND f.sta_utc < %s""",
            (case["case_id"], "HIGH" if b.simulate_fog else "NONE", hub, b.from_utc, b.to_utc),
        ).rowcount
        if n == 0:
            raise HTTPException(422, f"No scheduled flights arrive at {hub} in that window")
        if b.simulate_fog:
            stamp = conn.execute("SELECT scenario_now(%s) AS ts", (scn_id,)).fetchone()["ts"]
            conn.execute(
                """INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
                          effective_from_utc, expected_reopen_utc, quality, entered_by, note)
                   VALUES (%s,%s,'CLOSED','FOG (simulated)',50,TRUE,0,%s,%s + make_interval(mins => %s),'SIMULATED',%s,'Simulated fog for demonstration')""",
                (scn_id, hub, stamp, stamp, b.reopen_after_min, int(user)),
            )
            for alt, stands in (("RKT", 4), ("FJR", 6)):
                conn.execute(
                    """INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, weather_above_minima, handling_ok, fuel_ok,
                              lvp_in_force, effective_from_utc, quality, entered_by, note)
                       VALUES (%s,%s,'OPEN',%s,TRUE,TRUE,TRUE,FALSE,%s,'SIMULATED',%s,'Simulated alternate availability')""",
                    (scn_id, alt, stands, stamp, int(user)),
                )
    # first recommendations for airborne flights, written by the non-human agent
    recommended = 0
    with tx(agent_user_id()) as conn:
        airborne = conn.execute(
            "SELECT cf.flight_id FROM case_flight cf JOIN flight_state s ON s.flight_id = cf.flight_id AND s.scenario_id = %s WHERE cf.case_id = %s AND s.status IN ('AIRBORNE','HOLDING','DIVERTING','LANDED','ON_BLOCKS','SCHEDULED','TAXI_OUT')",
            (scn_id, case["case_id"]),
        ).fetchall()
        for row in airborne:
            with conn.transaction():
                conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (scn_id, case["case_id"], row["flight_id"]))
                recommended += 1
    return {**case, "flights": n, "recommended": recommended}


def _require_role(conn, user, allowed=("OCC", "ADMIN")):
    row = conn.execute("SELECT role_code FROM app_user WHERE user_id = %s", (int(user),)).fetchone()
    if not row or row["role_code"] not in allowed:
        raise HTTPException(403, f"Only {' or '.join(allowed)} can do this")


@r.post("/cases/{case_id}/close")
def close_case(case_id: int, user=Depends(actor)):
    """Archive a case. Decisions, comments and the audit trail stay; the case is just marked CLOSED."""
    with tx(user) as conn:
        _require_role(conn, user)
        rows = conn.execute(
            "UPDATE disruption_case SET phase = 'CLOSED', closed_at = scenario_stamp(scenario_id) WHERE case_id = %s RETURNING *", (case_id,)
        ).fetchall()
    if not rows:
        raise HTTPException(404, "Unknown case")
    return rows[0]


@r.delete("/cases/{case_id}")
def delete_case(case_id: int, user=Depends(actor)):
    """Delete a case that nobody has acted on. Cases with decisions or comments are part of the audit
    trail (the database forbids deleting those rows), so they must be closed instead."""
    with tx(user) as conn:
        _require_role(conn, user, ("ADMIN",))  # operational history is never deleted by duty staff: OCC closes a case, only an admin can remove an empty one
        case = conn.execute("SELECT case_id FROM disruption_case WHERE case_id = %s", (case_id,)).fetchone()
        if not case:
            raise HTTPException(404, "Unknown case")
        used = conn.execute(
            "SELECT (SELECT count(*) FROM decision WHERE case_id = %(c)s) AS decisions, (SELECT count(*) FROM case_comment WHERE case_id = %(c)s) AS comments",
            {"c": case_id},
        ).fetchone()
        if used["decisions"] or used["comments"]:
            raise HTTPException(409, f"This case has {used['decisions']} decision(s) and {used['comments']} comment(s). They are part of the audit trail and cannot be deleted. Close the case instead.")
        conn.execute("DELETE FROM recovery_plan WHERE case_id = %s", (case_id,))  # items cascade
        conn.execute("DELETE FROM report WHERE case_id = %s", (case_id,))
        conn.execute("DELETE FROM diversion WHERE case_id = %s", (case_id,))
        # recommendations are unique per flight and scenario across ALL cases, so other cases may point at ours: unlink first
        conn.execute("UPDATE recommendation SET superseded_by = NULL WHERE superseded_by IN (SELECT rec_id FROM recommendation WHERE case_id = %s)", (case_id,))
        conn.execute("UPDATE recommendation SET superseded_by = NULL WHERE case_id = %s", (case_id,))
        # flights still watched by another case must not be left without an open recommendation
        refresh = conn.execute(
            """SELECT DISTINCT other.case_id, cf.flight_id, dc.scenario_id
                 FROM case_flight cf
                 JOIN disruption_case dc ON dc.case_id = cf.case_id
                 JOIN case_flight other ON other.flight_id = cf.flight_id AND other.case_id <> cf.case_id
                 JOIN disruption_case odc ON odc.case_id = other.case_id AND odc.scenario_id = dc.scenario_id
                 JOIN flight_state s ON s.flight_id = cf.flight_id AND s.scenario_id = dc.scenario_id AND s.status IN ('AIRBORNE','HOLDING','DIVERTING','LANDED','ON_BLOCKS','SCHEDULED','TAXI_OUT')
                WHERE cf.case_id = %s""",
            (case_id,),
        ).fetchall()
        conn.execute("DELETE FROM recommendation WHERE case_id = %s", (case_id,))  # options cascade
        conn.execute("DELETE FROM case_flight WHERE case_id = %s", (case_id,))
        conn.execute("DELETE FROM disruption_case WHERE case_id = %s", (case_id,))
    if refresh:
        with tx(agent_user_id()) as conn:
            for row in refresh:
                with conn.transaction():
                    conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (row["scenario_id"], row["case_id"], row["flight_id"]))
    return {"deleted": case_id}


# ---------------------------------------------------------------- report time (move before sign-in, locked after: migration 018)
class ReportTime(BaseModel):
    scenario_id: int | None = None
    duty_id: int
    report_utc: datetime
    reason: str


@r.post("/crew/report-time")
def move_report_time(b: ReportTime, user=Depends(actor)):
    """Move a duty's report time while the crew has not signed in yet. The database refuses it once they have (the bracket is then
    fixed), refuses a time in the past or more than 12 hours away, and requires a reason. Returns the bracket and limit before and after."""
    with tx(user) as conn:
        _require_role(conn, user, ("OCC", "CREW_CONTROL", "ADMIN"))
        res = conn.execute("SELECT change_report_time(%s,%s,%s,%s) AS r", (b.scenario_id or live_scenario_id(), b.duty_id, b.report_utc, b.reason)).fetchone()
        return res["r"]


# ---------------------------------------------------------------- scenario clock (run / pause / set / advance: migration 019)
class ClockBody(BaseModel):
    action: str                       # run | pause | advance | set
    to_utc: datetime | None = None    # for set
    minutes: int | None = None        # for advance


@r.post("/scenarios/{scenario_id}/clock")
def scenario_clock(scenario_id: int, b: ClockBody, user=Depends(actor)):
    """Run, pause, set or advance a scenario's clock, so stamps follow the same time the screen shows. OCC and admin only."""
    with tx(user) as conn:
        _require_role(conn, user, ("OCC", "ADMIN"))
        res = conn.execute("SELECT set_scenario_clock(%s,%s,%s,%s) AS r", (scenario_id, b.action, b.to_utc, b.minutes)).fetchone()
        return res["r"]

