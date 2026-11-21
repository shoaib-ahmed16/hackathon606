#!/usr/bin/env python3
"""Repair fogops.pax_connection in an EXISTING database (same logic as load_pax in load_data.py).

Problem fixed: the Excel lists every connection twice (is_in_bound TRUE and FALSE, blocks swapped); the old loader
ignored that and stored ~half of the rows reversed (inbound = a departure from the hub).

  FOGOPS_DSN=postgresql://postgres:***@127.0.0.1:5433/fogops \
    python scripts/fix_pax_connection.py Hack606_Fog_Ops/Connecting_pax_data.xlsx            # dry run (rolled back)
  ... same command + --apply                                                                 # commit the repair
After --apply, regenerate backend/db/init/10_fogops.sql.gz with scripts/make_db_dump.sh so new deployments get the fix.
"""
import argparse
import os
import sys

import pandas as pd
import psycopg

ap = argparse.ArgumentParser()
ap.add_argument("xlsx")
ap.add_argument("--apply", action="store_true", help="commit (default: show the result and roll back)")
ap.add_argument("--hub", default="SHJ")
a = ap.parse_args()
HUB = a.hub
c = pd.read_excel(a.xlsx)
c.columns = ["flight_date", "in_no", "in_o", "in_d", "in_reg", "in_std", "in_sta", "is_in_bound", "pax",
             "out_no", "out_o", "out_d", "out_reg", "out_std", "out_sta"]
fkey = lambda no, o, std: f"{no}|{o}|{pd.Timestamp(std):%Y-%m-%dT%H:%M}"  # noqa: E731

with psycopg.connect(os.environ["FOGOPS_DSN"]) as conn:
    cur = conn.cursor()
    cur.execute("SET search_path = fogops, public")
    cur.execute("SELECT flight_id, flight_no, dep_iata, to_char(std_utc AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI') FROM flight")
    fmap = {f"{n}|{d}|{s}": i for i, n, d, s in cur.fetchall()}
    cur.execute("SELECT count(*), coalesce(sum(pax_count),0), count(*) FILTER (WHERE f.dep_iata = %s) "
                "FROM pax_connection p JOIN flight f ON f.flight_id = p.inbound_flight_id", (HUB,))
    before = cur.fetchone()

    agg, outside, odd, impossible = {}, 0, 0, 0
    for r in c.itertuples():
        if r.in_d == HUB and r.out_o == HUB:
            ik, ok, lands, departs = fkey(r.in_no, r.in_o, r.in_std), fkey(r.out_no, r.out_o, r.out_std), r.in_sta, r.out_std
        elif r.in_o == HUB and r.out_d == HUB:
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

    cur.execute("DELETE FROM pax_connection")
    cur.executemany("INSERT INTO pax_connection (inbound_flight_id, outbound_flight_id, pax_count) VALUES (%s,%s,%s)",
                    [(i, o, p) for (i, o), p in agg.items()])
    cur.execute("SELECT count(*), coalesce(sum(pax_count),0), count(*) FILTER (WHERE f.dep_iata = %s) "
                "FROM pax_connection p JOIN flight f ON f.flight_id = p.inbound_flight_id", (HUB,))
    after = cur.fetchone()
    print(f"BEFORE: {before[0]} pairs, {before[1]} pax, {before[2]} pairs with the inbound column departing {HUB} (wrong way round)")
    print(f"AFTER : {after[0]} pairs, {after[1]} pax, {after[2]} wrong way round")
    print(f"skipped rows: {outside} outside the 20-23 Nov rotation, {impossible} impossible (outbound before inbound), {odd} not hub connections")
    if a.apply:
        conn.commit()
        print("COMMITTED. Now regenerate the dump: scripts/make_db_dump.sh")
    else:
        conn.rollback()
        print("DRY RUN: nothing was changed. Re-run with --apply to commit.")
