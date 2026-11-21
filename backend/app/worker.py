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

import psycopg

from . import config
from .db import fetch, tx

log = logging.getLogger("fogops.worker")
LISTEN = "fogops_reassess"


def _agent():
    rows = fetch("SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1")
    return str(rows[0]["user_id"]) if rows else None


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
                    WHERE dc.scenario_id = %s AND cf.flight_id = %s AND s.status IN ('AIRBORNE','HOLDING')
                      AND NOT EXISTS (SELECT 1 FROM decision d WHERE d.scenario_id = dc.scenario_id AND d.flight_id = cf.flight_id
                                       AND d.status IN ('PROPOSED','APPROVED','EXECUTED'))""",
                (scn, fid),
            ).fetchall()
            for c in cases:
                conn.execute("SELECT propose_hold_or_divert(%s,%s,%s)", (scn, c["case_id"], fid))


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


async def run():
    while True:
        try:
            async with await psycopg.AsyncConnection.connect(config.DSN, autocommit=True) as conn:
                await conn.execute(f"LISTEN {LISTEN}")
                while True:
                    await asyncio.to_thread(process_pending)  # also drains anything queued while we were away
                    async for _ in conn.notifies(timeout=5):
                        break
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("worker connection lost, retrying")
            await asyncio.sleep(3)
