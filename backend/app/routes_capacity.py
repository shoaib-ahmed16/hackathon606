"""Airport capacity: stands, arrivals per hour and occupancy for the hub and the alternates, with the source of every number.

Everything is read from the database functions of migration 003_stand_capacity (airport_capacity_assess, airport_capacity_resolve,
airport_stays, airport_history_profile); this module only reshapes their output for the Airport capacity screen.
Honesty rules carried through: unknown stays null (never 0), a figure taken from history is a lower bound (the screen marks it >=),
and occupancy is derived from Air Arabia movements, not verified real-time data.

  GET  /api/airports/capacity                  one row per airport (hub + active alternates)
  GET  /api/airports/capacity/compare          the same airports assessed for one flight / extra flights / a delay, side by side
  GET  /api/airports/{iata}/capacity           one airport in depth: assessment, hourly outlook, history, traffic around now
  GET  /api/airports/{iata}/capacity/assess    the raw assessment (what-if)
  PUT  /api/airports/{iata}/capacity           OCC / admin states an assumed capacity (with who or what says so)
"""
import time
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from .db import fetch, tx
from .deps import actor, current_user
from .routes_console import scn

r = APIRouter(prefix="/api/airports", tags=["capacity"])
WRITERS = ("OCC", "ADMIN")


def _airports(s: int):
    """The hub first, then the active alternates in their priority order."""
    return fetch(
        """SELECT ap.iata, ap.name, ap.is_hub
             FROM airport ap LEFT JOIN alternate_airport aa ON aa.alt_iata = ap.iata AND aa.is_active
            WHERE ap.is_hub OR aa.alt_iata IS NOT NULL
            ORDER BY ap.is_hub DESC, aa.priority NULLS FIRST, ap.iata""")


# The hub alone takes about 2 s to assess and the screen refreshes every 10 s, so an assessment is reused for a few seconds (and dropped at once by any saved change).
# (The list and the compare table use the same default assessment, so one pass serves both.)
_CACHE: dict = {}
TTL = 8


def _assess(s, iata, flight_id=None, extra=0, delay_min=0, window_h=12, arrival_utc=None):
    key = (s, iata, flight_id, extra, delay_min, window_h, arrival_utc)
    hit = _CACHE.get(key)
    if hit and hit[0] > time.time():
        return hit[1]
    row = fetch("SELECT airport_capacity_assess(%s,%s,%s,%s,%s,%s,%s) AS a", (s, iata, arrival_utc, extra, flight_id, delay_min, window_h))
    if len(_CACHE) > 300:
        _CACHE.clear()
    _CACHE[key] = (time.time() + TTL, row[0]["a"])
    return row[0]["a"]


def _cfg(iata):
    row = fetch("SELECT stands_assumed, arrivals_per_hr_assumed, basis FROM airport_capacity WHERE iata = %s", (iata,))
    return row[0] if row else {}


def _latest(*ts):
    ts = [t for t in ts if t]
    return max(ts) if ts else None


def _diverted_in(s, iata):
    """Flights diverted TO this airport that have not landed yet (executed or approved diversions): they will need a stand and an arrival slot."""
    row = fetch(
        """SELECT count(*)::int AS n, min(eta) AS first_eta, string_agg(flight_no, ', ' ORDER BY flight_no) AS flights FROM (
           SELECT coalesce(fs.eta_utc, f.sta_utc) AS eta, f.flight_no
             FROM diversion d JOIN flight f ON f.flight_id = d.original_flight_id
             LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = d.scenario_id
            WHERE d.scenario_id = %s AND d.alternate_iata = %s AND d.status <> 'CANCELLED' AND d.landed_alt_utc IS NULL
           UNION ALL   -- an APPROVED diversion not yet executed already claims the stand (the OCC executes it next)
           SELECT coalesce(fs.eta_utc, f.sta_utc), f.flight_no
             FROM decision x JOIN flight f ON f.flight_id = x.flight_id
             LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = x.scenario_id
            WHERE x.scenario_id = %s AND x.alternate_iata = %s AND x.decision_type = 'DIVERT' AND x.status = 'APPROVED') u""", (s, iata, s, iata))
    return row[0] if row else {"n": 0, "first_eta": None, "flights": None}


def _row(ap, a, s=None):
    st, ar, oc, h = a["stands"], a["arrivals_per_hr"], a["occupancy"], a["history"]
    dv = _diverted_in(s, ap["iata"]) if s is not None else {"n": 0, "first_eta": None, "flights": None}
    cfg = _cfg(ap["iata"])
    now_known, now_unknown = oc["on_ground_now_known_departure"], oc["on_ground_now_no_known_departure"]
    return {
        "airport": ap["iata"], "name": ap["name"], "is_hub": ap["is_hub"], "airport_op_status": a.get("airport_op_status"),
        "stands_total": st["total"], "stands_source": st["source"], "stands_basis": st["basis"],
        "occupied_stands": (now_known + now_unknown) if oc["movement_evidence"] else None,   # no movement in the data = unknown, not zero
        "occupied_without_known_departure": now_unknown if oc["movement_evidence"] else None,
        "available_stands": st["free_before"],
        "arrivals_per_hr": ar["capacity"], "arrivals_source": ar["source"], "arrivals_basis": ar["basis"],
        "projected_arrivals": ar["scheduled_in_hour"], "remaining_arrival_capacity": ar["remaining_before"],
        "history_sample_n": h["sample_n"], "history_min_sample_hours": h["min_sample_hours"],
        "history_peak_arrivals_per_hr": h["peak_arrivals_per_hr"], "history_peak_ground": h["peak_ground"],
        "last_updated_utc": _latest(st.get("as_of_utc"), ar.get("as_of_utc")), "computed_at_utc": a["scenario_now_utc"],
        "outcome": a["outcome"],
        "diverted_inbound": dv["n"], "diverted_inbound_flights": dv["flights"], "diverted_inbound_first_eta_utc": dv["first_eta"],
        "available_after_diverted": (st["free_before"] - dv["n"]) if st["free_before"] is not None else None,
        "configured_stands": cfg.get("stands_assumed"), "configured_arrivals_per_hr": cfg.get("arrivals_per_hr_assumed"), "configured_basis": cfg.get("basis"),
    }


@r.get("/capacity", dependencies=[Depends(current_user)])
def capacity(scenario_id: int | None = None):
    s = scn(scenario_id)
    return [_row(ap, _assess(s, ap["iata"]), s) for ap in _airports(s)]


def _first_tight(hourly, margin=1):
    """The first hour in the outlook where a stand or an arrival slot is at or below the margin once the proposed flights are counted."""
    for h in hourly:
        sf, sl = h.get("stands_free_with_proposed"), h.get("arrival_slots_left_with_proposed")
        if (sf is not None and sf <= margin) or (sl is not None and sl <= margin):
            return h["hour_utc"]
    return None


@r.get("/capacity/compare", dependencies=[Depends(current_user)])
def compare(scenario_id: int | None = None, flight_id: int | None = None, extra: int = Query(0, ge=0, le=20), delay_min: int = Query(0, ge=0, le=600),
            window_h: int = Query(12, ge=1, le=48)):
    s = scn(scenario_id)
    margin = int((fetch("SELECT value FROM divert_policy WHERE key = 'capacity_constrained_margin'") or [{"value": 1}])[0]["value"])
    out = []
    for ap in _airports(s):
        a = _assess(s, ap["iata"], flight_id, extra, delay_min, window_h)
        out.append({"airport": ap["iata"], "name": ap["name"], "outcome": a["outcome"],
                    "stands_free_before": a["stands"]["free_before"], "stands_free_after": a["stands"]["free_after"],
                    "arrival_slots_before": a["arrivals_per_hr"]["remaining_before"], "arrival_slots_after": a["arrivals_per_hr"]["remaining_after"],
                    "first_constrained_hour_utc": _first_tight(a["hourly"], margin)})
    return out


@r.get("/{iata}/capacity/assess", dependencies=[Depends(current_user)])
def assess(iata: str, scenario_id: int | None = None, flight_id: int | None = None, extra: int = Query(0, ge=0, le=20),
           delay_min: int = Query(0, ge=0, le=600), window_h: int = Query(12, ge=1, le=48), arrival_utc: datetime | None = None):
    iata = iata.upper()
    if not fetch("SELECT 1 FROM airport WHERE iata = %s", (iata,)):
        raise HTTPException(404, f"Unknown airport {iata}")
    return _assess(scn(scenario_id), iata, flight_id, extra, delay_min, window_h, arrival_utc)


@r.get("/{iata}/capacity", dependencies=[Depends(current_user)])
def detail(iata: str, scenario_id: int | None = None, window_h: int = Query(24, ge=1, le=48)):
    iata = iata.upper()
    ap = fetch("SELECT iata, name, is_hub FROM airport WHERE iata = %s", (iata,))
    if not ap:
        raise HTTPException(404, f"Unknown airport {iata}")
    s = scn(scenario_id)
    a = _assess(s, iata, window_h=window_h)
    now = a["scenario_now_utc"]
    on_ground = fetch(
        """SELECT st.flight_id, st.flight_no, st.registration, st.ta AS arrived_utc, st.ta_actual AS arrival_is_actual, st.td AS departure_utc,
                  st.td_actual AS departure_is_actual, st.diverted
             FROM airport_stays(%s, %s) st
            WHERE st.ta <= %s::timestamptz AND (st.td > %s::timestamptz OR (st.td IS NULL AND st.ta_actual AND %s::timestamptz - st.ta <= interval '48 hours'))
            ORDER BY st.ta DESC LIMIT 60""", (s, iata, now, now, now))
    inbound = fetch(
        """SELECT f.flight_id, f.flight_no, coalesce(fs.registration, f.registration_planned) AS registration, f.dep_iata AS origin,
                  coalesce(fs.eta_utc, f.sta_utc) AS arrival_utc, (fs.eta_utc IS NOT NULL) AS arrival_is_actual, (fs.actual_arr_iata IS NOT NULL AND fs.actual_arr_iata <> f.arr_iata) AS diverted
             FROM flight f LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = %s
            WHERE coalesce(fs.actual_arr_iata, f.arr_iata) = %s AND fs.ata_utc IS NULL AND coalesce(fs.is_cancelled, FALSE) = FALSE
              AND coalesce(fs.eta_utc, f.sta_utc) BETWEEN %s::timestamptz AND %s::timestamptz + make_interval(hours => %s)
            ORDER BY 5 LIMIT 60""", (s, iata, now, now, window_h))
    outbound = fetch(
        """SELECT f.flight_id, f.flight_no, coalesce(fs.registration, f.registration_planned) AS registration, f.arr_iata AS destination,
                  coalesce(fs.etd_utc, f.std_utc) AS departure_utc, (fs.etd_utc IS NOT NULL) AS departure_is_actual
             FROM flight f LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = %s
            WHERE f.dep_iata = %s AND fs.atd_utc IS NULL AND coalesce(fs.is_cancelled, FALSE) = FALSE
              AND coalesce(fs.etd_utc, f.std_utc) BETWEEN %s::timestamptz AND %s::timestamptz + make_interval(hours => %s)
            ORDER BY 5 LIMIT 60""", (s, iata, now, now, window_h))
    profile = fetch("SELECT airport_history_profile(%s) AS p", (iata,))[0]["p"]
    return {**_row(ap[0], _assess(s, iata), s), "assessment": a, "reasons": a["reasons"], "history": a["history"], "history_profile": profile,
            "on_ground": on_ground, "inbound": inbound, "outbound": outbound}


class CapacityIn(BaseModel):
    stands_assumed: int | None = Field(None, ge=0, le=200)
    arrivals_per_hr_assumed: int | None = Field(None, ge=0, le=200)
    basis: str = Field(..., min_length=1, max_length=300)


@r.put("/{iata}/capacity")
def set_capacity(iata: str, b: CapacityIn, user=Depends(actor)):
    """OCC / admin assume a capacity for an airport (used only where there is no current status entry). Basis is mandatory and audited."""
    iata = iata.upper()
    if b.stands_assumed is None and b.arrivals_per_hr_assumed is None:
        raise HTTPException(422, "Give stands, arrivals per hour, or both")
    if not b.basis.strip():
        raise HTTPException(422, "Say who or what states this capacity")
    with tx(user) as conn:
        role = conn.execute("SELECT role_code FROM app_user WHERE user_id = %s", (int(user),)).fetchone()
        if not role or role["role_code"] not in WRITERS:
            raise HTTPException(403, "Only OCC or admin can set an assumed capacity")
        if not conn.execute("SELECT 1 FROM airport WHERE iata = %s", (iata,)).fetchone():
            raise HTTPException(404, f"Unknown airport {iata}")
        _CACHE.clear()  # a saved assumption must show at once, not after the 20 s reuse window
        return conn.execute(
            """INSERT INTO airport_capacity (iata, stands_assumed, arrivals_per_hr_assumed, basis, updated_by, updated_at)
               VALUES (%s,%s,%s,%s,%s, now())
               ON CONFLICT (iata) DO UPDATE SET stands_assumed = EXCLUDED.stands_assumed, arrivals_per_hr_assumed = EXCLUDED.arrivals_per_hr_assumed,
                      basis = EXCLUDED.basis, updated_by = EXCLUDED.updated_by, updated_at = now()
               RETURNING *""",
            (iata, b.stands_assumed, b.arrivals_per_hr_assumed, b.basis.strip(), int(user))).fetchone()
