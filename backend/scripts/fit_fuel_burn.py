"""Fit the fuel burn model used by fuel_now() (migrations 022 and 024) from the supplied history.

    trip fuel = a + b * airborne_min + c_out * taxi_out_min + c_in * taxi_in_min      (ordinary least squares)
    aircraft factor    = that aircraft's share of the airborne-minute burn compared with the fleet (aircraft with 50+ flights)
    route correction   = mean(model trip fuel - actual trip fuel) per route with 30+ flights, and the route's median airborne minutes

trip fuel = hist.fuel.fuel_onboard_departure - remaining_fuel, joined to hist.flight by registration, flight number and departure time
(plausible rows only, airborne 15-600 min, not diverted). Prints the numbers that are written, as literals, into the migrations.
Not part of the app: run it by hand when the history changes.    python3 scripts/fit_fuel_burn.py [dbname]   (needs psql access, numpy)
"""
import csv, io, subprocess, sys
from collections import defaultdict
import numpy as np

SQL = """COPY (SELECT j.fob - j.rem, extract(epoch FROM (j.tdown_utc - j.toff_utc))/60, extract(epoch FROM (j.toff_utc - j.atd_utc))/60,
                     extract(epoch FROM (j.ata_utc - j.tdown_utc))/60, j.registration, j.o, j.d
                FROM (SELECT DISTINCT ON (fu.hist_fuel_id) fu.registration, trim(fu.origin_iata) o, trim(fu.destination_iata) d,
                             fu.fuel_onboard_departure fob, fu.remaining_fuel rem, h.atd_utc, h.toff_utc, h.tdown_utc, h.ata_utc
                        FROM hist.fuel fu JOIN hist.flight h ON h.registration = fu.registration AND h.flight_no = fu.flight_no
                       WHERE fu.is_plausible AND fu.atd_utc IS NOT NULL AND h.atd_utc IS NOT NULL AND NOT h.is_diversion
                         AND abs(extract(epoch FROM (h.atd_utc - fu.atd_utc))) < 600 AND h.toff_utc IS NOT NULL AND h.tdown_utc IS NOT NULL AND h.ata_utc IS NOT NULL
                       ORDER BY fu.hist_fuel_id) j
               WHERE extract(epoch FROM (j.tdown_utc - j.toff_utc))/60 BETWEEN 15 AND 600
                 AND extract(epoch FROM (j.toff_utc - j.atd_utc))/60 BETWEEN 2 AND 45 AND extract(epoch FROM (j.ata_utc - j.tdown_utc))/60 BETWEEN 1 AND 30
                 AND j.fob - j.rem BETWEEN 300 AND 20000) TO STDOUT CSV"""

def main(dbname="fogops"):
    out = subprocess.run(["psql", "-d", dbname, "-X", "-c", SQL], capture_output=True, text=True, check=True).stdout
    rows = list(csv.reader(io.StringIO(out)))
    trip, air, tout, tin = (np.array([float(r[i]) for r in rows]) for i in range(4))
    reg = np.array([r[4] for r in rows])
    X = np.column_stack([np.ones(len(trip)), air, tout, tin])
    beta = np.linalg.lstsq(X, trip, rcond=None)[0]
    r2 = 1 - ((trip - X @ beta) ** 2).sum() / ((trip - trip.mean()) ** 2).sum()
    print(f"-- n={len(trip)}  a={beta[0]:.1f} kg  b={beta[1]:.3f} kg/min  c_out={beta[2]:.1f} kg/min  c_in={beta[3]:.1f} kg/min  R2={r2:.3f}")
    print(f"-- median taxi-out {np.median(tout):.0f} min, taxi-in {np.median(tin):.0f} min")
    res = trip - (beta[0] + beta[2] * tout + beta[3] * tin)
    fac = {}
    print("-- aircraft_burn_factor (registration, factor)")
    for rg in sorted(set(reg)):
        m = reg == rg
        if m.sum() >= 50:
            fac[rg] = res[m].sum() / (beta[1] * air[m]).sum()
            print(f"  ('{rg}', {fac[rg]:.3f}),")
    pred = beta[0] + beta[2] * tout + beta[3] * tin + beta[1] * air * np.array([fac.get(g, 1.0) for g in reg])
    err = pred - trip
    by, mins = defaultdict(list), defaultdict(list)
    for i, r in enumerate(rows):
        by[(r[5], r[6])].append(err[i])
        mins[(r[5], r[6])].append(air[i])
    print("-- fuel_route_adjust (origin, destination, n, mean(model - actual) kg, median airborne min)")
    for k in sorted(by):
        if len(by[k]) >= 30:
            print(f"  ('{k[0]}', '{k[1]}', {len(by[k])}, {np.mean(by[k]):.0f}, {np.median(mins[k]):.0f}),")

if __name__ == "__main__":
    main(*sys.argv[1:])
