import json

from fastapi import APIRouter, Query

from .db import fetch, live_scenario_id

r = APIRouter(prefix="/api", tags=["audit"])

# rows written by the loader/engine in bulk: hidden unless asked for
SYSTEM_ENTITIES = ("data_exception", "recommendation", "recommendation_option", "crew_assignment", "crew_duty_leg", "case_flight", "fdp_calculation", "latest_departure_calc", "flight_state", "reassessment_queue")

FRIENDLY = [
    ("/api/auth/login", "Signed in"), ("/api/auth/logout", "Signed out"), ("/api/ask", "Asked the assistant"),
    ("/api/cases/create", "Created a case"), ("/api/events/flight", "Sent a flight feed event"), ("/api/feed/push", "Pushed the live data feed"),
    ("/api/crew/swap", "Executed a crew swap"), ("/api/recovery/build", "Built a recovery plan"),
    ("/api/scenarios/clone", "Cloned a scenario"), ("/api/whatif", "Ran a what-if"),
]


def _summary(row):
    a, d = row["action"], row.get("after_data") or {}
    if row["entity_type"] == "api":
        path = d.get("path") or row["entity_id"]
        body = d.get("body") if isinstance(d.get("body"), dict) else {}
        what = next((t for p, t in FRIENDLY if path == p), None)
        if what is None:
            if path.endswith("/recommend"): what = "Re-ran the recommendation engine"
            elif path.endswith("/recompute"): what = "Recomputed legality"
            elif path.endswith("/execute-diversion"): what = "Executed a diversion"
            elif path.endswith("/close"): what = "Closed a case"
            elif path.endswith("/report"): what = "Generated a report"
            elif "/approve" in path: what = "Approved a recovery plan"
            elif path.startswith("/api/diversions/"): what = "Station update"
            elif path.startswith("/api/records/"): what = f"Recorded a {path.rsplit('/', 1)[-1].replace('_', ' ')}"
            elif a == "DELETE": what = "Deleted"
            else: what = f"{a} {path}"
        extra = body.get("question") or body.get("title") or body.get("username") or ""
        res = "" if d.get("ok", True) else f" - REFUSED ({d.get('status')})"
        return f"{what}{(': ' + str(extra)[:120]) if extra else ''}{res}"
    et = row["entity_type"].replace("_", " ")
    bits = [str(d[k]) for k in ("decision_type", "status", "verdict", "op_status", "rec_type", "alternate_iata", "phase") if d.get(k)]
    fields = f" ({', '.join(row['changed_fields'])})" if row.get("changed_fields") and a == "UPDATE" else ""
    return f"{a.title()} {et} #{row['entity_id']}{(' - ' + ', '.join(bits)) if bits else ''}{fields}"


@r.get("/audit")
def audit(
    scenario_id: int | None = None, case_id: int | None = None, actor_id: int | None = None, kind: str = "all",
    q: str | None = None, include_system: bool = False, flight_id: int | None = None, limit: int = Query(300, le=2000),
):
    """The audit trail. kind: all | action (what people did) | change (what changed in the data)."""
    where, p = ["1=1"], {}
    if scenario_id is not None:
        where.append("(al.scenario_id = %(s)s OR al.scenario_id IS NULL)"); p["s"] = scenario_id
    if case_id is not None:
        where.append("(al.case_id = %(c)s OR al.case_id IS NULL)"); p["c"] = case_id
    if actor_id is not None:
        where.append("al.actor_user_id = %(a)s"); p["a"] = actor_id
    if kind == "action":
        where.append("al.entity_type = 'api'")
    elif kind == "change":
        where.append("al.entity_type <> 'api'")
    if not include_system:
        where.append("(al.entity_type = 'api' OR (al.actor_user_id IS NOT NULL AND al.entity_type <> ALL(%(sys)s)))"); p["sys"] = list(SYSTEM_ENTITIES)
    if flight_id is not None:
        where.append("(al.after_data->>'flight_id' = %(f)s OR al.entity_id = %(f)s OR al.after_data->'query'->>'flight_id' = %(f)s OR al.entity_id LIKE %(fp)s)")
        p["f"] = str(flight_id); p["fp"] = f"/api/flights/{flight_id}/%"
    if q:
        where.append("(al.entity_type ILIKE %(q)s OR al.entity_id ILIKE %(q)s OR al.action ILIKE %(q)s OR al.after_data::text ILIKE %(q)s OR u.display_name ILIKE %(q)s)")
        p["q"] = f"%{q}%"
    rows = fetch(
        f"""SELECT al.audit_id, al.occurred_at, al.scenario_time_utc, al.actor_user_id, u.display_name AS actor, al.actor_role,
                   al.scenario_id, al.case_id, al.entity_type, al.entity_id, al.action, al.changed_fields, al.before_data, al.after_data
              FROM audit_log al LEFT JOIN app_user u ON u.user_id = al.actor_user_id
             WHERE {' AND '.join(where)} ORDER BY al.audit_id DESC LIMIT {int(limit)}""",
        p,
    )
    for row in rows:
        row["kind"] = "action" if row["entity_type"] == "api" else "change"
        row["summary"] = _summary(row)
    return rows
