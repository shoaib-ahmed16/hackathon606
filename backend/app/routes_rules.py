"""Custom rules API (Developer Guide section 9, P1 #14 + constraint rules).

FILTER and ALERT rules are active as soon as they are created. PRIORITY and CONSTRAINT rules start as DRAFT and become
ACTIVE only when an approver role approves them (PRIORITY: OCC; CONSTRAINT: OCC or Crew Control, as in the plan).
A rule is "in force" only inside its valid_from / valid_to window, measured on the scenario clock (so replays work).
"""
from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from . import rules as engine
from .db import fetch, live_scenario_id, tx
from .deps import actor
from .routes_collab import _me, _scn

r = APIRouter(prefix="/api/rules", tags=["rules"])


@r.get("/fields")
def fields(user=Depends(actor)):
    """The field whitelist the rule builder offers, with types, allowed operators and (where known) the allowed values."""
    options = {
        k: v for k, v in engine.field_options().items()
    }
    return {
        "fields": [{"field": k, "type": t, "label": lab, "ops": engine.ALLOWED_OPS[t], "options": options.get(k)} for k, (t, lab) in engine.FIELDS.items()],
        "kinds": {
            "FILTER": "Adds a filter chip to the board. Active at once.",
            "ALERT": "Notifies the rule's creator and the flight's subscribers when a flight starts matching. Active at once.",
            "PRIORITY": "Moves matching flights up the board. Needs OCC approval.",
            "CONSTRAINT": "Flags matching flights as blocked by this rule. Can only add a block, never relax approved limits. Needs approval (OCC or Crew Control).",
        },
    }


_LIST = """
SELECT r.rule_id, r.name, r.kind, r.description, r.definition, r.priority, r.valid_from, r.valid_to, r.status,
       r.created_by, cu.display_name AS created_by_name, r.approved_by, au.display_name AS approved_by_name, r.approved_at,
       ({active}) AS in_force,
       CASE WHEN r.status IN ('ACTIVE','DRAFT') AND r.valid_to IS NOT NULL AND r.valid_to <= scenario_now(%(s)s) THEN 'EXPIRED' ELSE r.status END AS effective_status
  FROM ops_rule r
  JOIN app_user cu ON cu.user_id = r.created_by
  LEFT JOIN app_user au ON au.user_id = r.approved_by
 ORDER BY (r.status = 'DRAFT') DESC, r.priority, r.rule_id DESC
""".replace("{active}", engine.ACTIVE_NOW)


@r.get("")
def list_rules(scenario_id: int | None = None, user=Depends(actor)):
    s = _scn(scenario_id)
    rows = fetch(_LIST, {"s": s})
    with tx() as conn:
        me = _me(conn, user)
    for x in rows:
        ap = engine.APPROVERS.get(x["kind"], ())
        x["can_approve"] = x["status"] == "DRAFT" and me["role_code"] in ap
        x["can_retire"] = x["status"] in ("ACTIVE", "DRAFT") and (me["role_code"] in ("OCC", "ADMIN") or x["created_by"] == me["user_id"])
    return rows


class NewRule(BaseModel):
    scenario_id: int | None = None
    name: str
    kind: str
    description: str
    definition: dict[str, Any]
    priority: int = 100
    valid_from: datetime | None = None
    valid_to: datetime | None = None


class Preview(BaseModel):
    scenario_id: int | None = None
    case_id: int
    definition: dict[str, Any]


@r.post("/preview")
def preview(b: Preview, user=Depends(actor)):
    """How many flights of this case a rule would match right now (nothing is saved)."""
    try:
        return engine.preview(_scn(b.scenario_id), b.case_id, b.definition)
    except engine.RuleError as e:
        raise HTTPException(422, str(e))


@r.post("")
def create_rule(b: NewRule, user=Depends(actor)):
    kind = b.kind.upper()
    if kind not in engine.KINDS:
        raise HTTPException(422, f"kind must be one of {list(engine.KINDS)}")
    if not b.name.strip() or not b.description.strip():
        raise HTTPException(422, "A name and a description are required")
    if not 1 <= b.priority <= 1000:
        raise HTTPException(422, "priority must be between 1 (first) and 1000")
    s = _scn(b.scenario_id)
    try:
        engine.compile_condition(b.definition)
        case = fetch("SELECT case_id FROM disruption_case WHERE scenario_id = %s ORDER BY case_id DESC LIMIT 1", (s,))
        if case:  # dry run against the real views: a rule that cannot run is refused now, not when it is in force
            engine.preview(s, case[0]["case_id"], b.definition)
    except engine.RuleError as e:
        raise HTTPException(422, f"Rule definition: {e}")
    with tx(user) as conn:
        me = _me(conn, user)
        if me["role_code"] not in engine.CREATORS:
            raise HTTPException(403, f"Role {me['role_code']} cannot create rules")
        start = b.valid_from or conn.execute("SELECT scenario_now(%s) AS ts", (s,)).fetchone()["ts"]
        if b.valid_to and b.valid_to <= start:
            raise HTTPException(422, "valid_to must be after valid_from")
        status = "ACTIVE" if kind in ("FILTER", "ALERT") else "DRAFT"
        row = conn.execute(
            """INSERT INTO ops_rule (name, kind, description, definition, priority, valid_from, valid_to, status, created_by)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING rule_id, name, kind, status""",
            (b.name.strip(), kind, b.description.strip(), Jsonb(b.definition), b.priority, start, b.valid_to, status, int(user)),
        ).fetchone()
    return row


def _decide(rule_id: int, user, approve: bool):
    with tx(user) as conn:
        me = _me(conn, user)
        rule = conn.execute("SELECT * FROM ops_rule WHERE rule_id = %s FOR UPDATE", (rule_id,)).fetchone()
        if not rule:
            raise HTTPException(404, "Unknown rule")
        if rule["status"] != "DRAFT":
            raise HTTPException(409, f"Rule is already {rule['status']}")
        allowed = engine.APPROVERS.get(rule["kind"], ())
        if me["role_code"] not in allowed:
            raise HTTPException(403, f"Only {' or '.join(allowed) or 'nobody'} can {'approve' if approve else 'reject'} a {rule['kind']} rule")
        if approve:
            return conn.execute("UPDATE ops_rule SET status = 'ACTIVE', approved_by = %s, approved_at = now() WHERE rule_id = %s RETURNING rule_id, status", (int(user), rule_id)).fetchone()
        return conn.execute("UPDATE ops_rule SET status = 'REJECTED', approved_by = %s, approved_at = now() WHERE rule_id = %s RETURNING rule_id, status", (int(user), rule_id)).fetchone()


@r.post("/{rule_id}/approve")
def approve_rule(rule_id: int, user=Depends(actor)):
    return _decide(rule_id, user, True)


@r.post("/{rule_id}/reject")
def reject_rule(rule_id: int, user=Depends(actor)):
    return _decide(rule_id, user, False)


@r.post("/{rule_id}/retire")
def retire_rule(rule_id: int, user=Depends(actor)):
    """Stop a rule now (status EXPIRED). The rule and its history stay for the audit trail."""
    with tx(user) as conn:
        me = _me(conn, user)
        rule = conn.execute("SELECT created_by, status FROM ops_rule WHERE rule_id = %s FOR UPDATE", (rule_id,)).fetchone()
        if not rule:
            raise HTTPException(404, "Unknown rule")
        if rule["status"] not in ("ACTIVE", "DRAFT"):
            raise HTTPException(409, f"Rule is already {rule['status']}")
        if me["role_code"] not in ("OCC", "ADMIN") and rule["created_by"] != me["user_id"]:
            raise HTTPException(403, "Only the creator, OCC or admin can retire a rule")
        return conn.execute("UPDATE ops_rule SET status = 'EXPIRED' WHERE rule_id = %s RETURNING rule_id, status", (rule_id,)).fetchone()


@r.get("/matches")
def matches(case_id: int, scenario_id: int | None = None, user=Depends(actor)):
    """Rules in force right now and, per flight of the case, which of them match. Drives chips, priority sort and blocks."""
    s = _scn(scenario_id)
    rules = engine.active_rules(s)
    out: dict[int, list[int]] = {}
    broken = []
    out = engine.match_flights(s, case_id, rules, broken)  # a broken stored rule is skipped and reported, never fatal
    counts: dict[int, int] = {}
    for hits in out.values():
        for rid in hits:
            counts[rid] = counts.get(rid, 0) + 1
    return {
        "rules": [{"rule_id": x["rule_id"], "name": x["name"], "kind": x["kind"], "description": x["description"], "priority": x["priority"], "matches": counts.get(x["rule_id"], 0)} for x in rules],
        "flights": {str(k): v for k, v in out.items()},
        "errors": broken,
    }
