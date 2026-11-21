"""MVP collaboration features from the New Plan (Developer Guide section 5): KPI bar, multi-role approvals,
subscriptions + in-app notifications, "?" data requests, deep links and the per-flight timeline.

Same rule as everywhere else: the database holds the rules (approval policy trigger, guardrails, notification
fan-out); these endpoints authenticate, set the actor and call/read database objects.
"""
from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from .db import fetch, live_scenario_id, tx
from .plain import humanize
from .deps import actor
from .routes_write import agent_user_id

r = APIRouter(prefix="/api", tags=["collaboration"])


def _scn(s: int | None) -> int:
    return s if s is not None else live_scenario_id()


def _me(conn, user):
    row = conn.execute("SELECT user_id, username, role_code FROM app_user WHERE user_id = %s", (int(user),)).fetchone()
    if not row:
        raise HTTPException(401, "Unknown user")
    return row


# ---------------------------------------------------------------- KPI bar
@r.get("/kpis")
def kpis(case_id: int, user=Depends(actor)):
    """The KPI bar for one case (flights affected, pax, severity, decisions pending, next deadline ...)."""
    rows = fetch("SELECT * FROM v_disruption_kpis WHERE case_id = %s", (case_id,))
    if not rows:
        raise HTTPException(404, "Unknown case")
    k = rows[0]
    sev = fetch(
        "SELECT count(*) FILTER (WHERE severity_score >= 50) AS high, count(*) FILTER (WHERE severity_score >= 30 AND severity_score < 50) AS medium, "
        "max(severity_score) AS max FROM v_flight_severity WHERE case_id = %s", (case_id,))[0]
    return {**k, "high_severity": sev["high"], "medium_severity": sev["medium"], "max_severity": sev["max"]}


# ---------------------------------------------------------------- approvals (multi-role, policy driven)
@r.get("/approval-policy")
def approval_policy(user=Depends(actor)):
    return fetch("SELECT decision_type::text AS decision_type, approver_role, required, notify_roles FROM approval_policy ORDER BY decision_type::text, approver_role")


_APPROVALS_SQL = """
SELECT d.decision_id, d.scenario_id, d.case_id, d.flight_id, f.flight_no, d.decision_type::text AS decision_type,
       d.status::text AS status, d.alternate_iata, d.rationale, d.followed_recommendation, d.decided_role AS proposed_role,
       u.display_name AS proposed_by, d.decided_at, d.decided_by,
       COALESCE((SELECT array_agg(p.approver_role ORDER BY p.approver_role) FROM approval_policy p
                  WHERE p.decision_type = d.decision_type AND p.required), '{}') AS required_roles,
       COALESCE((SELECT array_agg(DISTINCT a.approver_role) FROM decision_approval a
                  WHERE a.decision_id = d.decision_id AND a.verdict = 'APPROVED'), '{}') AS approved_roles,
       COALESCE((SELECT array_agg(DISTINCT a.approver_role) FROM decision_approval a
                  WHERE a.decision_id = d.decision_id AND a.verdict = 'REJECTED'), '{}') AS rejected_roles,
       COALESCE((SELECT array_agg(p.approver_role ORDER BY p.approver_role) FROM approval_policy p
                  WHERE p.decision_type = d.decision_type), '{}') AS allowed_roles
  FROM decision d
  JOIN flight f ON f.flight_id = d.flight_id
  LEFT JOIN app_user u ON u.user_id = d.decided_by
 WHERE d.scenario_id = %(scn)s
   AND (%(case)s::int IS NULL OR d.case_id = %(case)s::int)
   AND (%(flight)s::bigint IS NULL OR d.flight_id = %(flight)s::bigint)
   AND (%(status)s::text IS NULL OR d.status::text = %(status)s::text)
 ORDER BY d.decided_at DESC
 LIMIT 500
"""


@r.get("/approvals")
def approvals(case_id: int | None = None, flight_id: int | None = None, status: str | None = None,
              mine: bool = False, scenario_id: int | None = None, user=Depends(actor)):
    """Decisions with who must approve, who has, who is still awaited, and whether THIS user can act now.
    mine=true -> only PROPOSED decisions the signed-in user can approve (the approvals queue)."""
    with tx() as conn:
        me = _me(conn, user)
        can_approve_role = conn.execute("SELECT can_approve FROM app_role WHERE code = %s", (me["role_code"],)).fetchone()["can_approve"]
        rows = conn.execute(_APPROVALS_SQL, {"scn": _scn(scenario_id), "case": case_id, "flight": flight_id, "status": status}).fetchall()
    out = []
    for d in rows:
        waiting = [x for x in d["required_roles"] if x not in d["approved_roles"]]
        policy_ok = not d["allowed_roles"] or me["role_code"] in d["allowed_roles"]  # no policy rows = any approver
        d["waiting_for"] = waiting
        # the proposer can take their own proposal back (the picture changed); OCC and admin can too. Not once it is executed.
        d["can_withdraw"] = bool(d["status"] in ("PROPOSED", "APPROVED") and (d["decided_by"] == me["user_id"] or me["role_code"] in ("OCC", "ADMIN")))
        d["can_approve"] = bool(
            d["status"] == "PROPOSED" and can_approve_role and policy_ok
            and me["role_code"] not in d["approved_roles"] and not d["rejected_roles"]
        )
        if mine and not d["can_approve"]:
            continue
        out.append(d)
    return out


class Verdict(BaseModel):
    verdict: str = "APPROVED"  # APPROVED | REJECTED
    comment: str | None = None


class Withdraw(BaseModel):
    reason: str = "The picture changed"


@r.post("/decisions/{decision_id}/withdraw")
def withdraw(decision_id: int, b: Withdraw, user=Depends(actor)):
    """Take back a proposal that is still waiting or approved but not executed: it becomes REVOKED with who and why (never deleted).
    The proposer or OCC/admin can do it; the engine then re-assesses the flight and approvers are told."""
    reason = (b.reason or "").strip()
    if not reason:
        raise HTTPException(422, "Say why it is withdrawn")
    with tx(user) as conn:
        me = _me(conn, user)
        d = conn.execute("SELECT decision_id, decided_by, status::text AS status FROM decision WHERE decision_id = %s FOR UPDATE", (decision_id,)).fetchone()
        if not d:
            raise HTTPException(404, "Unknown decision")
        if d["status"] not in ("PROPOSED", "APPROVED"):
            raise HTTPException(409, f"A {d['status'].lower()} decision cannot be withdrawn here")
        if d["decided_by"] != me["user_id"] and me["role_code"] not in ("OCC", "ADMIN"):
            raise HTTPException(403, "Only the person who proposed it, or OCC, can withdraw it")
        conn.execute("UPDATE decision SET status = 'REVOKED', revoked_by = %s, revoke_reason = %s WHERE decision_id = %s", (me["user_id"], reason[:300], decision_id))
    return {"decision_id": decision_id, "status": "REVOKED"}


@r.post("/decisions/{decision_id}/approvals")
def approve(decision_id: int, b: Verdict, user=Depends(actor)):
    """One role's verdict. The database trigger decides when the decision becomes APPROVED (every required role)
    or REJECTED (any rejection), and refuses roles outside the policy, the AI and station users."""
    if b.verdict not in ("APPROVED", "REJECTED"):
        raise HTTPException(422, "verdict must be APPROVED or REJECTED")
    if b.verdict == "REJECTED" and not (b.comment or "").strip():
        raise HTTPException(422, "A reason is required to reject")
    with tx(user) as conn:
        me = _me(conn, user)
        conn.execute(
            "INSERT INTO decision_approval (decision_id, approver_id, approver_role, verdict, comment) VALUES (%s,%s,%s,%s,%s)",
            (decision_id, int(user), me["role_code"], b.verdict, b.comment),
        )
    rows = fetch(_APPROVALS_SQL.replace("d.scenario_id = %(scn)s", "d.decision_id = %(scn)s"), {"scn": decision_id, "case": None, "flight": None, "status": None})
    if not rows:
        raise HTTPException(404, "Unknown decision")
    d = rows[0]
    d["waiting_for"] = [x for x in d["required_roles"] if x not in d["approved_roles"]]
    return d


# ---------------------------------------------------------------- subscriptions + in-app notifications
@r.get("/me/subscriptions")
def my_subscriptions(scenario_id: int | None = None, user=Depends(actor)):
    return fetch(
        """SELECT flight_id, min(reason) AS reason, min(created_at) AS created_at, bool_or(channel = 'TEAMS') AS teams
             FROM flight_subscription WHERE active AND scenario_id = %s AND user_id = %s AND channel IN ('IN_APP','TEAMS')
            GROUP BY flight_id""",
        (_scn(scenario_id), int(user)),
    )


class Subscribe(BaseModel):
    scenario_id: int | None = None
    reason: str | None = None
    teams: bool | None = None  # True / False = also (or no longer) mirror alerts to the Teams channel


@r.post("/flights/{flight_id}/subscriptions")
def subscribe(flight_id: int, b: Subscribe | None = None, user=Depends(actor)):
    s = _scn(b.scenario_id if b else None)
    teams = b.teams if b else None
    with tx(user) as conn:
        if teams is not None:
            on = conn.execute("SELECT 1 FROM flight_subscription WHERE active AND scenario_id=%s AND flight_id=%s AND user_id=%s AND channel='TEAMS'", (s, flight_id, int(user))).fetchone()
            if teams and not on:
                conn.execute("INSERT INTO flight_subscription (scenario_id, flight_id, user_id, channel, target, reason, created_by) VALUES (%s,%s,%s,'TEAMS','#ops-fog',%s,%s)", (s, flight_id, int(user), None, int(user)))
            elif not teams and on:
                conn.execute("UPDATE flight_subscription SET active = FALSE WHERE scenario_id=%s AND flight_id=%s AND user_id=%s AND channel='TEAMS'", (s, flight_id, int(user)))
        have = conn.execute(
            "SELECT 1 FROM flight_subscription WHERE active AND scenario_id = %s AND flight_id = %s AND user_id = %s AND channel = 'IN_APP'",
            (s, flight_id, int(user)),
        ).fetchone()
        if not have:
            conn.execute(
                "INSERT INTO flight_subscription (scenario_id, flight_id, user_id, channel, reason, created_by) VALUES (%s,%s,%s,'IN_APP',%s,%s)",
                (s, flight_id, int(user), (b.reason if b else None), int(user)),
            )
    return {"subscribed": True, "flight_id": flight_id}


@r.delete("/flights/{flight_id}/subscriptions")
def unsubscribe(flight_id: int, scenario_id: int | None = None, user=Depends(actor)):
    with tx(user) as conn:
        conn.execute(
            "UPDATE flight_subscription SET active = FALSE WHERE scenario_id = %s AND flight_id = %s AND user_id = %s AND channel IN ('IN_APP','TEAMS')",
            (_scn(scenario_id), flight_id, int(user)),
        )
    return {"subscribed": False, "flight_id": flight_id}


@r.get("/me/notifications")
def my_notifications(limit: int = Query(50, le=200), user=Depends(actor)):
    """In-app inbox. PENDING = unread, SENT = read."""
    with tx() as conn:
        me = _me(conn, user)
        rows = conn.execute(
            """SELECT n.notification_id, n.flight_id, f.flight_no, n.case_id, n.severity::text AS severity, n.title, n.body,
                      n.source_entity, n.status, n.created_at,
                      EXISTS (SELECT 1 FROM flight_subscription s JOIN app_user su ON su.user_id = s.user_id
                               WHERE s.active AND s.channel = 'TEAMS' AND su.username = n.recipient AND s.flight_id = n.flight_id
                                 AND s.scenario_id = n.scenario_id) AS teams
                 FROM notification_outbox n LEFT JOIN flight f ON f.flight_id = n.flight_id
                WHERE n.channel = 'IN_APP' AND n.recipient = %s
                ORDER BY n.created_at DESC LIMIT %s""",
            (me["username"], limit),
        ).fetchall()
    return {"unread": sum(1 for x in rows if x["status"] == "PENDING"), "items": rows}


@r.post("/notifications/{notification_id}/read")
def read_notification(notification_id: int, user=Depends(actor)):
    with tx(user) as conn:
        me = _me(conn, user)
        n = conn.execute(
            "UPDATE notification_outbox SET status = 'SENT', sent_at = now() WHERE notification_id = %s AND channel = 'IN_APP' AND recipient = %s AND status = 'PENDING'",
            (notification_id, me["username"]),
        ).rowcount
    return {"read": n}


@r.post("/me/notifications/read-all")
def read_all_notifications(user=Depends(actor)):
    with tx(user) as conn:
        me = _me(conn, user)
        n = conn.execute(
            "UPDATE notification_outbox SET status = 'SENT', sent_at = now() WHERE channel = 'IN_APP' AND recipient = %s AND status = 'PENDING'",
            (me["username"],),
        ).rowcount
    return {"read": n}


# ---------------------------------------------------------------- "?" data requests
FIELDS = {"FUEL_ENDURANCE", "ALTERNATE_STATUS", "ALTERNATE_STANDS", "CREW_SIGN_IN", "CREW_QUALIFICATION", "ETA", "FLIGHT_PLAN", "LOAD_SHEET", "OTHER"}
DEFAULT_QUESTION = {
    "FUEL_ENDURANCE": "Fuel endurance (minutes of holding left) is not available. Please report it.",
    "ALTERNATE_STATUS": "Alternate status is not confirmed (open or closed). Please confirm.",
    "ALTERNATE_STANDS": "Stands available at the alternate are not known. Please confirm.",
    "CREW_SIGN_IN": "Crew sign-in time is missing. Please confirm.",
    "CREW_QUALIFICATION": "Crew qualification (LVP) is unconfirmed. Please confirm.",
    "ETA": "Updated ETA is not available. Please confirm.",
    "FLIGHT_PLAN": "The flight plan for the return leg is not filed yet. Please file it and confirm.",
    "LOAD_SHEET": "The load sheet for the return leg is not ready yet. Please prepare it and confirm.",
}
DEFAULT_ROLE = {"FUEL_ENDURANCE": "DISPATCH", "ALTERNATE_STATUS": "STATION", "ALTERNATE_STANDS": "STATION",
                "CREW_SIGN_IN": "CREW_CONTROL", "CREW_QUALIFICATION": "CREW_CONTROL", "FLIGHT_PLAN": "DISPATCH", "LOAD_SHEET": "STATION"}


class NewRequest(BaseModel):
    scenario_id: int | None = None
    field: str
    iata: str | None = None
    question: str | None = None
    requested_from_role: str | None = None


@r.get("/data-requests")
def data_requests(scenario_id: int | None = None, flight_id: int | None = None, status: str | None = None, user=Depends(actor)):
    return fetch(
        """SELECT q.*, f.flight_no, u.display_name AS requested_by_name
             FROM data_request q LEFT JOIN flight f ON f.flight_id = q.flight_id
             LEFT JOIN app_user u ON u.user_id = q.requested_by
            WHERE q.scenario_id = %s AND (%s::bigint IS NULL OR q.flight_id = %s::bigint)
              AND (%s::text IS NULL OR q.status = %s::text)
            ORDER BY q.created_at DESC LIMIT 500""",
        (_scn(scenario_id), flight_id, flight_id, status, status),
    )


@r.post("/flights/{flight_id}/data-requests")
def ask_for_data(flight_id: int, b: NewRequest, user=Depends(actor)):
    """Tracked request for missing data ('Ask crew' / 'Ask station'). Open requests notify the flight's subscribers."""
    field = b.field.upper()
    if field not in FIELDS:
        raise HTTPException(422, f"field must be one of {sorted(FIELDS)}")
    s = _scn(b.scenario_id)
    with tx(user) as conn:
        dup = conn.execute(
            "SELECT request_id FROM data_request WHERE scenario_id = %s AND flight_id = %s AND field = %s AND status = 'OPEN' AND coalesce(iata,'') = coalesce(%s,'')",
            (s, flight_id, field, b.iata),
        ).fetchone()
        if dup:
            return {**conn.execute("SELECT * FROM data_request WHERE request_id = %s", (dup["request_id"],)).fetchone(), "already_open": True}
        return conn.execute(
            """INSERT INTO data_request (scenario_id, flight_id, iata, field, question, requested_from_role, requested_by)
               VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (s, flight_id, b.iata, field, b.question or DEFAULT_QUESTION.get(field, "Please provide this value."),
             b.requested_from_role or DEFAULT_ROLE.get(field), int(user)),
        ).fetchone()


class Answer(BaseModel):
    value: Any  # FUEL_ENDURANCE: minutes; ALTERNATE_STATUS: {"op_status": "OPEN|CLOSED|RESTRICTED", "stands": n}; others: free text
    quality: str = "MANUAL"  # MEASURED | MANUAL | ESTIMATED ...
    note: str | None = None


@r.post("/data-requests/{request_id}/answer")
def answer_request(request_id: int, b: Answer, user=Depends(actor)):
    """Store the answer and APPLY it where the engine reads it (fuel estimate, airport status), then re-rank."""
    refresh: list[tuple[int, int, int]] = []
    with tx(user) as conn:
        me = _me(conn, user)
        q = conn.execute("SELECT * FROM data_request WHERE request_id = %s FOR UPDATE", (request_id,)).fetchone()
        if not q:
            raise HTTPException(404, "Unknown request")
        if q["status"] != "OPEN":
            raise HTTPException(409, f"Request is already {q['status']}")
        if q["requested_from_role"] and me["role_code"] not in (q["requested_from_role"], "OCC", "ADMIN"):
            raise HTTPException(403, f"This request is for {q['requested_from_role']}")
        scn_id, flight_id = q["scenario_id"], q["flight_id"]
        now = conn.execute("SELECT scenario_now(%s) AS ts", (scn_id,)).fetchone()["ts"]
        applied = None
        if q["field"] == "FUEL_ENDURANCE":
            try:
                minutes = int(b.value)
            except (TypeError, ValueError):
                raise HTTPException(422, "value must be the holding endurance in whole minutes")
            if minutes < 0 or minutes > 600:
                raise HTTPException(422, "endurance must be between 0 and 600 minutes")
            conn.execute(
                """INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, est_holding_endurance_min, quality, basis, entered_by)
                   VALUES (%s,%s,%s,%s,%s,%s,%s)""",
                (scn_id, flight_id, now, minutes, b.quality, Jsonb({"data_request": request_id, "note": b.note or "reported"}), int(user)),
            )
            applied = "flight_fuel_estimate"
        elif q["field"] in ("ALTERNATE_STATUS", "ALTERNATE_STANDS") and q["iata"]:
            v = b.value if isinstance(b.value, dict) else {"op_status": str(b.value).upper()}
            op = str(v.get("op_status") or "OPEN").upper()
            if op not in ("OPEN", "CLOSED", "RESTRICTED"):
                raise HTTPException(422, "op_status must be OPEN, CLOSED or RESTRICTED")
            conn.execute(
                """INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, weather_above_minima, handling_ok, fuel_ok,
                          lvp_in_force, effective_from_utc, quality, entered_by, note)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,FALSE,%s,%s,%s,%s)""",
                (scn_id, q["iata"], op, v.get("stands"), op == "OPEN", op == "OPEN", op == "OPEN", now, b.quality, int(user), b.note or f"data request {request_id}"),
            )
            applied = "airport_status_event"
        elif q["field"] in ("FLIGHT_PLAN", "LOAD_SHEET"):
            # answering the request IS ticking the paperwork item on the diversion, with who and when
            col = "flight_plan_filed" if q["field"] == "FLIGHT_PLAN" else "load_sheet_ready"
            n = conn.execute(
                f"""UPDATE diversion SET {col}_at = scenario_stamp(scenario_id), {col}_by = %s, updated_by = %s, updated_at = now()
                       WHERE scenario_id = %s AND original_flight_id = %s AND status NOT IN ('DEPARTED','CLOSED','CANCELLED')""",
                (int(user), int(user), scn_id, flight_id)).rowcount
            if not n:
                raise HTTPException(409, "This flight has no open diversion to attach it to")
            applied = "diversion"
        conn.execute(
            "UPDATE data_request SET status = 'ANSWERED', answer = %s, answered_by = %s, answered_at = now() WHERE request_id = %s",
            (Jsonb({"value": b.value, "quality": b.quality, "note": b.note, "applied_to": applied}), int(user), request_id),
        )
        if flight_id:
            cases = conn.execute("SELECT DISTINCT cf.case_id FROM case_flight cf JOIN disruption_case dc ON dc.case_id = cf.case_id WHERE dc.scenario_id = %s AND cf.flight_id = %s", (scn_id, flight_id)).fetchall()
            refresh = [(scn_id, c["case_id"], flight_id) for c in cases]
    # re-rank as the non-human agent (recommends, never decides); the worker also reacts, this is immediate
    if refresh:
        with tx(agent_user_id()) as conn:
            for scn_id, case_id, flight_id in refresh:
                with conn.transaction():
                    conn.execute("SELECT compute_flight_legality(%s,%s,'data_request')", (scn_id, flight_id))
                    conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (scn_id, case_id, flight_id))
    return {"answered": request_id, "applied_to": applied, "reranked": len(refresh)}


# ---------------------------------------------------------------- deep links
@r.get("/flights/{flight_id}/links")
def flight_links(flight_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """'Open in aeroOps / crew system / aeroMart' with the flight pre-selected. Templates live in external_system;
    `configured` is false while a template still points at the placeholder host."""
    s = _scn(scenario_id)
    return fetch(
        """SELECT es.code, es.name, es.purpose, es.enabled, deep_link(es.code, %s, %s) AS url,
                  (es.deep_link_template NOT LIKE '%%.example/%%') AS configured
             FROM external_system es WHERE es.deep_link_template IS NOT NULL ORDER BY es.code""",
        (flight_id, s),
    )


# ---------------------------------------------------------------- per-flight timeline (the flight briefing)
@r.get("/flights/{flight_id}/timeline")
def flight_timeline(flight_id: int, scenario_id: int | None = None, since: datetime | None = None, limit: int = Query(300, le=2000), user=Depends(actor)):
    """Everything that happened to ONE flight on one clock: feed events, decisions, approvals, comments, requests, station (crew ids shown as names)."""
    return humanize(_timeline(flight_id, scenario_id, since, limit, user))


def _timeline(flight_id: int, scenario_id: int | None = None, since: datetime | None = None, limit: int = Query(300, le=2000),
                    user=Depends(actor)):
    """Everything that happened to ONE flight on one clock: feed events, decisions, approvals, comments, requests, station."""
    return fetch(
        """SELECT * FROM (
             SELECT e.event_ts AS occurred_at, 'feed' AS stream, e.source_code AS actor, NULL AS actor_role,
                    e.event_type || ' (' || coalesce(e.apply_result,'-') || ')' AS summary
               FROM flight_event e WHERE e.scenario_id = %(s)s AND e.flight_id = %(f)s AND e.event_type <> 'BASELINE'
             UNION ALL
             SELECT d.decided_at, 'decision', u.display_name, d.decided_role,
                    d.decision_type::text || ' ' || d.status::text || coalesce(' ' || d.alternate_iata, '') || ': ' || coalesce(d.rationale, '')
               FROM decision d LEFT JOIN app_user u ON u.user_id = d.decided_by WHERE d.scenario_id = %(s)s AND d.flight_id = %(f)s
             UNION ALL
             SELECT a.approved_at, 'approval', u.display_name, a.approver_role,
                    a.verdict || ' ' || d.decision_type::text || coalesce(': ' || a.comment, '')
               FROM decision_approval a JOIN decision d ON d.decision_id = a.decision_id
               LEFT JOIN app_user u ON u.user_id = a.approver_id WHERE d.scenario_id = %(s)s AND d.flight_id = %(f)s
             UNION ALL
             SELECT c.created_at, 'comment', u.display_name, c.author_role, '[' || c.kind || '] ' || c.body
               FROM case_comment c JOIN app_user u ON u.user_id = c.author_id
               JOIN disruption_case dc ON dc.case_id = c.case_id
              WHERE dc.scenario_id = %(s)s AND c.flight_id = %(f)s
             UNION ALL
             SELECT t.set_at, 'tag', u.display_name, NULL, 'Tagged ' || t.tag || coalesce(': ' || t.note, '')
               FROM flight_tag t LEFT JOIN app_user u ON u.user_id = t.set_by WHERE t.scenario_id = %(s)s AND t.flight_id = %(f)s
             UNION ALL
             SELECT q.created_at, 'request', u.display_name, NULL,
                    'Data request ' || q.field || ' ' || q.status || ': ' || q.question
               FROM data_request q LEFT JOIN app_user u ON u.user_id = q.requested_by WHERE q.scenario_id = %(s)s AND q.flight_id = %(f)s
           ) t
           WHERE t.occurred_at IS NOT NULL AND (%(since)s::timestamptz IS NULL OR t.occurred_at > %(since)s::timestamptz)
           ORDER BY t.occurred_at DESC LIMIT %(lim)s""",
        {"s": _scn(scenario_id), "f": flight_id, "since": since, "lim": limit},
    )


# ---------------------------------------------------------------- alternates table (rank_alternates, read-only)
@r.get("/flights/{flight_id}/alternates")
def alternates(flight_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """Every alternate ranked for this flight: stands, fuel margin, return block, crew outcome, and why it is blocked."""
    try:
        return fetch("SELECT * FROM rank_alternates(%s,%s)", (_scn(scenario_id), flight_id))
    except Exception:  # noqa: BLE001 - not an airborne flight: there is nothing to rank
        return []


# ---------------------------------------------------------------- tags (a medical case on board, VIP ...)
class Tag(BaseModel):
    scenario_id: int | None = None
    tag: str
    note: str | None = None


@r.post("/flights/{flight_id}/tags")
def add_tag(flight_id: int, b: Tag, user=Depends(actor)):
    tag = b.tag.upper()
    if tag not in ("MEDICAL", "VIP", "HIGH_IMPACT"):
        raise HTTPException(422, "tag must be MEDICAL, VIP or HIGH_IMPACT")
    with tx(user) as conn:
        me = _me(conn, user)
        if me["role_code"] not in ("OCC", "DISPATCH", "CREW_CONTROL", "STATION", "ADMIN"):
            raise HTTPException(403, f"Role {me['role_code']} cannot tag flights")
        conn.execute(
            "INSERT INTO flight_tag (scenario_id, flight_id, tag, note, set_by) VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
            (_scn(b.scenario_id), flight_id, tag, b.note, int(user)),
        )
    return {"flight_id": flight_id, "tag": tag}


@r.delete("/flights/{flight_id}/tags/{tag}")
def remove_tag(flight_id: int, tag: str, scenario_id: int | None = None, user=Depends(actor)):
    with tx(user) as conn:
        me = _me(conn, user)
        if me["role_code"] not in ("OCC", "DISPATCH", "CREW_CONTROL", "ADMIN"):
            raise HTTPException(403, f"Role {me['role_code']} cannot remove tags")
        conn.execute("DELETE FROM flight_tag WHERE scenario_id = %s AND flight_id = %s AND tag = %s", (_scn(scenario_id), flight_id, tag.upper()))
    return {"flight_id": flight_id, "tag": tag.upper(), "removed": True}


# ---------------------------------------------------------------- execute (OCC) for every decision type
@r.post("/decisions/{decision_id}/execute")
def execute_decision(decision_id: int, turnaround_min: int | None = None, user=Depends(actor)):
    """OCC executes an APPROVED decision. DIVERT creates the recovery leg (and queues the aeroMart entry);
    CREW_REPLACE performs the approved swap; every other type is marked EXECUTED."""
    from .routes_write import Swap, swap  # local import: routes_write imports nothing from here

    with tx(user) as conn:
        me = _me(conn, user)
        if me["role_code"] not in ("OCC", "ADMIN"):
            raise HTTPException(403, "Only OCC executes decisions")
        d = conn.execute("SELECT * FROM decision WHERE decision_id = %s FOR UPDATE", (decision_id,)).fetchone()
        if not d:
            raise HTTPException(404, "Unknown decision")
        if d["status"] != "APPROVED":
            raise HTTPException(409, f"Decision is {d['status']}: every required role must approve before it can be executed")
        kind = str(d["decision_type"])
        if kind == "DIVERT":
            done = conn.execute("SELECT alternate_iata FROM diversion WHERE scenario_id = %s AND original_flight_id = %s", (d["scenario_id"], d["flight_id"])).fetchone()
            if done:  # a flight diverts once per scenario: say so instead of failing on a duplicate key
                raise HTTPException(409, f"Already diverted: this flight is already diverted to {done['alternate_iata']} and cannot be diverted again.")
            conn.execute("SELECT execute_diversion(%s,%s)", (decision_id, turnaround_min))
        elif kind != "CREW_REPLACE":
            conn.execute("UPDATE decision SET status = 'EXECUTED', executed_at = scenario_stamp(scenario_id) WHERE decision_id = %s", (decision_id,))
    if kind == "CREW_REPLACE":
        det = d["details"] or {}
        keep = {k: det[k] for k in ("duty_id", "out_crew_id", "in_crew_id", "sign_in_utc", "report_station", "standby_id", "positioning_min") if k in det}
        if not {"duty_id", "out_crew_id", "in_crew_id"} <= set(keep):
            raise HTTPException(409, "This crew replacement has no crew details recorded; use the replacement finder")
        swap(Swap(scenario_id=d["scenario_id"], case_id=d["case_id"], decision_id=decision_id, reason=d["rationale"] or "Approved replacement", **keep), user)
    return {"decision_id": decision_id, "executed": kind}


# ---------------------------------------------------------------- downstream impact (downstream_impact(), read-only)
@r.get("/flights/{flight_id}/downstream")
def downstream(flight_id: int, scenario_id: int | None = None, ready_at_hub_utc: datetime | None = None, user=Depends(actor)):
    """What else breaks if this flight is late or diverted: the tail's next legs (delay carried leg by leg), each operating crew
    member's next duty and rest, and connecting passengers. `ready_at_hub_utc` is an optional what-if (aircraft back at the hub at ...)."""
    return fetch("SELECT * FROM downstream_impact(%s,%s,%s)", (_scn(scenario_id), flight_id, ready_at_hub_utc))


# ---------------------------------------------------------------- connecting passengers per flight (v_connection_risk, read-only)
@r.get("/flights/{flight_id}/connections")
def flight_connections(flight_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """Passengers arriving on this flight who connect onward: the onward flight, how many, the projected connection time against the
    scheduled one and the 40 min minimum, and the status. Worst first, so Customer Service can start with the passengers at risk."""
    return fetch(
        """SELECT outbound_flight_id, outbound_flight, outbound_to, connection_iata, pax_count, sched_connection_min,
                  inbound_arrival_utc, outbound_departure_utc, projected_connection_min, connection_status
             FROM v_connection_risk WHERE scenario_id = %s AND inbound_flight_id = %s
            ORDER BY CASE connection_status WHEN 'MISSED' THEN 0 WHEN 'INBOUND_DIVERTED' THEN 1 WHEN 'CANCELLED' THEN 2 WHEN 'AT_RISK' THEN 3 ELSE 4 END,
                     projected_connection_min NULLS LAST""",
        (_scn(scenario_id), flight_id),
    )


# ---------------------------------------------------------------- fuel in kilograms (flight_fuel_estimate + rank_alternates, read-only)
@r.get("/flights/{flight_id}/fuel-card")
def fuel_card(flight_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """Fuel on board, burn rate and, for each alternate, what the aircraft would land with and what the return leg would need.
    The engine works in minutes of holding; this turns them into kilograms with the SAME margins, and says which numbers are assumptions:
    the burn rate is the holding burn from the estimate, used as a stand-in for the burn on the leg (no aircraft-type burn table in the data)."""
    s = _scn(scenario_id)
    est = fetch("""SELECT as_of_utc, fuel_on_board_kg, burn_rate_hold_kg_per_hr, min_diversion_fuel_kg, est_holding_endurance_min, quality, basis
                     FROM flight_fuel_estimate WHERE scenario_id = %s AND flight_id = %s ORDER BY as_of_utc DESC LIMIT 1""", (s, flight_id))
    if not est:
        return {"available": False, "reason": "No fuel on board has been reported or estimated for this flight."}
    e = est[0]
    burn = float(e["burn_rate_hold_kg_per_hr"] or 0)
    now = fetch("SELECT scenario_now(%s) AS t", (s,))[0]["t"]
    left_now = None if e["fuel_on_board_kg"] is None else max(0.0, float(e["fuel_on_board_kg"]) - burn * max(0.0, (now - e["as_of_utc"]).total_seconds() / 3600))
    alts = []
    try:
        for a in fetch("SELECT * FROM rank_alternates(%s,%s)", (s, flight_id)):
            if a["fuel_margin_min"] is None or not burn:
                alts.append({"alt_iata": a["alt_iata"], "is_executable": a["is_executable"], "fuel_margin_min": a["fuel_margin_min"]})
                continue
            per_min = burn / 60
            reserve_min = a["final_reserve_min"] or 30
            at_landing = (a["fuel_margin_min"] + reserve_min) * per_min          # fuel left on touchdown
            above_reserve = a["fuel_margin_min"] * per_min                       # fuel above the final reserve
            back = (a["return_block_min"] or 0) * per_min + reserve_min * per_min  # the return leg plus a final reserve again
            alts.append({"alt_iata": a["alt_iata"], "is_executable": a["is_executable"], "fuel_margin_min": a["fuel_margin_min"],
                         "lands_with_kg": round(max(0.0, at_landing)), "above_reserve_kg": round(above_reserve),
                         "return_leg_need_kg": round(back), "uplift_needed_kg": round(max(0.0, back - max(0.0, at_landing))),
                         "return_block_min": a["return_block_min"], "final_reserve_min": reserve_min})
    except Exception:  # noqa: BLE001 - not an airborne flight: nothing to rank
        pass
    return {"available": True, "as_of_utc": e["as_of_utc"], "fuel_on_board_kg": e["fuel_on_board_kg"], "fuel_now_kg": None if left_now is None else round(left_now),
            "burn_rate_kg_per_hr": burn or None, "endurance_min": e["est_holding_endurance_min"], "quality": e["quality"], "basis": e["basis"],
            "assumption": "Burn rate = the holding burn from the estimate, used as a stand-in for the burn on the leg. Replace with an aircraft-type burn table when one is supplied.",
            "alternates": alts}

