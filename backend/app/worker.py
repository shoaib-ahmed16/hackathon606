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

from . import config, routes_integrations, rules
from .db import fetch, live_scenario_id, tx

log = logging.getLogger("fogops.worker")
LISTEN = "fogops_reassess"
ALERT_EVERY_SEC = 15
FUEL_EVERY_SEC = 60


def _agent():
    rows = fetch("SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1")
    return str(rows[0]["user_id"]) if rows else None


def _estimate_fuel() -> int:
    """Give every airborne flight of the live scenario an ESTIMATED fuel figure (from route history) when it has none."""
    scn = live_scenario_id()
    if scn is None:
        return 0
    with tx() as conn:
        return conn.execute("SELECT estimate_airborne_fuel(%s) AS n", (scn,)).fetchone()["n"] or 0


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
                    async for _ in conn.notifies(timeout=5):
                        break
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("worker connection lost, retrying")
            await asyncio.sleep(3)
