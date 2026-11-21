"""
Load the Hack606 Fog Ops files into the fogops PostgreSQL schema.

Usage
  pip install pandas openpyxl xlrd psycopg2-binary airportsdata
  export FOGOPS_DSN="postgresql://postgres@localhost:5432/fogops"
  python load_data.py --data-dir /path/to/files

Expected files in --data-dir (names as delivered):
  OCC_Flight_Rotation_20Nov_23Nov26.xls            baseline snapshot (08:48 UTC)
  OCC_Flight_Rotation_as_of_20Nov2026_1645.xls     later snapshot (16:45 UTC) -> diff events
  Crew_duty_sheet_*.xlsx                            duty + standby per day (UTC)
  Crew_Roster_Next_10_Days.xlsx                     roster (LOCAL time of crew base)
  Crew_FDTL.xlsx                                    FDP rule table
  Connecting_pax_data*.xlsx
  Historical_Flight_Data_Jan-Nov_2026.xlsx
  Historical_fuel_data.xlsx
"""
import argparse, glob, hashlib, json, os, re, sys, warnings
from datetime import datetime, timedelta, timezone

import pandas as pd
import psycopg2
from psycopg2.extras import execute_values, Json

warnings.filterwarnings("ignore")
UTC = timezone.utc
BASELINE_TS = datetime(2026, 11, 20, 8, 48, tzinfo=UTC)
SNAPSHOT2_TS = datetime(2026, 11, 20, 16, 45, tzinfo=UTC)
ASSIGN_VALID_FROM = datetime(2026, 11, 19, tzinfo=UTC)
BASE_TZ = {"SHJ": "Asia/Dubai", "RKT": "Asia/Dubai", "KHI": "Asia/Karachi"}   # crew bases (for airport load)
ROSTER_TZ = "Asia/Dubai"     # organizer-confirmed: roster check-in/out times are SHJ local for every crew
FDP_BAND_TZ = "Asia/Dubai"   # organizer-confirmed: FDP time bands use SHJ local (UTC+4)
QUAL_TOKENS = {"LVP", "TRN", "ETOP"}

# Alternates for SHJ. Road positioning minutes are ASSUMPTIONS for the prototype.
SHJ_ALTERNATES = {  # iata: (road_positioning_min, note)
    "RKT": (60,  "ASSUMED road time SHJ-RKT"),
    "FJR": (90,  "ASSUMED road time SHJ-FJR"),
    "DWC": (60,  "ASSUMED road time SHJ-DWC"),
    "AAN": (120, "ASSUMED road time SHJ-AAN"),
    "AUH": (120, "ASSUMED road time SHJ-AUH"),
    "MCT": (None, "Not reachable by road in time: deadhead required"),
}


def log(msg):
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def ts(v):
    """pandas value -> aware UTC datetime or None (source files are UTC unless stated)."""
    if v is None or (isinstance(v, float) and pd.isna(v)) or pd.isna(v):
        return None
    t = pd.Timestamp(v)
    return (t.tz_localize(UTC) if t.tzinfo is None else t.tz_convert(UTC)).to_pydatetime()


def hm_to_min(v):
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    s = str(v).strip()
    m = re.match(r"^(-?\d{1,3}):(\d{1,2})", s)
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    return h * 60 + mi


def nn(v):
    return None if v is None or (not isinstance(v, (list, dict)) and pd.isna(v)) else v


def find(data_dir, pattern):
    hits = sorted(glob.glob(os.path.join(data_dir, pattern)))
    if not hits:
        sys.exit(f"Missing file matching {pattern} in {data_dir}")
    return hits


# ---------------------------------------------------------------------------
def load_airports(cur, data_dir, codes):
    import airportsdata
    by_iata = airportsdata.load("IATA")
    gt = pd.read_excel(find(data_dir, "Historical_Flight_Data*.xlsx")[0], sheet_name="icao_iata_ground_time")
    ground = dict(zip(gt["code"], gt["min_ground_time"]))
    codes = set(codes) | set(gt["code"].dropna())
    rows, missing = [], []
    for c in sorted(x for x in codes if isinstance(x, str) and len(x) == 3):
        a = by_iata.get(c)
        if not a or not a.get("tz"):
            missing.append(c)
            continue
        rows.append((c, a.get("icao") or None, a.get("name"), a.get("country"), a["tz"],
                     int(ground.get(c, 40)), c in ("SHJ", "RKT"), a.get("lat"), a.get("lon")))
    execute_values(cur, """INSERT INTO fogops.airport (iata, icao, name, country, tz, min_ground_time_min,
                           is_hub, latitude, longitude) VALUES %s ON CONFLICT (iata) DO NOTHING""", rows)
    log(f"airports: {len(rows)} loaded, {len(missing)} without timezone skipped {missing[:10]}")
    return {r[0] for r in rows}


def load_rule_set(cur, data_dir):
    path = find(data_dir, "Crew_FDTL.xlsx")[0]
    sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    t = pd.read_excel(path)
    cur.execute("""INSERT INTO fogops.rule_set (name, version, source_document, checksum_sha256, status,
                       effective_from, commander_discretion_min, band_reference, band_tz, at_risk_threshold_min, parameters)
                   VALUES ('GCAA FDP', 'v1 Crew_FDTL 2026-11-20', 'Crew_FDTL.xlsx', %s, 'DRAFT',
                           '2026-01-01T00:00Z', 180, 'FIXED_TZ', %s, 60, %s)
                   RETURNING rule_set_id""",
                (sha, FDP_BAND_TZ, Json({"min_rest_after_duty_min": 720,
                            "sheet_mismatch_policy": "WARN",
                            "sheet_mismatch_note": "Band basis confirmed by organizers (SHJ local); duty-sheet maxFdp is a derived field and is only cross-checked",
                            "min_rest_note": "ASSUMED - minimum rest is not in the supplied FDTL file; confirm with organizers",
                            "legs_0_rows": "Present in source (FDP_ID 257-298); meaning to be confirmed",
                            "band_reference_note": "Organizer-confirmed: FDP bands use SHJ local time (UTC+4) for all crew"})))
    rs_id = cur.fetchone()[0]
    rows = [(rs_id, int(r.FDP_ID), r.CREW_TYPE_CODE, str(r.LocalStartFrom), str(r.LocalStartTo),
             int(r.NO_OF_LEGS), int(r.FDP)) for r in t.itertuples()]
    execute_values(cur, """INSERT INTO fogops.fdp_rule (rule_set_id, source_rule_id, crew_type_code,
                           local_start_from, local_start_to, no_of_legs, max_fdp_min) VALUES %s""", rows)
    cur.execute("""UPDATE fogops.rule_set SET status='APPROVED', approved_by='Hackathon organizers (supplied file)',
                   approved_at=now() WHERE rule_set_id=%s""", (rs_id,))
    log(f"rule set {rs_id}: {len(rows)} FDP rules approved (sha256 {sha[:12]})")


def read_rotation(path):
    df = pd.read_excel(path, engine="xlrd")
    df = df[df["SAI"].notna() & df["STD"].notna()]
    df["key"] = df["SAI"].astype(str) + "|" + df["Dep"] + "|" + pd.to_datetime(df["STD"]).dt.strftime("%Y-%m-%dT%H:%M")
    return df.set_index("key")


def load_flights(cur, data_dir, airports):
    base = read_rotation(find(data_dir, "OCC_Flight_Rotation_20Nov_23Nov26.xls")[0])
    regs = sorted(set(base["Reg"].dropna()))
    execute_values(cur, "INSERT INTO fogops.aircraft (registration) VALUES %s ON CONFLICT DO NOTHING",
                   [(r,) for r in regs])
    rows = []
    for k, r in base.iterrows():
        if r.Dep not in airports or r.Arr not in airports:
            log(f"  skip flight {k}: unknown airport")
            continue
        kind = "TEST" if str(r["Op.Type"]).startswith("T") else "SCHEDULED"
        rows.append((r.SAI, ts(r.STD).date(), r.Dep, r.Arr, ts(r.STD), ts(r.STA), nn(r.Reg),
                     r["Op.Type"], kind, nn(r.PAX) and int(r.PAX), "OCC_Flight_Rotation_20Nov_23Nov26.xls"))
    execute_values(cur, """INSERT INTO fogops.flight (flight_no, flight_date, dep_iata, arr_iata, std_utc, sta_utc,
                           registration_planned, op_type, flight_kind, pax_planned, source) VALUES %s""", rows)
    cur.execute("SELECT flight_id, flight_no, dep_iata, std_utc FROM fogops.flight")
    fmap = {f"{n}|{d}|{s.astimezone(UTC):%Y-%m-%dT%H:%M}": i for i, n, d, s in cur.fetchall()}
    log(f"flights: {len(rows)} (aircraft {len(regs)})")
    return base, fmap


FIELD_MAP = {"etd": "RSTD", "eta": "ETA", "atd": "ATD", "toff": "TOFF", "tdown": "TDOWN", "ata": "ATA"}


def payload_from(r):
    p = {}
    for k, col in FIELD_MAP.items():
        if col in r and ts(r[col]) is not None:
            p[k] = ts(r[col]).isoformat()
    if nn(r.get("Reg")):
        p["registration"] = r["Reg"]
    if nn(r.get("PAX")) is not None:
        p["pax"] = int(r["PAX"])
    for extra in ("PTD", "PTA"):          # kept in the raw event only (meaning to be confirmed)
        if extra in r and ts(r[extra]) is not None:
            p[extra.lower()] = ts(r[extra]).isoformat()
    return p


def load_feed(cur, data_dir, base, fmap):
    n_base = 0
    for k, r in base.iterrows():
        if k not in fmap:
            continue
        cur.execute("SELECT fogops.ingest_flight_event(1,'OCC_ROTATION',%s,%s,'BASELINE',%s,%s,NULL,%s)",
                    (f"OCC0848:{k}", fmap[k], BASELINE_TS, Json(payload_from(r)), BASELINE_TS))
        n_base += 1
    snap = read_rotation(find(data_dir, "OCC_Flight_Rotation_as_of_*.xls")[0])
    n_diff, results = 0, {}
    for k, r in snap.iterrows():
        if k not in fmap:
            continue
        old = payload_from(base.loc[k]) if k in base.index else {}
        new = payload_from(r)
        diff = {f: v for f, v in new.items() if old.get(f) != v}
        if not diff:
            continue
        cur.execute("SELECT fogops.ingest_flight_event(1,'OCC_ROTATION',%s,%s,'SNAPSHOT_DIFF',%s,%s,NULL,%s)",
                    (f"OCC1645:{k}", fmap[k], SNAPSHOT2_TS, Json(diff), SNAPSHOT2_TS))
        res = cur.fetchone()[0]
        results[res] = results.get(res, 0) + 1
        n_diff += 1
    log(f"feed: {n_base} baseline events, {n_diff} diff events from 16:45 snapshot {results}")


def clean_name(raw, langs):
    s = re.sub(r"^\(\d+\)\s*", "", str(raw))
    s = s.split(" - ")[0]
    toks = [t for t in s.split() if t not in QUAL_TOKENS and t not in langs]
    return " ".join(toks).strip()


def load_crew(cur, data_dir, fmap, airports):
    # roster first: it has every crew member and their base
    ro = pd.read_excel(find(data_dir, "Crew_Roster_Next_10_Days.xlsx")[0])
    members = {}
    for r in ro.drop_duplicates("CREW_ID").itertuples():
        members[int(r.CREW_ID)] = dict(name=r.CREW_NAME, type=r.CREW_TYPE_CODE, base=r.CREW_BASE,
                                       gender=None, langs=None, ac=None, mobile=None)
    duty_rows, standby_rows, quals = [], [], set()
    for path in find(data_dir, "Crew_duty_sheet_*.xlsx"):
        fname = os.path.basename(path)
        ds = pd.read_excel(path, sheet_name="Duty Sheet")
        ds["duty_no"] = ds["num"].ffill()
        ds["Date"] = ds["Date"].ffill()
        for r in ds[ds["crewType"].notna()].itertuples():
            cid = int(r.crewId)
            langs = set(str(r.languages).split(",")) if nn(r.languages) else set()
            raw = str(r.crewName)
            for q in QUAL_TOKENS:
                if re.search(rf"\b{q}\b", raw.split(" - ")[0]):
                    quals.add((cid, q, fname))
            ac = re.search(r"-\s*([A-Z0-9,]+)\s*-", raw)
            m = members.setdefault(cid, dict(name=clean_name(raw, langs), type=r.crewType, base="SHJ"))
            m.update(gender=nn(r.gender), langs=sorted(langs) or None, ac=ac.group(1).split(",") if ac else None,
                     mobile=nn(r.mobile) and str(r.mobile))
        duty_rows.append((fname, ds))
        sb = pd.read_excel(path, sheet_name="Standby Details")
        duty_date = pd.Timestamp(ds["Date"].dropna().iloc[0]).date()
        for r in sb.itertuples():
            cid = int(r.crewId)
            members.setdefault(cid, dict(name=r.crewName, type=r.crewTypeCode, base="SHJ", gender=None,
                                         langs=None, ac=None, mobile=str(r.mobileNo)))
            st = datetime.combine(duty_date, pd.Timestamp(str(r.startTime)).time(), tzinfo=UTC)
            en = datetime.combine(duty_date, pd.Timestamp(str(r.endTime)).time(), tzinfo=UTC)
            if en <= st:
                en += timedelta(days=1)
            standby_rows.append((duty_date, r.patternName, cid, r.crewTypeCode, "SHJ", st, en,
                                 "ASSUMED_UTC_SAME_DATE", float(r.totFlyingDuration) if nn(r.totFlyingDuration) else None,
                                 fname))

    execute_values(cur, """INSERT INTO fogops.crew_member (crew_id, full_name, crew_type_code, base_iata, gender,
                           languages, aircraft_types, mobile) VALUES %s ON CONFLICT (crew_id) DO NOTHING""",
                   [(k, v["name"], v["type"], v["base"] if v["base"] in airports else None, v.get("gender"),
                     v.get("langs"), v.get("ac"), v.get("mobile")) for k, v in members.items()])
    execute_values(cur, "INSERT INTO fogops.crew_qualification VALUES %s ON CONFLICT DO NOTHING", list(quals))
    log(f"crew: {len(members)} members, {len(quals)} qualifications")

    # duties, legs, assignments
    n_duty = n_leg = n_unmatched = n_assign = n_created = 0
    for fname, ds in duty_rows:
        for duty_no, g in ds.groupby("duty_no"):
            duty_date = pd.Timestamp(g["Date"].iloc[0]).date()
            legs = g[g["flightNo"].notna()]
            crew = g[g["crewType"].notna()]
            if legs.empty:
                continue
            # leg datetimes: same day as duty, rolling over midnight when times go backwards
            leg_dt, prev = [], None
            for l in legs.itertuples():
                t = datetime.combine(duty_date, pd.Timestamp(str(l.etd)).time(), tzinfo=UTC)
                while prev and t < prev:
                    t += timedelta(days=1)
                leg_dt.append(t)
                prev = t
            si = re.search(r"(\d{1,2}:\d{2})\s*$", str(crew["crewName"].iloc[0])) if len(crew) else None
            sign_in = None
            if si:
                s_min = hm_to_min(si.group(1))
                first = leg_dt[0]
                gap = (first.hour * 60 + first.minute - s_min) % 1440
                sign_in = first - timedelta(minutes=gap)
            first_row = crew.iloc[0] if len(crew) else legs.iloc[0]   # duty without crew -> legality blocked later
            cur.execute("""INSERT INTO fogops.crew_duty (duty_date, source_duty_no, source_file, report_station_iata,
                               sign_in_utc, oper_base, sheet_block_fdp_min, sheet_duration_min)
                           VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING duty_id""",
                        (duty_date, int(duty_no), fname, legs["origin"].iloc[0], sign_in,
                         nn(first_row.operBase), hm_to_min(first_row.blockFdp), hm_to_min(first_row.duration)))
            duty_id = cur.fetchone()[0]
            n_duty += 1
            for seq, (l, dt) in enumerate(zip(legs.itertuples(), leg_dt), start=1):
                fid = None
                for shift in (0, -1, 1):
                    fid = fmap.get(f"{l.flightNo}|{l.origin}|{(dt + timedelta(days=shift)):%Y-%m-%dT%H:%M}")
                    if fid:
                        break
                if not fid and l.origin in airports and l.destination in airports:
                    # leg exists for the crew but not in the rotation window (e.g. next-day return):
                    # create it from the duty sheet so the sector count stays correct
                    sta = datetime.combine(dt.date(), pd.Timestamp(str(l.eta)).time(), tzinfo=UTC)
                    while sta <= dt:
                        sta += timedelta(days=1)
                    if nn(l.acRegNo):
                        cur.execute("INSERT INTO fogops.aircraft (registration) VALUES (%s) ON CONFLICT DO NOTHING",
                                    (l.acRegNo,))
                    cur.execute("""INSERT INTO fogops.flight (flight_no, flight_date, dep_iata, arr_iata, std_utc, sta_utc,
                                       registration_planned, flight_kind, source)
                                   VALUES (%s,%s,%s,%s,%s,%s,%s,'SCHEDULED',%s)
                                   ON CONFLICT (flight_no, std_utc, dep_iata) DO UPDATE SET source = fogops.flight.source
                                   RETURNING flight_id""",
                                (l.flightNo, dt.date(), l.origin, l.destination, dt, sta, nn(l.acRegNo),
                                 f"duty_sheet:{fname}"))
                    fid = cur.fetchone()[0]
                    fmap[f"{l.flightNo}|{l.origin}|{dt:%Y-%m-%dT%H:%M}"] = fid
                    cur.execute("SELECT fogops.ingest_flight_event(1,'OCC_ROTATION',%s,%s,'BASELINE',%s,%s,NULL,%s)",
                                (f"DUTYSHEET:{fid}", fid, BASELINE_TS, Json({"eta": sta.isoformat()}), BASELINE_TS))
                    cur.execute("""INSERT INTO fogops.data_exception (entity_type, entity_id, code, severity, message, detail)
                                   VALUES ('flight', %s, 'FLIGHT_FROM_DUTY_SHEET_ONLY', 'INFO',
                                   'Leg not in OCC rotation window; created from duty sheet so sector count is complete', %s)
                                   ON CONFLICT DO NOTHING""", (str(fid), Json({"file": fname})))
                    n_created += 1
                if not fid:
                    n_unmatched += 1
                    cur.execute("""INSERT INTO fogops.data_exception (entity_type, entity_id, code, severity, message, detail)
                                   VALUES ('crew_duty', %s, 'LEG_NOT_IN_ROTATION', 'BLOCKING',
                                   'Duty-sheet leg not found in OCC rotation', %s)
                                   ON CONFLICT DO NOTHING""",
                                (str(duty_id), Json({"flight": l.flightNo, "origin": l.origin, "etd": str(l.etd),
                                                     "file": fname})))
                    continue
                cur.execute("INSERT INTO fogops.crew_duty_leg (scenario_id, duty_id, leg_seq, flight_id) VALUES (1,%s,%s,%s)",
                            (duty_id, seq, fid))
                n_leg += 1
                if nn(l.acRegNo):
                    cur.execute("""SELECT registration_planned FROM fogops.flight WHERE flight_id=%s""", (fid,))
                    planned = cur.fetchone()[0]
                    if planned and planned != l.acRegNo:
                        cur.execute("""INSERT INTO fogops.data_exception (entity_type, entity_id, code, severity, message, detail)
                                       VALUES ('flight', %s, 'REG_MISMATCH_DUTY_VS_ROTATION', 'INFO',
                                       'Duty sheet and OCC rotation show different aircraft (swap?) - crew linked by flight, not by registration', %s)
                                       ON CONFLICT DO NOTHING""",
                                    (str(fid), Json({"duty_sheet_reg": l.acRegNo, "rotation_reg": planned, "file": fname})))
            seen = set()
            for c in crew.itertuples():
                cid = int(c.crewId)
                if cid in seen:
                    continue
                seen.add(cid)
                cur.execute("""INSERT INTO fogops.crew_assignment (scenario_id, duty_id, crew_id, position_code,
                                   valid_from, source, sheet_max_fdp_min) VALUES (1,%s,%s,%s,%s,'DUTY_SHEET',%s)""",
                            (duty_id, cid, c.crewType, ASSIGN_VALID_FROM, hm_to_min(c.maxFdp)))
                n_assign += 1
    log(f"duties: {n_duty}, legs: {n_leg} ({n_created} flights created from duty sheets), "
        f"unmatched legs: {n_unmatched}, assignments: {n_assign}")

    execute_values(cur, """INSERT INTO fogops.standby_slot (duty_date, pattern_name, crew_id, crew_type_code,
                           location_iata, start_utc, end_utc, times_basis, total_flying_hrs, source_file)
                           VALUES %s ON CONFLICT DO NOTHING""", standby_rows)
    log(f"standby slots: {len(standby_rows)} (times ASSUMED UTC - confirm with organizers)")

    # roster: SHJ LOCAL -> UTC
    ro["tz"] = ROSTER_TZ          # SHJ local for every crew member, including KHI/RKT bases
    out = []
    for r in ro.itertuples():
        s_loc, e_loc = pd.Timestamp(r.DUTY_START_LOCAL), pd.Timestamp(r.DUTY_END_LOCAL)
        s_utc = s_loc.tz_localize(r.tz).tz_convert(UTC).to_pydatetime()
        e_utc = e_loc.tz_localize(r.tz).tz_convert(UTC).to_pydatetime()
        out.append((int(r.CREW_ID), r.DUTY_TYPE, nn(r.BLOCK_NAME), s_loc.to_pydatetime(), e_loc.to_pydatetime(),
                    r.tz, s_utc, e_utc, hm_to_min(r.FLYING_HRS), hm_to_min(r.DUTY_PERIOD),
                    int(r.NO_OF_LEGS) if nn(r.NO_OF_LEGS) else None))
    execute_values(cur, """INSERT INTO fogops.roster_entry (crew_id, duty_type, block_name, start_local, end_local,
                           local_tz, start_utc, end_utc, flying_min, duty_min, no_of_legs) VALUES %s""",
                   out, page_size=5000)
    log(f"roster entries: {len(out)} (converted from local to UTC)")


def load_pax(cur, data_dir, fmap):
    """Connecting passengers: inbound leg (lands at the hub) -> outbound leg (departs the hub).

    The sheet lists EVERY connection twice: once with is_in_bound = TRUE and once with FALSE, where the two flight
    blocks are swapped (the departing flight comes first). The flag is not reliable, so the direction is decided from
    the airports: the block that arrives at the hub is the inbound. Both listings of a connection are counted once
    (the larger figure if the two disagree). Connections where the outbound leaves before the inbound lands are skipped.
    """
    HUB = "SHJ"
    c = pd.read_excel(find(data_dir, "Connecting_pax_data*.xlsx")[0])
    c.columns = ["flight_date", "in_no", "in_o", "in_d", "in_reg", "in_std", "in_sta", "is_in_bound", "pax",
                 "out_no", "out_o", "out_d", "out_reg", "out_std", "out_sta"]
    fkey = lambda no, o, std: f"{no}|{o}|{pd.Timestamp(std):%Y-%m-%dT%H:%M}"  # noqa: E731
    agg = {}
    outside = odd = impossible = 0
    for r in c.itertuples():
        if r.in_d == HUB and r.out_o == HUB:      # block 1 lands at the hub, block 2 departs it
            ik, ok, lands, departs = fkey(r.in_no, r.in_o, r.in_std), fkey(r.out_no, r.out_o, r.out_std), r.in_sta, r.out_std
        elif r.in_o == HUB and r.out_d == HUB:    # swapped listing
            ik, ok, lands, departs = fkey(r.out_no, r.out_o, r.out_std), fkey(r.in_no, r.in_o, r.in_std), r.out_sta, r.in_std
        else:
            odd += 1
            continue
        i, o = fmap.get(ik), fmap.get(ok)
        if not i or not o:
            outside += 1
            continue
        if pd.Timestamp(departs) < pd.Timestamp(lands):
            impossible += 1
            continue
        agg[(i, o)] = max(agg.get((i, o), 0), int(r.pax))
    execute_values(cur, "INSERT INTO fogops.pax_connection VALUES %s", [(i, o, p) for (i, o), p in agg.items()])
    log(f"pax connections: {len(agg)} pairs, {sum(agg.values())} pax ({outside} rows outside the 20-23 Nov rotation, "
        f"{impossible} impossible (outbound before inbound), {odd} not hub connections: skipped)")


def load_history(cur, data_dir):
    h = pd.read_excel(find(data_dir, "Historical_Flight_Data*.xlsx")[0], sheet_name="Flight Summary")
    h = h.rename(columns={"Op.Type": "OpType", "Dep DLY": "DepDly", "Arr DLY": "ArrDly", "Dest ICAO": "DestICAO"})
    yes = lambda v: str(v).strip().lower() == "yes"
    rows = [(nn(r.SAI), nn(r.Reg), nn(r.Dep), nn(r.Arr), nn(r.DestICAO), nn(r.OpType), ts(r.STD), ts(r.STA), ts(r.ATD),
             ts(r.TOFF), ts(r.TDOWN), ts(r.ATA),
             int(r.DepDly) if nn(r.DepDly) is not None else None, int(r.ArrDly) if nn(r.ArrDly) is not None else None,
             nn(r.DLYCODE), nn(r.DCODE), int(r.PAX) if nn(r.PAX) is not None else None, hm_to_min(r.BLK),
             yes(r.Diversion), yes(r.GTB), yes(r.ATB))
            for r in h.itertuples()]
    execute_values(cur, """INSERT INTO hist.flight (flight_no, registration, dep_iata, arr_iata, planned_dest_icao,
                           op_type, std_utc, sta_utc, atd_utc, toff_utc, tdown_utc, ata_utc, dep_delay_min,
                           arr_delay_min, dep_delay_codes, arr_delay_codes, pax, block_min, is_diversion, is_gtb, is_atb)
                           VALUES %s""", rows, page_size=5000)
    f = pd.read_excel(find(data_dir, "Historical_fuel_data.xlsx")[0])
    plaus = lambda r: (nn(r.fuel_onboard_departure) is not None and 1000 <= r.fuel_onboard_departure <= 30000
                       and nn(r.remaining_fuel) is not None and 300 <= r.remaining_fuel <= 20000
                       and (nn(r.density) is None or 0.7 <= r.density <= 0.9))
    frows = [(nn(r.reg_number), nn(r.flight_number), nn(r.origin), nn(r.destination), ts(r.etd), ts(r.atd),
              nn(r.fuel_onboard_departure), nn(r.fuel_uplift_departure), nn(r.density), nn(r.minimum_fuel),
              nn(r.remaining_fuel), plaus(r)) for r in f.itertuples()]
    execute_values(cur, """INSERT INTO hist.fuel (registration, flight_no, origin_iata, destination_iata, etd_utc,
                           atd_utc, fuel_onboard_departure, fuel_uplift_departure, density, minimum_fuel,
                           remaining_fuel, is_plausible) VALUES %s""", frows, page_size=5000)
    log(f"history: {len(rows)} flights, {len(frows)} fuel rows "
        f"({sum(1 for x in frows if not x[-1])} flagged implausible)")


def post_load(cur):
    cur.execute("""
        INSERT INTO fogops.block_time_reference (from_iata, to_iata, median_block_min, p90_block_min, sample_n, source)
        SELECT h.dep_iata, h.arr_iata,
               percentile_disc(0.5) WITHIN GROUP (ORDER BY block_min),
               percentile_disc(0.9) WITHIN GROUP (ORDER BY block_min), count(*), 'hist.flight Jan-Nov 2026'
          FROM hist.flight h
          JOIN fogops.airport a1 ON a1.iata = h.dep_iata
          JOIN fogops.airport a2 ON a2.iata = h.arr_iata
         WHERE block_min BETWEEN 10 AND 900 AND h.dep_iata <> h.arr_iata
         GROUP BY 1, 2 HAVING count(*) >= 2""")
    cur.execute("SELECT count(*) FROM fogops.block_time_reference")
    log(f"block time references: {cur.fetchone()[0]} routes")

    # alternates for SHJ, ranked by how often history used them
    cur.execute("""SELECT arr_iata, count(*) FROM hist.flight
                   WHERE is_diversion AND planned_dest_icao = 'OMSJ' GROUP BY 1""")
    hist_counts = dict(cur.fetchall())
    ranked = sorted(SHJ_ALTERNATES, key=lambda a: -hist_counts.get(a, 0))
    execute_values(cur, """INSERT INTO fogops.alternate_airport (hub_iata, alt_iata, priority, road_positioning_min,
                           historical_diversions, notes) VALUES %s""",
                   [("SHJ", a, i + 1, SHJ_ALTERNATES[a][0], hist_counts.get(a, 0), SHJ_ALTERNATES[a][1])
                    for i, a in enumerate(ranked)])
    # median time an aircraft spent on the ground at each alternate after a SHJ diversion
    cur.execute("""
        UPDATE fogops.alternate_airport aa SET hist_median_ground_min = g.med
          FROM (SELECT d.arr_iata, percentile_disc(0.5) WITHIN GROUP (ORDER BY
                       extract(epoch FROM nx.atd_utc - d.ata_utc) / 60)::int AS med
                  FROM hist.flight d
                  JOIN LATERAL (SELECT h.atd_utc FROM hist.flight h
                                 WHERE h.registration = d.registration AND h.dep_iata = d.arr_iata
                                   AND h.std_utc > d.std_utc AND h.atd_utc > d.ata_utc
                                 ORDER BY h.std_utc LIMIT 1) nx ON TRUE
                 WHERE d.is_diversion AND d.planned_dest_icao = 'OMSJ'
                   AND nx.atd_utc - d.ata_utc < interval '24 hours'
                 GROUP BY d.arr_iata) g
         WHERE aa.hub_iata = 'SHJ' AND aa.alt_iata = g.arr_iata""")
    for st in ("FJR", "RKT", "AAN", "MCT"):
        cur.execute("""INSERT INTO fogops.app_user (username, display_name, role_code, station_iata)
                       VALUES (%s, %s, 'STATION', %s) ON CONFLICT DO NOTHING""",
                    (f"station.{st.lower()}", f"{st} Station", st))

    cur.execute("""INSERT INTO fogops.data_exception (entity_type, entity_id, code, severity, message, detail) VALUES
        ('feed_source','OCC_ROTATION','STATUS_COLUMN_UNRELIABLE','INFO',
         'Source Status column is SCH for every flight, including landed ones; status is derived from actual times', '{}'),
        ('standby_slot','*','STANDBY_TIME_BASIS_ASSUMED','WARN',
         'Standby Details times have no timezone; loaded as UTC on the sheet date - confirm with organizers', '{}'),
        ('rule_set','GCAA FDP','MIN_REST_NOT_SUPPLIED','WARN',
         'Minimum rest is not in Crew_FDTL.xlsx; 12h is an assumption used only for roster-conflict checks', '{}')
        ON CONFLICT DO NOTHING""")

    # LIVE scenario clock = time of the latest snapshot
    cur.execute("UPDATE fogops.scenario SET sim_clock_utc = %s WHERE scenario_id = 1", (SNAPSHOT2_TS,))
    cur.execute("SELECT duty_id FROM fogops.crew_duty ORDER BY duty_id")
    duties = [d for (d,) in cur.fetchall()]
    for d in duties:
        cur.execute("SELECT fogops.compute_duty_legality(1, %s, 'initial_load')", (d,))
    cur.execute("""SELECT status, count(*) FROM fogops.fdp_calculation
                   WHERE is_current AND crew_id IS NULL GROUP BY 1 ORDER BY 1""")
    log(f"legality computed for {len(duties)} duties: {dict(cur.fetchall())}")
    cur.execute("""SELECT code, count(*) FROM fogops.data_exception WHERE status='OPEN' GROUP BY 1 ORDER BY 2 DESC""")
    log(f"open exceptions: {dict(cur.fetchall())}")
    cur.execute("UPDATE fogops.reassessment_queue SET status='DONE', done_at=now() WHERE status='PENDING'")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--dsn", default=os.environ.get("FOGOPS_DSN", "postgresql://postgres@localhost:5432/fogops"))
    args = ap.parse_args()
    conn = psycopg2.connect(args.dsn)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        rot = read_rotation(find(args.data_dir, "OCC_Flight_Rotation_20Nov_23Nov26.xls")[0])
        hist_codes = pd.read_excel(find(args.data_dir, "Historical_Flight_Data*.xlsx")[0],
                                   sheet_name="Flight Summary", usecols=["Dep", "Arr"])
        codes = set(rot["Dep"]) | set(rot["Arr"]) | set(hist_codes["Dep"]) | set(hist_codes["Arr"]) \
            | set(SHJ_ALTERNATES) | set(BASE_TZ)
        airports = load_airports(cur, args.data_dir, codes)
        load_rule_set(cur, args.data_dir)
        base, fmap = load_flights(cur, args.data_dir, airports)
        load_feed(cur, args.data_dir, base, fmap)
        load_crew(cur, args.data_dir, fmap, airports)
        load_pax(cur, args.data_dir, fmap)
        load_history(cur, args.data_dir)
        post_load(cur)
        conn.commit()
        log("DONE - committed")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
