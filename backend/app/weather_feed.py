"""Live weather feed (migration 026): METAR + TAF for the hub and the alternates from aviationweather.gov (public, no key).

What it does: every WEATHER_EVERY_SEC (default 600) it stores new observations in fogops.weather_obs / weather_taf (source 'AWC', quality
EXTERNAL_OBSERVED / EXTERNAL_FORECAST) and, when a station crosses a visibility threshold (fog / mist / clear), queues a reassessment for the open
LIVE cases at that hub so the recommendation follows the weather.
What it never does: change an airport's status, enter a reopening time, or decide anything (those stay human entries). It is off unless
WEATHER_FEED_ENABLED=true. A network failure only means the data goes stale (the engine ignores observations older than weather_max_age_min);
it never raises into the worker loop. Only public ICAO station codes are sent.
"""
import json
import logging
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from .db import fetch, tx

log = logging.getLogger("fogops.weather")
AWC = "https://aviationweather.gov/api/data"
M_PER_MILE = 1609.344


def _get(path: str, params: dict):
    url = f"{AWC}/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "fogops-weather-feed"}), timeout=20) as r:
        body = r.read().decode("utf-8", "replace")
    return json.loads(body) if body.strip() else []


def _vis_m(v):
    """aviationweather.gov gives statute miles as a number or a string such as '10+'."""
    if v is None:
        return None
    if isinstance(v, str):
        if v.endswith("+"):
            return 9999
        try:
            v = float(v)
        except ValueError:
            return None
    return 9999 if v >= 6.2 else int(round(v * M_PER_MILE))


def _num(x):
    try:
        return None if x is None else float(x)
    except (TypeError, ValueError):
        return None


def parse_metar(m: dict):
    ts = m.get("obsTime")
    if ts is None:
        return None
    wd = m.get("wdir")
    return (m["icaoId"], datetime.fromtimestamp(int(ts), tz=timezone.utc), _vis_m(m.get("visib")), wd if isinstance(wd, int) else None,
            _num(m.get("wspd")), _num(m.get("temp")), _num(m.get("dewp")), _num(m.get("altim")), m.get("rawOb"), "AWC")


def taf_min_vis(raw: str):
    """lowest visibility mentioned in the TAF text (CAVOK = 9999); None when nothing parseable"""
    if not raw:
        return None
    vals = [int(t) for t in re.findall(r"(?<![\d/])(\d{4})(?![\d/Z])", re.sub(r"\d{4}/\d{4}|\d{6}Z|\d{5}KT|Q\d{4}", " ", raw))]
    if "CAVOK" in raw:
        vals.append(9999)
    return min(vals) if vals else None


def _category(vis, v_in, v_clear):
    return None if vis is None else 2 if vis < v_in else 1 if vis < v_clear else 0


def pull_once() -> dict:
    """One poll. Returns counts; never raises."""
    try:
        sts = fetch("SELECT s.icao::text AS icao, s.iata::text AS iata, s.role FROM weather_station s ORDER BY s.role DESC, s.icao")
        if not sts:
            return {"stations": 0}
        pol = {r["key"]: float(r["value"]) for r in fetch("SELECT key, value FROM divert_policy WHERE key IN ('fog_vis_in_m','fog_vis_clear_m')")}
        v_in, v_clear = pol.get("fog_vis_in_m", 800), pol.get("fog_vis_clear_m", 1500)
        ids = ",".join(s["icao"] for s in sts)
        metars = _get("metar", {"ids": ids, "format": "json", "hours": 3})
        tafs = _get("taf", {"ids": ids, "format": "json"})
    except Exception as e:  # noqa: BLE001 - offline / service down: data simply goes stale
        log.warning("weather feed skipped: %s", e)
        return {"error": str(e)[:200]}
    agent = fetch("SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1")
    new, changed = 0, []
    with tx(str(agent[0]["user_id"]) if agent else None) as conn:
        for m in metars:
            row = parse_metar(m)
            if row is None:
                continue
            prev = conn.execute("SELECT vsby_m FROM weather_obs WHERE icao = %s AND obs_utc < %s AND vsby_m IS NOT NULL ORDER BY obs_utc DESC LIMIT 1", (row[0], row[1])).fetchone()
            cur = conn.execute("""INSERT INTO weather_obs (icao, obs_utc, vsby_m, wind_dir, wind_kt, temp_c, dewp_c, qnh_hpa, raw, source)
                                  VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING""", row)
            if cur.rowcount:
                new += 1
                if prev and _category(prev["vsby_m"], v_in, v_clear) != _category(row[2], v_in, v_clear):
                    changed.append(row[0])
        for t in tafs:
            try:
                issued = datetime.fromtimestamp(int(t.get("validTimeFrom")), tz=timezone.utc) if t.get("issueTime") is None else datetime.fromisoformat(t["issueTime"].replace("Z", "+00:00"))
                conn.execute("""INSERT INTO weather_taf (icao, issued_utc, valid_from, valid_to, min_vsby_m, raw)
                                VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING""",
                             (t["icaoId"], issued, datetime.fromtimestamp(int(t["validTimeFrom"]), tz=timezone.utc), datetime.fromtimestamp(int(t["validTimeTo"]), tz=timezone.utc),
                              taf_min_vis(t.get("rawTAF")), t.get("rawTAF")))
            except Exception as e:  # noqa: BLE001 - one odd TAF must not drop the METARs
                log.warning("TAF skipped: %s", e)
        # a station crossing a threshold re-ranks the open LIVE cases at that hub
        for icao in set(changed):
            conn.execute("""SELECT enqueue_reassessment(dc.scenario_id, 'WEATHER_CHANGE', 'airport', %s, jsonb_build_object('icao', %s::text))
                              FROM (SELECT DISTINCT d.scenario_id FROM disruption_case d JOIN scenario s ON s.scenario_id = d.scenario_id
                                     WHERE s.kind = 'LIVE' AND s.is_active AND d.phase <> 'CLOSED') dc""", (icao, icao))
    if new:
        log.info("weather feed: %s new observations, %s station(s) crossed a threshold", new, len(set(changed)))
    return {"new": new, "threshold_crossings": sorted(set(changed))}
