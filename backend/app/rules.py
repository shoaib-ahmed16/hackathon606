"""Custom rules (Developer Guide section 9): a small, SAFE condition language over the flight board.

  {"all": [ {"field": "lvp_required", "op": "eq", "value": true},
            {"field": "lvp_crew_ok",  "op": "neq", "value": true} ]}

Safety: only whitelisted fields, only the listed operators, values type-checked per field, depth and size limited.
Rules are compiled to PARAMETERISED SQL; user text is never concatenated into a query.

Kinds: FILTER (board filter), ALERT (notify when a rule starts matching a flight), PRIORITY (sort boost, needs approval),
CONSTRAINT (extra blocking flag, needs approval). A constraint can only ADD a block; nothing here can relax the approved
FDP rule set, because the legality engine in the database is not touched by rules.
"""
from __future__ import annotations

import logging

from functools import lru_cache

from .db import fetch, tx

log = logging.getLogger("fogops.rules")

# field -> (type, label). The whitelist from the plan: v_flight_watch + v_flight_severity.
FIELDS: dict[str, tuple[str, str]] = {
    "status": ("text", "Live status"),
    "crew_status": ("text", "Crew legality status"),
    "crew_margin_min": ("number", "Crew margin (min)"),
    "lvp_required": ("bool", "LVP in force at destination"),
    "lvp_crew_ok": ("bool", "Pilots LVP-qualified"),
    "diverted_to": ("text", "Diverted to (airport)"),
    "fog_exposure": ("text", "Fog exposure"),
    "open_exceptions": ("number", "Open data exceptions"),
    "minutes_to_latest_legal_departure": ("number", "Minutes to latest legal departure"),
    "recommendation": ("text", "Engine recommendation"),
    "decision_status": ("text", "Decision status"),
    "severity_score": ("number", "Severity (0-100)"),
    "connecting_pax": ("number", "Connecting passengers"),
    "tag": ("text", "Flight tag (medical, VIP ...)"),
}
OPS = {"eq": "=", "neq": "IS DISTINCT FROM", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
ALLOWED_OPS = {"text": ["eq", "neq", "in", "is_null", "not_null"], "number": ["eq", "neq", "lt", "lte", "gt", "gte", "is_null", "not_null"],
               "bool": ["eq", "neq", "is_null", "not_null"]}
MAX_DEPTH, MAX_ITEMS, MAX_IN = 4, 12, 20
KINDS = ("FILTER", "ALERT", "PRIORITY", "CONSTRAINT")
CREATORS = ("OCC", "DISPATCH", "CREW_CONTROL", "RECOVERY", "ADMIN")
APPROVERS = {"PRIORITY": ("OCC",), "CONSTRAINT": ("OCC", "CREW_CONTROL")}  # FILTER / ALERT need no approval


class RuleError(ValueError):
    pass


@lru_cache(maxsize=1)
def field_options() -> dict[str, list[str]]:
    """Allowed values for fields backed by an enum. A rule value outside this list is refused when the rule is created."""
    def enum(name):
        return [x["v"] for x in fetch("SELECT e.enumlabel AS v FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'fogops' AND t.typname = %s ORDER BY e.enumsortorder", (name,))]
    return {"status": enum("flight_status"), "crew_status": enum("legality_status"), "recommendation": enum("rec_type"),
            "decision_status": enum("decision_status"), "fog_exposure": ["NONE", "LOW", "MEDIUM", "HIGH"],
            "tag": ["MEDICAL", "VIP", "HIGH_IMPACT"]}


def _value(ftype: str, v):
    if ftype == "bool":
        if not isinstance(v, bool):
            raise RuleError("value must be true or false")
        return v
    if ftype == "number":
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise RuleError("value must be a number")
        return v
    if not isinstance(v, str) or not v.strip() or len(v) > 80:
        raise RuleError("value must be text of at most 80 characters")
    return v.strip()


def _checked_text(field: str, v):
    v = _value("text", v)
    allowed = field_options().get(field)
    if allowed is not None and v not in allowed:
        raise RuleError(f"'{v}' is not a valid value for {FIELDS[field][1]}; use one of {', '.join(allowed)}")
    return v


def compile_condition(node, depth: int = 0) -> tuple[str, list]:
    """Validate and compile one node to (sql, params). Columns are addressed as t."field" (whitelisted names only)."""
    if depth > MAX_DEPTH:
        raise RuleError("rule is nested too deeply")
    if not isinstance(node, dict):
        raise RuleError("a rule must be an object with all / any, or field / op / value")
    if "all" in node or "any" in node:
        key = "all" if "all" in node else "any"
        items = node[key]
        if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
            raise RuleError(f"'{key}' needs between 1 and {MAX_ITEMS} conditions")
        parts, params = [], []
        for it in items:
            s, p = compile_condition(it, depth + 1)
            parts.append(s)
            params += p
        return "(" + (" AND " if key == "all" else " OR ").join(parts) + ")", params
    field, op = node.get("field"), node.get("op")
    if field not in FIELDS:
        raise RuleError(f"unknown field '{field}'")
    ftype = FIELDS[field][0]
    if op not in ALLOWED_OPS[ftype] and op not in ("is_null", "not_null"):
        raise RuleError(f"operator '{op}' is not allowed for {FIELDS[field][1]}")
    col = f't."{field}"'
    if field == "tag":  # a flight can carry several tags, so compare against the array
        if op == "is_null":
            return 'cardinality(t."tags") = 0', []
        if op == "not_null":
            return 'cardinality(t."tags") > 0', []
        if op == "in":
            vals = node.get("value")
            if not isinstance(vals, list) or not 1 <= len(vals) <= MAX_IN:
                raise RuleError(f"'in' needs a list of 1 to {MAX_IN} values")
            return 't."tags" && %s', [[_checked_text(field, x) for x in vals]]
        if "value" not in node:
            raise RuleError("missing value")
        return ("%s = ANY(t.\"tags\")" if op == "eq" else "NOT (%s = ANY(t.\"tags\"))"), [_checked_text(field, node["value"])]
    if op == "is_null":
        return f"{col} IS NULL", []
    if op == "not_null":
        return f"{col} IS NOT NULL", []
    if op == "in":
        vals = node.get("value")
        if not isinstance(vals, list) or not 1 <= len(vals) <= MAX_IN:
            raise RuleError(f"'in' needs a list of 1 to {MAX_IN} values")
        return f"{col} = ANY(%s)", [[_checked_text(field, x) if ftype == 'text' else _value(ftype, x) for x in vals]]
    if "value" not in node:
        raise RuleError("missing value")
    return f"{col} {OPS[op]} %s", [_checked_text(field, node["value"]) if ftype == "text" else _value(ftype, node["value"])]


_BASE = """SELECT w.*, sv.severity_score, sv.connecting_pax,
                   COALESCE((SELECT array_agg(ft.tag) FROM flight_tag ft WHERE ft.scenario_id = w.scenario_id AND ft.flight_id = w.flight_id), '{}'::text[]) AS tags
             FROM v_flight_watch w
             LEFT JOIN v_flight_severity sv ON sv.case_id = w.case_id AND sv.flight_id = w.flight_id
            WHERE w.scenario_id = %s AND w.case_id = %s"""


def match_flights(scenario_id: int, case_id: int, rules: list[dict], errors: list | None = None) -> dict[int, list[int]]:
    """{flight_id: [rule_id, ...]} for every flight of the case that matches at least one rule. One query for all rules.
    A stored rule that cannot be evaluated is skipped (and reported in `errors`) so it never breaks the board for everyone."""
    if not rules:
        return {}
    good = []
    for r in rules:
        try:
            compile_condition(r["definition"])
            good.append(r)
        except RuleError as e:
            if errors is not None:
                errors.append(f"rule {r['rule_id']} ({r['name']}): {e}")
    rules = good
    if not rules:
        return {}
    try:
        return _match(scenario_id, case_id, rules)
    except Exception:  # noqa: BLE001 - a rule failed in the database: find it, skip it, keep the rest
        out: dict[int, list[int]] = {}
        for r in rules:
            try:
                for fid, hits in _match(scenario_id, case_id, [r]).items():
                    out.setdefault(fid, []).extend(hits)
            except Exception as e:  # noqa: BLE001
                log.warning("rule %s skipped: %s", r["rule_id"], e)
                if errors is not None:
                    errors.append(f"rule {r['rule_id']} ({r['name']}) could not be evaluated")
        return out


def _match(scenario_id: int, case_id: int, rules: list[dict]) -> dict[int, list[int]]:
    cases, params = [], [scenario_id, case_id]
    for r in rules:
        sql, p = compile_condition(r["definition"])
        cases.append(f"CASE WHEN {sql} THEN {int(r['rule_id'])} END")
        params += p
    q = f"WITH t AS ({_BASE}) SELECT t.flight_id, array_remove(ARRAY[{', '.join(cases)}]::int[], NULL) AS hits FROM t"
    out = {}
    for row in fetch(q, params):
        if row["hits"]:
            out[row["flight_id"]] = row["hits"]
    return out


def preview(scenario_id: int, case_id: int, definition: dict) -> dict:
    sql, p = compile_condition(definition)
    rows = fetch(f"WITH t AS ({_BASE}) SELECT t.flight_id, t.flight_no FROM t WHERE {sql} ORDER BY t.flight_no LIMIT 500", [scenario_id, case_id, *p])
    return {"count": len(rows), "sample": [r["flight_no"] for r in rows[:12]]}


ACTIVE_NOW = """r.status = 'ACTIVE' AND r.valid_from <= scenario_now(%(s)s) AND (r.valid_to IS NULL OR r.valid_to > scenario_now(%(s)s))"""


def active_rules(scenario_id: int, kinds: tuple[str, ...] | None = None) -> list[dict]:
    q = f"SELECT r.rule_id, r.name, r.kind, r.description, r.definition, r.priority FROM ops_rule r WHERE {ACTIVE_NOW}"
    rows = fetch(q + " ORDER BY r.priority, r.rule_id", {"s": scenario_id})
    return [r for r in rows if not kinds or r["kind"] in kinds]


def evaluate_alerts(agent_user: str) -> int:
    """Fire ALERT rules for flights that STARTED matching since the last evaluation. Returns alerts raised.
    Recipients: the flight's subscribers plus the rule's creator. Safe to run often and from several instances."""
    raised = 0
    scenarios = fetch("SELECT DISTINCT dc.scenario_id FROM disruption_case dc WHERE dc.phase <> 'CLOSED'")
    for sc in scenarios:
        scn = sc["scenario_id"]
        rules = active_rules(scn, ("ALERT",))
        stale = fetch("SELECT DISTINCT rule_id FROM ops_rule_match WHERE scenario_id = %s AND active", (scn,))
        if not rules and not stale:
            continue
        cases = fetch("SELECT case_id FROM disruption_case WHERE scenario_id = %s AND phase <> 'CLOSED' ORDER BY case_id", (scn,))
        matched: dict[int, dict[int, int]] = {r["rule_id"]: {} for r in rules}  # rule -> {flight: case}
        for c in cases:
            try:
                for fid, hits in match_flights(scn, c["case_id"], rules).items():
                    for rid in hits:
                        matched[rid].setdefault(fid, c["case_id"])
            except Exception:  # noqa: BLE001 - one bad rule must not stop the others
                log.exception("alert evaluation failed for scenario %s case %s", scn, c["case_id"])
        with tx(agent_user) as conn:
            for r in rules:
                flights = matched[r["rule_id"]]
                for fid, case_id in flights.items():
                    new = conn.execute(
                        """INSERT INTO ops_rule_match (rule_id, scenario_id, flight_id) VALUES (%s,%s,%s)
                           ON CONFLICT (rule_id, scenario_id, flight_id)
                           DO UPDATE SET active = TRUE, last_matched_at = now() WHERE ops_rule_match.active = FALSE
                           RETURNING 1""",
                        (r["rule_id"], scn, fid),
                    ).fetchone()
                    if not new:
                        conn.execute("UPDATE ops_rule_match SET last_matched_at = now() WHERE rule_id=%s AND scenario_id=%s AND flight_id=%s", (r["rule_id"], scn, fid))
                        continue
                    no = conn.execute("SELECT flight_no FROM flight WHERE flight_id = %s", (fid,)).fetchone()["flight_no"]
                    title, body = f"{no}: rule alert, {r['name']}", r["description"]
                    conn.execute("SELECT notify_flight(%s,%s,%s,%s,%s,'WARN','ops_rule',%s)", (scn, fid, case_id, title, body, str(r["rule_id"])))
                    conn.execute(
                        """INSERT INTO notification_outbox (scenario_id, case_id, flight_id, channel, recipient, severity, title, body, source_entity, source_id)
                           SELECT %s,%s,%s,'IN_APP',u.username,'WARN',%s,%s,'ops_rule',%s
                             FROM ops_rule o JOIN app_user u ON u.user_id = o.created_by
                            WHERE o.rule_id = %s
                              AND NOT EXISTS (SELECT 1 FROM flight_subscription s WHERE s.active AND s.scenario_id = %s AND s.flight_id = %s AND s.user_id = o.created_by)""",
                        (scn, case_id, fid, title, body, str(r["rule_id"]), r["rule_id"], scn, fid),
                    )
                    raised += 1
            # flights that stopped matching (or whose rule is no longer active) can alert again later
            for rid in {s["rule_id"] for s in stale} | set(matched):
                keep = list(matched.get(rid, {}))
                conn.execute(
                    "UPDATE ops_rule_match SET active = FALSE WHERE rule_id = %s AND scenario_id = %s AND active AND flight_id <> ALL(%s)",
                    (rid, scn, keep),
                )
        if raised:
            with tx() as conn:
                conn.execute("SELECT pg_notify('fogops_updated', %s)", ('{"rules": true}',))
    return raised
