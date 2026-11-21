from datetime import datetime, timedelta

from fastapi import APIRouter, HTTPException, Query

from .db import fetch, live_scenario_id, view

r = APIRouter(prefix="/api", tags=["read models"])


def scn(scenario_id: int | None) -> int | None:
    """Every screen is scenario-scoped. No scenario given = the LIVE operational picture."""
    return scenario_id if scenario_id is not None else live_scenario_id()


@r.get("/scenarios")
def scenarios():
    return fetch("SELECT scenario_id, name, kind, parent_scenario_id, sim_clock_utc, description, is_active FROM scenario ORDER BY scenario_id")


@r.get("/users")
def users():
    """Who can act (drives the 'acting as' picker + X-User-Id)."""
    return fetch("SELECT user_id, username, display_name, role_code FROM app_user WHERE is_active ORDER BY user_id")


@r.get("/cases")
def cases(scenario_id: int | None = None):
    """All disruption cases (newest first), with their scenario. Optional scenario filter."""
    return fetch(
        """SELECT c.*, s.name AS scenario_name, s.kind AS scenario_kind,
                  CASE WHEN s.sim_clock_utc IS NULL THEN NULL ELSE scenario_now(c.scenario_id) END AS sim_clock_utc, s.clock_running,
                  -- is the hub of this case closed or under LVP right now (scenario clock)? the app opens on a case where it is
                  EXISTS (SELECT 1 FROM v_airport_status_current a
                           WHERE a.scenario_id = c.scenario_id AND a.iata = c.hub_iata AND (a.op_status <> 'OPEN' OR a.lvp_in_force)) AS hub_restricted
             FROM disruption_case c JOIN scenario s USING (scenario_id)
            WHERE (%s::int IS NULL OR c.scenario_id = %s::int) ORDER BY c.case_id DESC""",
        (scenario_id, scenario_id),
    )


@r.get("/flights")
def flights(scenario_id: int | None = None, case_id: int | None = None, limit: int = Query(1000, le=5000)):
    """Single flight watch: status, ETA, fog exposure, captain, duty margin, recommendation, decision, owner, severity, tags."""
    # The case filter is added only when given and as a plain equality: with "(%s IS NULL OR case_id = %s)" Postgres cannot push
    # it down into the heavy v_flight_watch view and evaluates EVERY case of the scenario (23 s for a 94-flight case).
    where, params = "w.scenario_id = %s", [scn(scenario_id)]
    if case_id is not None:
        where += " AND w.case_id = %s"
        params.append(case_id)
    return fetch(
        f"""SELECT w.*, sv.severity_score, sv.connecting_pax, fcl.max_fdp_min, fcl.projected_end_utc,
                   -- connecting passengers whose onward flight is really threatened (less than the minimum connection time, flight diverted or cancelled)
                   (SELECT dv.flight_plan_filed_at FROM diversion dv WHERE dv.scenario_id = w.scenario_id AND dv.original_flight_id = w.flight_id
                       AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED') ORDER BY dv.diversion_id DESC LIMIT 1) AS flight_plan_filed_at,
                   (SELECT dv.load_sheet_ready_at FROM diversion dv WHERE dv.scenario_id = w.scenario_id AND dv.original_flight_id = w.flight_id
                       AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED') ORDER BY dv.diversion_id DESC LIMIT 1) AS load_sheet_ready_at,
                   COALESCE((SELECT sum(r.pax_count) FROM v_connection_risk r WHERE r.scenario_id = w.scenario_id AND r.inbound_flight_id = w.flight_id
                                AND r.connection_status <> 'OK'), 0)::int AS pax_at_risk,
                   COALESCE((SELECT array_agg(ft.tag ORDER BY ft.tag) FROM flight_tag ft WHERE ft.scenario_id = w.scenario_id AND ft.flight_id = w.flight_id), '{{}}'::text[]) AS tags
              FROM v_flight_watch w
              LEFT JOIN v_flight_severity sv ON sv.case_id = w.case_id AND sv.flight_id = w.flight_id AND sv.scenario_id = w.scenario_id
              LEFT JOIN v_flight_crew_legality fcl ON fcl.scenario_id = w.scenario_id AND fcl.flight_id = w.flight_id
             WHERE {where}
             ORDER BY coalesce(w.eta_utc, w.sta_utc) LIMIT {int(limit)}""",
        params,
    )


@r.get("/crew/legality")
def crew_legality(scenario_id: int | None = None, case_id: int | None = None, limit: int = Query(200, le=2000)):
    """Q1: which crew runs out of legality next (soonest first). With case_id, only duties flying that case's flights."""
    s = scn(scenario_id)
    if case_id is None:
        return view("v_crew_legality_ranking", {"scenario_id": s}, "ORDER BY minutes_until_legal_end NULLS LAST", limit)
    return fetch(
        f"""SELECT v.* FROM v_crew_legality_ranking v
             WHERE v.scenario_id = %s AND v.duty_id IN (
                   SELECT l.duty_id FROM crew_duty_leg l JOIN case_flight cf ON cf.flight_id = l.flight_id
                    WHERE l.scenario_id = %s AND l.is_active AND cf.case_id = %s)
             ORDER BY v.minutes_until_legal_end NULLS LAST LIMIT {int(limit)}""",
        (s, s, case_id),
    )


@r.get("/aircraft/{registration}")
def aircraft(registration: str, scenario_id: int | None = None):
    """Q2: where is aircraft X and what is it waiting for."""
    rows = view("v_aircraft_whereabouts", {"scenario_id": scn(scenario_id), "registration": registration.upper()})
    if not rows:
        raise HTTPException(404, "Unknown registration")
    return rows


@r.get("/crew/standby-candidates")
def standby(duty_id: int, position: str, station: str, from_leg: int = 1, scenario_id: int | None = None):
    """Q4: alternate crew who keep legality and roster (positioning, LVP, rest, conflicts included)."""
    return fetch("SELECT * FROM standby_candidates(%s,%s,%s,%s,%s)", (scn(scenario_id), duty_id, position.upper(), station.upper(), from_leg))


@r.get("/crew/fdp-preview")
def fdp_preview(duty_id: int, report_utc: datetime, scenario_id: int | None = None):
    """What moving the report time would do, before the crew signs in: the sign-in bracket it falls in and the maximum FDP that bracket gives.
    Once the crew has signed in the bracket is locked: only the number of sectors can still change the limit."""
    s = scn(scenario_id)
    cur = fetch(
        """SELECT fc.position_code, fc.sign_in_utc, fc.legs_counted, fc.max_fdp_min, fc.band_tz, fc.rule_set_id, fc.legal_end_utc,
                  r.local_start_from, r.local_start_to
             FROM fdp_calculation fc LEFT JOIN fdp_rule r ON r.rule_id = fc.rule_id
            WHERE fc.scenario_id = %s AND fc.duty_id = %s AND fc.crew_id IS NOT NULL AND fc.is_current
            ORDER BY fc.margin_min NULLS LAST LIMIT 1""", (s, duty_id))
    if not cur:
        return {"available": False, "reason": "No crew legality is calculated for this duty yet"}
    c = cur[0]
    now = fetch("SELECT scenario_now(%s) AS t", (s,))[0]["t"]
    out = {"available": True, "position": c["position_code"], "legs": c["legs_counted"], "signed_in": c["sign_in_utc"] <= now,
           "current": {"report_utc": c["sign_in_utc"], "bracket_from": c["local_start_from"], "bracket_to": c["local_start_to"],
                       "max_fdp_min": c["max_fdp_min"], "legal_end_utc": c["legal_end_utc"]}}
    if out["signed_in"]:
        out["locked"] = True
        return out  # no preview: the bracket was fixed at sign-in
    row = fetch("SELECT * FROM lookup_fdp_rule(%s,%s,(%s::timestamptz AT TIME ZONE %s)::time,%s)",
                (c["rule_set_id"], c["position_code"], report_utc, c["band_tz"], c["legs_counted"]))
    n = row[0] if row and row[0].get("rule_id") else None
    out["locked"] = False
    out["preview"] = None if not n else {"report_utc": report_utc, "bracket_from": n["local_start_from"], "bracket_to": n["local_start_to"],
                                         "max_fdp_min": n["max_fdp_min"],
                                         "legal_end_utc": report_utc + timedelta(minutes=n["max_fdp_min"])}
    return out


@r.get("/crew/replacement-options")
def replacement_options(duty_id: int, position: str, destination: str, from_leg: int = 1, scenario_id: int | None = None):
    """Replacement finder for the flight's destination: legal for the current legs (N) and one more sector (N+1),
    positioning to the destination, weekly workload vs the pool average. Ranked, suggestions first."""
    return fetch("SELECT * FROM crew_replacement_options(%s,%s,%s,%s,%s)", (scn(scenario_id), duty_id, position.upper(), destination.upper(), from_leg))


@r.get("/crew/leg-outlook")
def leg_outlook(duty_id: int, scenario_id: int | None = None):
    """Crew on a duty: legality now (N legs) and with one more sector (N+1), from the approved FDP rules."""
    return fetch("SELECT * FROM crew_leg_outlook(%s,%s)", (scn(scenario_id), duty_id))


@r.get("/crew/next-duty-legal")
def next_duty_legal(duty_id: int, scenario_id: int | None = None):
    """Per crew on a duty: duty end + minimum rest = from when they are legal for their next flight (rest is labelled ASSUMED)."""
    return fetch("SELECT * FROM crew_next_duty_legal(%s,%s)", (scn(scenario_id), duty_id))


@r.get("/airport/status")
def airport_status(scenario_id: int | None = None):
    return view("v_airport_status_current", {"scenario_id": scn(scenario_id)})


@r.get("/recovery/plan")
def recovery_plan(scenario_id: int | None = None, case_id: int | None = None):
    """Current recovery plan items (with flight_id so the UI can move a flight to another slot)."""
    return fetch(
        """SELECT v.*, i.flight_id FROM v_recovery_plan_current v
             JOIN recovery_plan_item i ON i.plan_id = v.plan_id AND i.rank = v.rank
            WHERE v.scenario_id = %s AND (%s::int IS NULL OR v.case_id = %s::int) ORDER BY v.plan_id DESC, v.rank""",
        (scn(scenario_id), case_id, case_id),
    )


@r.get("/decisions/log")
def decision_log(scenario_id: int | None = None, case_id: int | None = None, limit: int = Query(500, le=5000)):
    return view("v_decision_log", {"scenario_id": scn(scenario_id), "case_id": case_id}, "ORDER BY decided_at DESC", limit)


@r.get("/timeline")
def timeline(case_id: int, limit: int = Query(500, le=5000)):
    """Shared timeline: feed, airport, decisions, approvals, crew, comments on one clock."""
    return view("v_case_timeline", {"case_id": case_id}, "ORDER BY occurred_at", limit)


@r.get("/feed/freshness")
def feed_freshness():
    return view("v_feed_freshness")


@r.get("/exceptions")
def exceptions(scenario_id: int | None = None):
    """Open data-quality / verification items (scenario-less import findings are always included)."""
    return fetch("SELECT * FROM v_open_exceptions WHERE scenario_id = %s OR scenario_id IS NULL", (scn(scenario_id),))


@r.get("/recommendations/options")
def recommendation_options(case_id: int, flight_id: int | None = None, scenario_id: int | None = None):
    """Options panel: every ranked option (HOLD + each alternate) of the open recommendation, with blocking constraints.
    option_id is joined in so a decision can reference the exact option chosen.
    A flight can be watched by several cases of one scenario but the engine keeps ONE open recommendation per flight and
    scenario, so options are looked up by flight (for the flights of this case), not by the case that last refreshed them."""
    return fetch(
        """SELECT v.*, o.option_id FROM v_recommendation_options v
             JOIN recommendation_option o ON o.rec_id = v.rec_id AND o.rank = v.rank
            WHERE v.scenario_id = %s
              AND EXISTS (SELECT 1 FROM case_flight cf WHERE cf.case_id = %s AND cf.flight_id = v.flight_id)
              -- only the OPEN recommendation: an executed one (ACCEPTED) is history and is shown only while nothing newer is open,
              -- otherwise an aircraft that already diverted would again be offered "Divert to ..." and two options would both be #1
              AND (v.rec_status = 'PROPOSED'
                   OR (v.rec_status = 'ACCEPTED' AND NOT EXISTS (SELECT 1 FROM recommendation r2
                                                                  WHERE r2.scenario_id = v.scenario_id AND r2.flight_id = v.flight_id AND r2.status = 'PROPOSED')))
              AND (%s::bigint IS NULL OR v.flight_id = %s::bigint)
            ORDER BY v.flight_no, v.rank LIMIT 2000""",
        (scn(scenario_id), case_id, flight_id, flight_id),
    )


@r.get("/diversions")
def diversions(scenario_id: int | None = None, case_id: int | None = None):
    """Station-side tracking of diverted aircraft (what is it waiting for?)."""
    return view("diversion", {"scenario_id": scn(scenario_id), "case_id": case_id}, "ORDER BY diversion_id")


@r.get("/comments")
def comments(case_id: int, flight_id: int | None = None):
    return fetch(
        """SELECT c.comment_id, c.flight_id, c.parent_comment_id, c.kind, c.body, c.author_role, c.created_at, u.display_name AS author
             FROM case_comment c JOIN app_user u ON u.user_id = c.author_id
            WHERE c.case_id = %s AND (%s::bigint IS NULL OR c.flight_id = %s::bigint) ORDER BY c.created_at""",
        (case_id, flight_id, flight_id),
    )


@r.get("/airport-pairs")
def airport_pairs(frm: str = Query(..., alias="from"), to: str | None = None):
    """Distance and travel time between airports: flying and block time, trip fuel (kg), and road time for hub-alternate pairs.
    Every measure has a basis (HISTORICAL, MIRRORED, COMPUTED, ESTIMATED or SYNTHETIC) so generated values are never mistaken for real ones."""
    to = to.upper() if to else None
    return fetch(
        """SELECT * FROM airport_pair_travel WHERE from_iata = %s AND (%s::text IS NULL OR to_iata = %s) ORDER BY to_iata LIMIT 500""",
        (frm.upper(), to, to),
    )


@r.get("/fuel")
def fuel(scenario_id: int | None = None):
    """Latest holding-endurance estimate per flight, with its quality label."""
    return fetch(
        """SELECT DISTINCT ON (flight_id) flight_id, as_of_utc, est_holding_endurance_min, fuel_on_board_kg, quality, basis
             FROM flight_fuel_estimate WHERE scenario_id = %s ORDER BY flight_id, as_of_utc DESC, estimate_id DESC""",
        (scn(scenario_id),),
    )


@r.get("/queue")
def queue():
    """Reassessment queue health (the worker drains it)."""
    return fetch("SELECT status, count(*) AS n, max(enqueued_at) AS latest FROM reassessment_queue GROUP BY status ORDER BY status")
