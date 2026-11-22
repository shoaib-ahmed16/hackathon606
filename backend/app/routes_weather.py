"""Weather read endpoints (migrations 026/027). Everything is EXTERNAL data or a model estimate and is labelled so; unknown stays null.

  GET /api/weather/stations     latest observation per station (hub + alternates) with age / freshness, hub fog state and model clearing estimate
  GET /api/weather/model        the active fitted fog model runs with their held-out metrics
  GET /api/weather/{iata}       one station: last 24 h of observations, latest TAF, fog forecast / alternate fog risk
Nothing here changes an airport status: when the hub is in fog but nobody has entered CLOSED/RESTRICTED the response carries a plain-language
suggestion for the OCC to act on; a person still enters the status.
"""
from fastapi import APIRouter, HTTPException

from .db import fetch
from .routes_console import now_utc, scn

r = APIRouter(prefix="/api/weather", tags=["weather"])
QUALITY = {"obs": "EXTERNAL_OBSERVED", "taf": "EXTERNAL_FORECAST", "model": "ESTIMATED_MODEL"}


def _stations():
    return fetch("SELECT s.icao::text AS icao, s.iata::text AS iata, s.role FROM weather_station s ORDER BY s.role DESC, s.iata")


@r.get("/stations")
def stations(scenario_id: int | None = None):
    s = scn(scenario_id)
    now = now_utc(s)
    mode = fetch("SELECT use_external_weather FROM scenario WHERE scenario_id = %s", (s,))
    out = []
    for st in _stations():
        o = fetch("""SELECT obs_utc, vsby_m, wind_dir, wind_kt, temp_c, dewp_c, qnh_hpa, raw, source FROM weather_obs
                      WHERE icao = %s AND obs_utc <= %s ORDER BY obs_utc DESC LIMIT 1""", (st["icao"], now))
        age = None if not o else round((now - o[0]["obs_utc"]).total_seconds() / 60)
        max_age = float(fetch("SELECT value FROM divert_policy WHERE key = 'weather_max_age_min'")[0]["value"])
        row = {**st, "observation": (o[0] | {"quality": QUALITY["obs"]}) if o else None, "age_min": age, "fresh": age is not None and age <= max_age}
        if st["role"] == "HUB":
            f = fetch("SELECT * FROM fog_clear_forecast(%s, %s)", (st["icao"], now))
            row["fog"] = (f[0] | {"quality": f[0]["quality"] or None}) if f else None
            fe = fetch("SELECT * FROM fog_clear_forecast_entered(%s, %s, %s)", (s, st["iata"], now))
            row["fog_from_entered_status"] = fe[0] if fe else None   # what the engine uses when the switch is off
            status = fetch("SELECT op_status::text AS op_status FROM v_airport_status_current WHERE scenario_id = %s AND iata = %s", (s, st["iata"]))
            cur = status[0]["op_status"] if status else None
            row["status_entered"] = cur
            if f and f[0]["in_fog"] and f[0]["fresh"] and cur not in ("CLOSED", "RESTRICTED"):
                row["suggestion"] = (f"Fog observed at {st['iata']} (visibility {f[0]['vis_m']} m for {f[0]['age_min']} min) but no CLOSED/RESTRICTED status is entered. "
                                     + (f"The model expects clearing in about {round(f[0]['p50_min'])} min (P10 {round(f[0]['p10_min'])}, P90 {round(f[0]['p90_min'])}), ESTIMATED. " if f[0]["p50_min"] is not None else "")
                                     + "Enter the airport status to start recommendations.")
        out.append(row)
    return {"scenario_id": s, "as_of_utc": now, "use_external_weather": bool(mode and mode[0]["use_external_weather"]), "quality": QUALITY, "stations": out}


@r.get("/model")
def model():
    runs = fetch("""SELECT run_id, icao::text AS icao, trained_at, train_from, train_to, test_from, test_to, n_episodes_train, n_episodes_test, n_samples, params, metrics, is_active
                      FROM fog_model_run ORDER BY run_id DESC LIMIT 10""")
    return {"quality": QUALITY["model"], "runs": runs}


@r.get("/{iata}")
def station(iata: str, scenario_id: int | None = None):
    s = scn(scenario_id)
    now = now_utc(s)
    st = fetch("SELECT icao::text AS icao, iata::text AS iata, role FROM weather_station WHERE iata = %s", (iata.upper(),))
    if not st:
        raise HTTPException(404, "No weather station configured for this airport")
    st = st[0]
    obs = fetch("""SELECT obs_utc, vsby_m, wind_dir, wind_kt, temp_c, dewp_c, qnh_hpa, raw, source FROM weather_obs
                    WHERE icao = %s AND obs_utc <= %s AND obs_utc > %s - interval '24 hours' ORDER BY obs_utc DESC""", (st["icao"], now, now))
    taf = fetch("""SELECT issued_utc, valid_from, valid_to, min_vsby_m, raw FROM weather_taf WHERE icao = %s AND issued_utc <= %s ORDER BY issued_utc DESC LIMIT 1""", (st["icao"], now))
    mode = fetch("SELECT use_external_weather FROM scenario WHERE scenario_id = %s", (s,))
    body = {**st, "as_of_utc": now, "use_external_weather": bool(mode and mode[0]["use_external_weather"]), "observations": obs, "observation_quality": QUALITY["obs"], "taf": taf[0] if taf else None, "taf_quality": QUALITY["taf"]}
    if st["role"] == "HUB":
        f = fetch("SELECT * FROM fog_clear_forecast(%s, %s)", (st["icao"], now))
        body["fog_forecast"] = f[0] if f else None
    else:
        hub = fetch("SELECT icao::text AS icao FROM weather_station WHERE role = 'HUB' LIMIT 1")
        fz = fetch("SELECT in_fog FROM fog_state(%s, %s)", (hub[0]["icao"], now)) if hub else []
        risk = fetch("SELECT * FROM alt_fog_risk(%s, %s, %s)", (st["icao"], fz[0]["in_fog"] if fz and fz[0]["in_fog"] is not None else True, now))
        body["fog_risk_next_hour"] = risk[0] if risk else None
    return body
