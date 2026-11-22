"""Reassessment worker (README section 11 contract). Runs inside the API process.

  LISTEN fogops_reassess -> claim PENDING jobs (SKIP LOCKED) -> recompute legality ->
  latest legal departure for the recovery leg -> hold/divert recommendation for airborne case flights ->
  mark DONE/FAILED -> NOTIFY fogops_updated (the UI refetches).

All writes run as the non-human AGENT user, so the database's guardrails still apply: the worker can
recommend but never decide.
"""
import asyncio
import json
import logging
import time

import psycopg

from . import cache, config, routes_integrations, rules, weather_feed
from .db import fetch, live_scenario_id, tx

log = logging.getLogger("fogops.worker")
LISTEN = "fogops_reassess"
ALERT_EVERY_SEC = 15
FUEL_EVERY_SEC = 60
RECALC_EVERY_SEC = 60
MARGIN_STEP_MIN = 5  # a new recommendation is written when the fuel margin moved by at least this many minutes


def _agent():
    rows = fetch("SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1")
    return str(rows[0]["user_id"]) if rows else None


def _estimate_fuel() -> int:
    """Give every flight in the air (live and replay scenarios) a take-off fuel estimate from route history when it has none."""
    n = 0
    for sc in fetch("SELECT scenario_id FROM scenario WHERE is_active ORDER BY scenario_id"):
        with tx() as conn:
            n += conn.execute("SELECT estimate_airborne_fuel(%s) AS n", (sc["scenario_id"],)).fetchone()["n"] or 0
    return n


_SIG_SQL = """SELECT r.rec_type::text AS rec_type, o1.action::text AS top_action, o1.alternate_iata AS top_alt, o1.fuel_margin_min AS top_margin,
                      coalesce((SELECT string_agg(o.alternate_iata, ',' ORDER BY o.alternate_iata) FROM recommendation_option o
                                 WHERE o.rec_id = r.rec_id AND o.is_executable AND o.alternate_iata IS NOT NULL), '') AS executable,
                      coalesce((SELECT bool_or(o.is_executable AND o.action = 'HOLD') FROM recommendation_option o WHERE o.rec_id = r.rec_id), FALSE) AS hold_ok,
                      r.input_snapshot->>'flight_phase' AS phase
                 FROM recommendation r LEFT JOIN recommendation_option o1 ON o1.rec_id = r.rec_id AND o1.rank = 1
                WHERE r.rec_id = %s"""


def _same_answer(a, b) -> bool:
    """The recommendation did not change in a way a person would act on: same action and top alternate, the same options still
    executable, same phase, and the fuel margin moved by less than MARGIN_STEP_MIN minutes."""
    if a is None or b is None:
        return False
    if any(a[k] != b[k] for k in ("rec_type", "top_action", "top_alt", "executable", "hold_ok", "phase")):
        return False
    ma, mb = a["top_margin"], b["top_margin"]
    if (ma is None) != (mb is None):
        return False
    return ma is None or abs(ma - mb) < MARGIN_STEP_MIN


def _recommend_if_changed(conn, scenario_id: int, case_id: int, flight_id: int) -> bool:
    """Re-run the engine for one flight on the CURRENT fuel and clock. The new recommendation is kept only when the answer changed;
    otherwise the attempt is undone and the open recommendation just has its validity extended (no new row). True = a row was written."""
    prev = conn.execute(
        """SELECT rec_id FROM recommendation WHERE scenario_id = %s AND flight_id = %s AND status = 'PROPOSED'
            ORDER BY generated_at DESC, rec_id DESC LIMIT 1""",
        (scenario_id, flight_id),
    ).fetchone()
    prev_sig = conn.execute(_SIG_SQL, (prev["rec_id"],)).fetchone() if prev else None
    try:
        with conn.transaction():  # a savepoint: undone when nothing changed
            new_id = conn.execute("SELECT recommend_for_flight(%s,%s,%s) AS r", (scenario_id, case_id, flight_id)).fetchone()["r"]
            new_sig = conn.execute(_SIG_SQL, (new_id,)).fetchone() if new_id else None
            if prev and new_id and _same_answer(prev_sig, new_sig):
                raise psycopg.Rollback()
        return True
    except psycopg.Rollback:
        conn.execute(
            "UPDATE recommendation SET valid_until_utc = scenario_now(scenario_id) + interval '15 minutes' WHERE rec_id = %s",
            (prev["rec_id"],),
        )
        return False


def _recalc_fuel_recommendations() -> int:
    """Scenarios on the REAL wall clock (the live one) change with the fuel all the time, but nothing ticks them: once a minute re-run the
    engine, on the current fuel, for every flight that is holding or airborne in a case. Scenarios on a stored clock are covered by the
    clock tick (_tick_running_clocks -> _reassess), which uses the same change-only rule; a paused clock cannot change, so it is left alone."""
    agent = _agent()
    if agent is None:
        return 0
    todo = fetch(
        """SELECT s.scenario_id, cf.case_id, s.flight_id
             FROM flight_state s
             JOIN scenario sc ON sc.scenario_id = s.scenario_id AND sc.is_active AND sc.sim_clock_utc IS NULL
             JOIN disruption_case dc ON dc.scenario_id = s.scenario_id
             JOIN case_flight cf ON cf.case_id = dc.case_id AND cf.flight_id = s.flight_id
            WHERE s.status IN ('AIRBORNE', 'HOLDING')
              AND NOT EXISTS (SELECT 1 FROM decision d WHERE d.scenario_id = s.scenario_id AND d.flight_id = s.flight_id
                               AND d.status IN ('PROPOSED', 'APPROVED'))
            ORDER BY s.scenario_id, s.flight_id"""
    )
    changed: dict[int, int] = {}
    for t_ in todo:
        try:
            with tx(agent) as conn:
                if _recommend_if_changed(conn, t_["scenario_id"], t_["case_id"], t_["flight_id"]):
                    changed[t_["scenario_id"]] = changed.get(t_["scenario_id"], 0) + 1
        except Exception:  # noqa: BLE001 - one flight must not stop the others
            log.exception("fuel recalculation failed for flight %s (scenario %s)", t_["flight_id"], t_["scenario_id"])
    if changed:
        with tx() as conn:
            for scn, n in changed.items():
                conn.execute("SELECT pg_notify('fogops_updated', %s)", (json.dumps({"scenario_id": scn, "reason": "fuel", "changed": n}),))
    return sum(changed.values())


def _flights_for(conn, job) -> list[int]:
    scn, et, eid = job["scenario_id"], job["entity_type"], job["entity_id"]
    if et == "flight":
        return [int(eid)]
    if et == "crew_duty":
        q = "SELECT DISTINCT flight_id FROM crew_duty_leg WHERE scenario_id = %s AND duty_id = %s AND is_active"
        return [r["flight_id"] for r in conn.execute(q, (scn, int(eid))).fetchall()]
    if et == "decision":
        q = "SELECT flight_id FROM decision WHERE decision_id = %s AND flight_id IS NOT NULL"
        return [r["flight_id"] for r in conn.execute(q, (int(eid),)).fetchall()]
    # airport status changed: every watched flight of that scenario is affected
    q = "SELECT cf.flight_id FROM case_flight cf JOIN disruption_case dc ON dc.case_id = cf.case_id WHERE dc.scenario_id = %s"
    return [r["flight_id"] for r in conn.execute(q, (scn,)).fetchall()]


def _reassess(conn, job):
    scn = job["scenario_id"]
    tick = job.get("reason") == "CLOCK_TICK"   # the once-a-minute tick of a running clock: write a recommendation only when it changed
    for fid in _flights_for(conn, job):
        with conn.transaction():  # one bad flight must not fail the whole job
            conn.execute("SELECT compute_flight_legality(%s,%s,'worker')", (scn, fid))
            rf = conn.execute("SELECT recovery_flight_id FROM diversion WHERE scenario_id = %s AND original_flight_id = %s AND recovery_flight_id IS NOT NULL", (scn, fid)).fetchone()
            if rf:
                conn.execute("SELECT compute_latest_departure(%s,%s)", (scn, rf["recovery_flight_id"]))
            # airborne case flights get a fresh recommendation, unless a human decision is already in flight
            cases = conn.execute(
                """SELECT cf.case_id FROM case_flight cf
                     JOIN disruption_case dc ON dc.case_id = cf.case_id
                     JOIN flight_state s ON s.flight_id = cf.flight_id AND s.scenario_id = dc.scenario_id
                    WHERE dc.scenario_id = %s AND cf.flight_id = %s
                      AND s.status IN ('AIRBORNE','HOLDING','DIVERTING','LANDED','ON_BLOCKS','SCHEDULED','TAXI_OUT')
                      -- do not re-recommend while a decision is waiting for approval or approved but not yet executed
                      AND NOT EXISTS (SELECT 1 FROM decision d WHERE d.scenario_id = dc.scenario_id AND d.flight_id = cf.flight_id
                                       AND d.status IN ('PROPOSED','APPROVED'))""",
                (scn, fid),
            ).fetchall()
            for c in cases:
                if tick:
                    _recommend_if_changed(conn, scn, c["case_id"], fid)
                else:
                    conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (scn, c["case_id"], fid))


def process_pending() -> int:
    """Drain the queue. Returns how many jobs were handled."""
    agent = _agent()
    if agent is None:
        return 0
    done = 0
    while True:
        with tx(agent) as conn:
            job = conn.execute(
                """UPDATE reassessment_queue SET status = 'RUNNING', picked_at = now()
                    WHERE job_id = (SELECT job_id FROM reassessment_queue WHERE status = 'PENDING'
                                     ORDER BY enqueued_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING *"""
            ).fetchone()
        if not job:
            return done
        try:
            with tx(agent) as conn:
                _reassess(conn, job)
                conn.execute("UPDATE reassessment_queue SET status = 'DONE', done_at = now() WHERE job_id = %s", (job["job_id"],))
                conn.execute("SELECT pg_notify('fogops_updated', %s)", (json.dumps({"job_id": job["job_id"], "scenario_id": job["scenario_id"]}),))
            cache.clear()   # the re-check is committed: the next read must see it
        except Exception as e:  # noqa: BLE001 - record and carry on with the next job
            log.exception("reassessment job %s failed", job["job_id"])
            with tx(agent) as conn:
                conn.execute("UPDATE reassessment_queue SET status = 'FAILED', done_at = now(), error = %s WHERE job_id = %s", (str(e)[:500], job["job_id"]))
        done += 1


def _tick_running_clocks():
    for row in fetch("SELECT scenario_id FROM scenario WHERE clock_running AND sim_clock_utc IS NOT NULL"):
        with tx() as conn:
            conn.execute("SELECT enqueue_reassessment(%s, 'CLOCK_TICK', 'scenario', %s)", (row["scenario_id"], str(row["scenario_id"])))


async def run():
    while True:
        try:
            async with await psycopg.AsyncConnection.connect(config.DSN, autocommit=True) as conn:
                await conn.execute(f"LISTEN {LISTEN}")
                last_alert = 0.0
                last_tick = 0.0
                last_fuel = 0.0
                last_recalc = 0.0
                last_weather = 0.0
                while True:
                    await asyncio.to_thread(process_pending)  # also drains anything queued while we were away
                    try:  # entries for switched-off systems become manual tasks
                        await asyncio.to_thread(routes_integrations.settle)
                    except Exception:  # noqa: BLE001
                        log.exception("integration outbox settle failed")
                    if time.monotonic() - last_alert >= ALERT_EVERY_SEC:  # custom ALERT rules: fire when a flight starts matching
                        last_alert = time.monotonic()
                        try:
                            agent = _agent()
                            if agent:
                                await asyncio.to_thread(rules.evaluate_alerts, agent)
                        except Exception:  # noqa: BLE001 - alerts must never stop the reassessment loop
                            log.exception("alert rule evaluation failed")
                    if time.monotonic() - last_tick >= 60:  # a RUNNING scenario clock moves on its own: refresh stored margins once a minute
                        last_tick = time.monotonic()
                        try:
                            await asyncio.to_thread(_tick_running_clocks)
                        except Exception:  # noqa: BLE001
                            log.exception("clock tick failed")
                    if time.monotonic() - last_fuel >= FUEL_EVERY_SEC:  # airborne flights without a fuel figure get an estimate
                        last_fuel = time.monotonic()
                        try:
                            await asyncio.to_thread(_estimate_fuel)
                        except Exception:  # noqa: BLE001 - must never stop the reassessment loop
                            log.exception("fuel estimate failed")
                    if time.monotonic() - last_recalc >= RECALC_EVERY_SEC:  # recommendations follow the current fuel
                        last_recalc = time.monotonic()
                        try:
                            await asyncio.to_thread(_recalc_fuel_recommendations)
                        except Exception:  # noqa: BLE001 - must never stop the reassessment loop
                            log.exception("fuel recalculation failed")
                    if config.WEATHER_FEED_ENABLED and time.monotonic() - last_weather >= config.WEATHER_EVERY_SEC:  # open weather data, never an airport status
                        last_weather = time.monotonic()
                        await asyncio.to_thread(weather_feed.pull_once)  # never raises
                    async for _ in conn.notifies(timeout=5):
                        break
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("worker connection lost, retrying")
            await asyncio.sleep(3)
