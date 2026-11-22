"""Backfill open weather data into fogops.weather_obs / weather_fcst (migration 026). Run by hand; idempotent (a second run inserts 0 rows).

    FOGOPS_DSN=postgresql://... python3 scripts/load_weather.py iem   [first_year] [last_year] [ICAO ...]
    FOGOPS_DSN=postgresql://... python3 scripts/load_weather.py openmeteo [start_date] [end_date]

iem        Iowa Environmental Mesonet METAR archive (free, no key). vsby is statute miles and capped at 6.21 (= 10 km): stored in metres, 9999 = 10 km or more.
openmeteo  Open-Meteo Historical Forecast API (model forecasts as issued, hourly visibility). Free tier: attribution (CC BY 4.0), check the terms before commercial use.
Only public ICAO station codes / coordinates of the airports are sent. Needs psycopg (see requirements.txt); standard library for HTTP.
"""
import csv, io, os, sys, time, urllib.parse, urllib.request
from datetime import date
import psycopg

IEM = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py"
OPENMETEO = "https://historical-forecast-api.open-meteo.com/v1/forecast"
M_PER_MILE = 1609.344


def fnum(x):
    try:
        return None if x in (None, "", "null", "M") else float(x)
    except ValueError:
        return None


def get(url, tries=4):
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "fogops-weather-loader"}), timeout=120) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001 - network: retry then give up on this chunk
            print(f"   retry {k + 1}: {e}", file=sys.stderr)
            time.sleep(3 * (k + 1))
    return None


def iem_rows(icao, year):
    q = [("station", icao)] + [("data", d) for d in ("tmpf", "dwpf", "drct", "sknt", "vsby", "mslp", "metar")] + [
        ("year1", year), ("month1", 1), ("day1", 1), ("year2", year + 1), ("month2", 1), ("day2", 1), ("tz", "Etc/UTC"), ("format", "onlycomma"),
        ("latlon", "no"), ("missing", "null"), ("trace", "null"), ("direct", "no"), ("report_type", 3), ("report_type", 4)]
    text = get(IEM + "?" + urllib.parse.urlencode(q))
    if text is None:
        return None
    out = []
    for r in csv.DictReader(io.StringIO(text)):
        v = fnum(r.get("vsby"))
        vm = None if v is None else (9999 if v >= 6.2 else int(round(v * M_PER_MILE)))
        t, d = fnum(r.get("tmpf")), fnum(r.get("dwpf"))
        out.append((icao, r["valid"] + "+00", vm, None if fnum(r.get("drct")) is None else int(fnum(r["drct"])), fnum(r.get("sknt")),
                    None if t is None else round((t - 32) / 1.8, 1), None if d is None else round((d - 32) / 1.8, 1), fnum(r.get("mslp")),
                    (r.get("metar") or None), "IEM"))
    return out


def load_iem(conn, y0, y1, stations):
    total = 0
    for icao in stations:
        for y in range(y0, y1 + 1):
            rows = iem_rows(icao, y)
            if rows is None:
                print(f"{icao} {y}: download failed, skipped"); continue
            with conn.cursor() as cur:
                cur.execute("CREATE TEMP TABLE _w (LIKE fogops.weather_obs INCLUDING DEFAULTS) ON COMMIT DROP")
                with cur.copy("COPY _w (icao, obs_utc, vsby_m, wind_dir, wind_kt, temp_c, dewp_c, qnh_hpa, raw, source) FROM STDIN") as cp:
                    for r in rows:
                        cp.write_row(r)
                cur.execute("INSERT INTO fogops.weather_obs SELECT * FROM _w ON CONFLICT DO NOTHING")
                n = cur.rowcount
            conn.commit()
            total += n
            print(f"{icao} {y}: {len(rows)} downloaded, {n} new", flush=True)
    print("new rows:", total)


def load_openmeteo(conn, start, end):
    with conn.cursor() as cur:
        cur.execute("SELECT s.icao, a.latitude, a.longitude FROM fogops.weather_station s JOIN fogops.airport a USING (iata) WHERE a.latitude IS NOT NULL")
        sts = cur.fetchall()
    total = 0
    for icao, lat, lon in sts:
        q = {"latitude": float(lat), "longitude": float(lon), "start_date": start, "end_date": end, "timezone": "UTC",
             "hourly": "visibility,relative_humidity_2m,temperature_2m,dew_point_2m,wind_speed_10m"}
        import json
        txt = get(OPENMETEO + "?" + urllib.parse.urlencode(q))
        if txt is None:
            print(icao, "download failed, skipped"); continue
        h = json.loads(txt)["hourly"]
        rows = [(icao, h["time"][i] + "+00", h["visibility"][i], h["relative_humidity_2m"][i], h["temperature_2m"][i], h["dew_point_2m"][i],
                 None if h["wind_speed_10m"][i] is None else round(h["wind_speed_10m"][i] / 1.852, 1)) for i in range(len(h["time"]))]
        with conn.cursor() as cur:
            cur.executemany("INSERT INTO fogops.weather_fcst (icao, valid_utc, visibility_m, rh_pct, temp_c, dewp_c, wind_kt) VALUES (%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING", rows)
            n = cur.rowcount
        conn.commit(); total += max(n, 0)
        print(f"{icao}: {len(rows)} hours downloaded", flush=True)
    print("done")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("iem", "openmeteo"):
        sys.exit(__doc__)
    with psycopg.connect(os.environ["FOGOPS_DSN"]) as conn:
        if sys.argv[1] == "iem":
            y0 = int(sys.argv[2]) if len(sys.argv) > 2 else 2010
            y1 = int(sys.argv[3]) if len(sys.argv) > 3 else date.today().year
            sts = sys.argv[4:] or [r[0] for r in conn.execute("SELECT icao FROM fogops.weather_station ORDER BY role DESC, icao").fetchall()]
            load_iem(conn, y0, y1, sts)
        else:
            load_openmeteo(conn, sys.argv[2] if len(sys.argv) > 2 else "2022-01-01", sys.argv[3] if len(sys.argv) > 3 else date.today().isoformat())


if __name__ == "__main__":
    main()
