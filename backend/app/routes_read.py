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
        """SELECT c.*, s.name AS scenario_name, s.kind AS scenario_kind, s.sim_clock_utc
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
        f"""SELECT w.*, sv.severity_score, sv.connecting_pax,
                   COALESCE((SELECT array_agg(ft.tag ORDER BY ft.tag) FROM flight_tag ft WHERE ft.scenario_id = w.scenario_id AND ft.flight_id = w.flight_id), '{{}}'::text[]) AS tags
              FROM v_flight_watch w
              LEFT JOIN v_flight_severity sv ON sv.case_id = w.case_id AND sv.flight_id = w.flight_id AND sv.scenario_id = w.scenario_id
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
