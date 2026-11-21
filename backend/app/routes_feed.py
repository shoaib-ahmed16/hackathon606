"""Simulated live feed: one call pushes "what has happened by now" into the LIVE scenario.

For every scheduled flight that should have moved by `as_of` (default: now) it sends OUT / OFF / ON / IN
events through the same DB function a real feed uses (`ingest_flight_event`), so dedupe, out-of-order
protection, status derivation, legality reassessment and audit all behave exactly as in production.

Safe to press repeatedly: message ids are fixed per flight and stage (`PUSH-<flight>-<stage>`), so a stage that
was already pushed comes back as DUPLICATE. Fields a real source already filled are never overwritten.
Flights that are cancelled, holding or diverted are left alone.

Beyond flights, the same push moves the rest of the operational picture forward:
  - passengers on board (in the OUT event, from the planned load)
  - crew duties: PLANNED -> ACTIVE (first leg out) -> COMPLETED (last leg in blocks)
  - standby slots: AVAILABLE -> RELEASED once their window has ended
  - fuel on board for airborne flights (quality SIMULATED, refreshed at most every 10 minutes)
Airport status (fog, closures) is deliberately NOT simulated: it drives the disruption cases and must stay a
human/OCC input.
"""
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from psycopg.types.json import Jsonb
from pydantic import BaseModel

from .db import live_scenario_id, tx
from .deps import actor

r = APIRouter(prefix="/api/feed", tags=["feed"])

SOURCE = "SIM_FEED"
LOOKBACK = timedelta(hours=36)  # do not replay older history than this


class PushBody(BaseModel):
    as_of: datetime | None = None  # defaults to the server's current time (UTC); handy to test a chosen moment


def _plan(f, s, as_of):
    """Stage events due by as_of. Actual values already in flight_state win over the simulated ones."""
    h = (f["flight_id"] * 2654435761) % 997  # stable per flight, so repeat pushes agree
    delay = timedelta(minutes=h % 16)  # 0-15 min late off blocks
    taxi_out = timedelta(minutes=10 + h % 6)
    taxi_in = timedelta(minutes=5)
    block = f["sta_utc"] - f["std_utc"]
    air = max(block - taxi_out - taxi_in, timedelta(minutes=10))

    atd = (s or {}).get("atd_utc") or f["std_utc"] + delay
    toff = (s or {}).get("toff_utc") or atd + taxi_out
    tdown = (s or {}).get("tdown_utc") or toff + air
    ata = (s or {}).get("ata_utc") or tdown + taxi_in

    stages = [  # (type, event time, payload key, already known?)
        ("OUT", atd, "atd", (s or {}).get("atd_utc")),
        ("OFF", toff, "toff", (s or {}).get("toff_utc")),
        ("ON", tdown, "tdown", (s or {}).get("tdown_utc")),
        ("IN", ata, "ata", (s or {}).get("ata_utc")),
    ]
    out = []
    for typ, ts, key, known in stages:
        if known is not None or ts > as_of:
            continue
        payload = {key: ts.isoformat()}
        if typ == "OUT":
            payload["eta"] = tdown.isoformat()  # estimate shown while it is in the air
            if f.get("pax_planned") is not None and f.get("pax") is None:
                payload["pax"] = round(f["pax_planned"] * (0.85 + (h % 12) / 100))  # 85-96% load
        out.append((typ, ts, payload))
    return out


@r.post("/push")
def push(body: PushBody | None = None, user=Depends(actor)):
    """Push the simulated current picture into the LIVE scenario. Returns what was applied."""
    as_of = (body.as_of if body and body.as_of else datetime.now(timezone.utc))
    if as_of.tzinfo is None:
        as_of = as_of.replace(tzinfo=timezone.utc)
    scn = live_scenario_id()
    counts: dict[str, int] = {}
    flights_touched = 0

    with tx(user) as conn:
        rows = conn.execute(
            """SELECT f.flight_id, f.std_utc, f.sta_utc, f.pax_planned, s.pax,
                      s.atd_utc, s.toff_utc, s.tdown_utc, s.ata_utc
                 FROM flight f
                 LEFT JOIN flight_state s ON s.scenario_id = %(scn)s AND s.flight_id = f.flight_id
                WHERE f.flight_kind = 'SCHEDULED'
                  AND f.std_utc <= %(as_of)s AND f.std_utc >= %(since)s
                  AND s.ata_utc IS NULL
                  AND coalesce(s.is_cancelled, FALSE) = FALSE
                  AND coalesce(s.is_holding, FALSE) = FALSE
                  AND (s.actual_arr_iata IS NULL OR s.actual_arr_iata = f.arr_iata)
                  AND NOT EXISTS (SELECT 1 FROM diversion d
                                   WHERE d.scenario_id = %(scn)s AND d.original_flight_id = f.flight_id)
                ORDER BY f.std_utc""",
            {"scn": scn, "as_of": as_of, "since": as_of - LOOKBACK},
        ).fetchall()

        for f in rows:
            events = _plan(f, f, as_of)
            if not events:
                continue
            flights_touched += 1
            for typ, ts, payload in events:
                res = conn.execute(
                    "SELECT ingest_flight_event(%s,%s,%s,%s,%s,%s,%s,%s)",
                    (scn, SOURCE, f"PUSH-{f['flight_id']}-{typ}", f["flight_id"], typ, ts, Jsonb(payload), None),
                ).fetchone()
                result = next(iter(res.values()))
                counts[result] = counts.get(result, 0) + 1

        # ---- crew, standby and fuel follow what the flights just did (state is read after the events above)
        duties_active = conn.execute(
            """UPDATE crew_duty d SET status = 'ACTIVE'
                WHERE d.status = 'PLANNED'
                  AND EXISTS (SELECT 1 FROM crew_duty_leg l JOIN flight_state s
                                ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
                               WHERE l.scenario_id = %s AND l.duty_id = d.duty_id AND l.is_active
                                 AND s.atd_utc IS NOT NULL)""", (scn,)).rowcount
        duties_done = conn.execute(
            """UPDATE crew_duty d SET status = 'COMPLETED'
                WHERE d.status IN ('PLANNED','ACTIVE')
                  AND EXISTS (SELECT 1 FROM crew_duty_leg l WHERE l.scenario_id = %(s)s AND l.duty_id = d.duty_id AND l.is_active)
                  AND NOT EXISTS (SELECT 1 FROM crew_duty_leg l
                                    LEFT JOIN flight_state s ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
                                   WHERE l.scenario_id = %(s)s AND l.duty_id = d.duty_id AND l.is_active
                                     AND s.ata_utc IS NULL)""", {"s": scn}).rowcount
        standby_released = conn.execute(
            "UPDATE standby_slot SET status = 'RELEASED' WHERE status = 'AVAILABLE' AND end_utc < %s", (as_of,)).rowcount
        fuel_rows = conn.execute(
            """INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg,
                                                 burn_rate_hold_kg_per_hr, est_holding_endurance_min, quality, basis)
               SELECT s.scenario_id, s.flight_id, %(as_of)s, fob.kg, 2300, 2400,
                      GREATEST(0, ((fob.kg - 2300) * 60 / 2400)), 'SIMULATED',
                      jsonb_build_object('from', 'simulated live feed: planned fuel less cruise burn since take-off')
                 FROM flight_state s
                 CROSS JOIN LATERAL (SELECT GREATEST(2500, 6500 + (s.flight_id %% 20) * 100
                                          - (2400 * EXTRACT(EPOCH FROM (%(as_of)s - s.toff_utc)) / 3600)::int) AS kg) fob
                WHERE s.scenario_id = %(scn)s AND s.toff_utc IS NOT NULL AND s.tdown_utc IS NULL
                  AND NOT EXISTS (SELECT 1 FROM flight_fuel_estimate e
                                   WHERE e.scenario_id = s.scenario_id AND e.flight_id = s.flight_id
                                     AND e.as_of_utc > %(as_of)s - interval '10 minutes')""",
            {"as_of": as_of, "scn": scn}).rowcount

    return {
        "as_of": as_of.isoformat(),
        "scenario_id": scn,
        "flights_updated": flights_touched,
        "events": counts,
        "events_applied": sum(v for k, v in counts.items() if k != "DUPLICATE"),
        "crew_duties_active": duties_active,
        "crew_duties_completed": duties_done,
        "standby_released": standby_released,
        "fuel_estimates": fuel_rows,
    }
