"""Fit the fog model that migration 027 reads (fog_clear_quantile, alt_fog_conditional) from the METAR history in fogops.weather_obs.

    FOGOPS_DSN=postgresql://... python3 scripts/train_fog_model.py [--icao OMSJ] [--write] [--activate] [--test-from 2025-01-01]

Without --write it only reports. Needs numpy and scikit-learn (offline tool, not an API dependency), psycopg.

Fog episode (same rules as fogops.fog_state()): starts at a report with visibility < fog_vis_in_m, ends at the first of two consecutive reports >= fog_vis_clear_m.
Label of a sample = minutes from that report until the episode ends. Episodes with a gap of more than 2 h between reports are dropped (end unknown).
Models compared on episodes the model never saw (time split) and leave-one-year-out:
  climatology  : empirical quantiles of the remaining time by minutes-since-onset only
  rule         : the engine's assumed spread, P50 = climatology median, P90 = P50 + max(30, 0.5 x P50)
  gbm          : gradient-boosted quantile regression on log(remaining) with visibility, age, hour, month, T-Td spread, wind
The gbm is exported as a grid of its predictions (SQL looks up the nearest cell), so the engine has no ML dependency.
"""
import argparse, json, os, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import numpy as np
import psycopg
from sklearn.ensemble import GradientBoostingRegressor

VIS_G = [50, 100, 200, 300, 400, 500, 600, 800, 1000, 1200, 1500]
AGE_G = [0, 30, 60, 120, 180, 300, 480]
HOUR_G = list(range(0, 24, 3))
MONTH_G = list(range(1, 13))
SPREAD_G = [0, 1, 2, 3]
WIND_G = [0, 4, 8]
QS = (0.1, 0.5, 0.9)


def season(month):  # same as alt_fog_risk(): Dec-Feb 0, Mar-May 1, Jun-Aug 2, Sep-Nov 3
    return (month % 12) // 3


def pol(conn, key, default):
    r = conn.execute("SELECT value FROM fogops.divert_policy WHERE key = %s", (key,)).fetchone()
    return float(r[0]) if r else default


def load(conn, icao):
    rows = conn.execute("""SELECT DISTINCT ON (obs_utc) obs_utc, vsby_m, temp_c, dewp_c, wind_kt FROM fogops.weather_obs
                           WHERE icao = %s AND vsby_m IS NOT NULL ORDER BY obs_utc, source""", (icao,)).fetchall()
    return rows


def episodes(rows, v_in, v_clear, max_gap_min=120):
    """-> list of dicts(onset, end, samples=[(t, vis, temp, dewp, wind)])"""
    out, i, n = [], 0, len(rows)
    while i < n:
        if rows[i][1] < v_in:
            j, onset, ok, end = i, rows[i][0], True, None
            samples = []
            while j < n:
                t, vis = rows[j][0], rows[j][1]
                if j > i and (t - rows[j - 1][0]).total_seconds() / 60 > max_gap_min:
                    ok = False  # gap inside the episode: end unknown
                    break
                if vis >= v_clear and j + 1 < n and rows[j + 1][1] >= v_clear:
                    end = t
                    break
                samples.append(rows[j]); j += 1
            if end is not None and ok and samples:
                out.append(dict(onset=onset, end=end, samples=samples))
            # continue after this episode (or after the broken part)
            i = max(j + 1, i + 1)
        else:
            i += 1
    return out


def feat(sample, onset):
    t, vis, temp, dewp, wind = sample
    age = (t - onset).total_seconds() / 60
    spread = 3.0 if temp is None or dewp is None else min(max(float(temp) - float(dewp), 0), 3)
    return [vis, age, t.hour, t.month, spread, min(float(wind or 0), 8)]


def xy(eps):
    X, y, ep_id = [], [], []
    for k, e in enumerate(eps):
        for s in e["samples"]:
            X.append(feat(s, e["onset"]))
            y.append((e["end"] - s[0]).total_seconds() / 60); ep_id.append(k)
    return np.array(X, float), np.array(y, float), np.array(ep_id)


def pinball(y, p, q):
    d = y - p
    return float(np.mean(np.maximum(q * d, (q - 1) * d)))


def fit_gbm(X, y):
    ly = np.log1p(y)
    return [GradientBoostingRegressor(loss="quantile", alpha=q, n_estimators=150, max_depth=3, learning_rate=0.06, subsample=0.8, random_state=7).fit(X, ly) for q in QS]


def predict_gbm(ms, X):
    P = np.column_stack([np.expm1(m.predict(X)) for m in ms])
    P = np.sort(np.clip(P, 1, 720), axis=1)
    return P


def climatology(Xtr, ytr):
    """empirical quantiles of remaining time by age bucket (nearest grid value of age)"""
    ages = np.array(AGE_G)
    idx = lambda a: np.abs(ages[None, :] - a[:, None]).argmin(axis=1)
    b = idx(Xtr[:, 1]); table = {}
    for k in range(len(AGE_G)):
        v = ytr[b == k]
        table[k] = np.quantile(v, QS) if len(v) >= 10 else np.quantile(ytr, QS)
    return lambda X: np.array([table[k] for k in idx(X[:, 1])])


def evaluate(Xte, yte, preds):
    res = {}
    for name, P in preds.items():
        res[name] = {"pinball_p10": pinball(yte, P[:, 0], .1), "pinball_p50": pinball(yte, P[:, 1], .5), "pinball_p90": pinball(yte, P[:, 2], .9),
                     "mae_p50_min": float(np.mean(np.abs(yte - P[:, 1]))), "coverage_p10": float(np.mean(yte <= P[:, 0])),
                     "coverage_p90": float(np.mean(yte <= P[:, 2])), "mean_p90_minus_p50_min": float(np.mean(P[:, 2] - P[:, 1]))}
    return res


def split_metrics(eps_tr, eps_te):
    Xtr, ytr, _ = xy(eps_tr); Xte, yte, _ = xy(eps_te)
    clim = climatology(Xtr, ytr)
    Pc = clim(Xte)
    spread = np.maximum(30, .5 * Pc[:, 1])   # the engine's assumed rule: P90 = P50 + max(30, 0.5 x P50); P10 mirrored at half the spread
    Pr = np.column_stack([np.maximum(1, Pc[:, 1] - 0.5 * spread), Pc[:, 1], Pc[:, 1] + spread])
    Pg = predict_gbm(fit_gbm(Xtr, ytr), Xte)
    return evaluate(Xte, yte, {"climatology": Pc, "assumed_rule": Pr, "gbm": Pg}), len(yte)


def grid_rows(ms, X, y):
    cells = [(v, a, h, m, s, w) for v in VIS_G for a in AGE_G for h in HOUR_G for m in MONTH_G for s in SPREAD_G for w in WIND_G]
    P = predict_gbm(ms, np.array(cells, float))
    vis_i = np.abs(np.array(VIS_G)[None, :] - X[:, 0][:, None]).argmin(axis=1)
    age_i = np.abs(np.array(AGE_G)[None, :] - X[:, 1][:, None]).argmin(axis=1)
    sup = defaultdict(int)
    for a, b in zip(vis_i, age_i):
        sup[(a, b)] += 1
    rows = []
    for (v, a, h, m, s, w), p in zip(cells, P):
        rows.append((v, a, h, m, s, w, sup[(VIS_G.index(v), AGE_G.index(a))], round(float(p[0]), 1), round(float(p[1]), 1), round(float(p[2]), 1)))
    return rows


def alt_conditional(conn, hub, v_in, minima, k=20.0):
    hub_rows = load(conn, hub)
    hubv = {r[0].replace(minute=(r[0].minute // 30) * 30, second=0, microsecond=0): r[1] for r in hub_rows}
    out = []
    for icao, in conn.execute("SELECT icao FROM fogops.weather_station WHERE role = 'ALTERNATE' ORDER BY icao").fetchall():
        a = {r[0].replace(minute=(r[0].minute // 30) * 30, second=0, microsecond=0): r[1] for r in load(conn, icao)}
        cnt = defaultdict(lambda: [0, 0]); tot = defaultdict(lambda: [0, 0])
        for t, hv in hubv.items():
            t1 = t + timedelta(hours=1)
            av = a.get(t1)
            if av is None:
                continue
            fog = hv < v_in; below = av < minima
            c = cnt[(fog, season(t1.month), (round(t1.hour / 3) * 3) % 24)]; c[0] += 1; c[1] += below
            tt = tot[fog]; tt[0] += 1; tt[1] += below
        for (fog, sea, hr), (n, nb) in cnt.items():
            base = tot[fog][1] / tot[fog][0] if tot[fog][0] else 0
            out.append((icao, fog, sea, hr, n, nb, round((nb + k * base) / (n + k), 5)))
    return out


def crosscheck(conn, icao, v_in):
    """how many historical diversions planned to the hub coincide with fog in the METAR (within 2 h of the scheduled arrival)?"""
    r = conn.execute("""SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM fogops.weather_obs w WHERE w.icao = %s AND w.vsby_m < %s
                          AND w.obs_utc BETWEEN f.sta_utc - interval '2 hours' AND f.sta_utc + interval '2 hours'))
                        FROM hist.flight f WHERE f.is_diversion AND f.planned_dest_icao = 'OMSJ'""", (icao, v_in)).fetchone()
    return {"diversions_planned_to_hub": r[0], "with_metar_fog_within_2h": r[1]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--icao", default="OMSJ"); ap.add_argument("--write", action="store_true"); ap.add_argument("--activate", action="store_true")
    ap.add_argument("--test-from", default="2025-01-01")
    a = ap.parse_args()
    test_from = datetime.fromisoformat(a.test_from).replace(tzinfo=timezone.utc)
    with psycopg.connect(os.environ["FOGOPS_DSN"]) as conn:
        v_in, v_clear, minima = pol(conn, "fog_vis_in_m", 800), pol(conn, "fog_vis_clear_m", 1500), pol(conn, "alt_minima_vis_m", 800)
        rows = load(conn, a.icao)
        eps = episodes(rows, v_in, v_clear)
        print(f"{a.icao}: {len(rows)} reports {rows[0][0].date()}..{rows[-1][0].date()}, {len(eps)} complete fog episodes (vis<{v_in:.0f} m, clear >= {v_clear:.0f} m)")
        tr = [e for e in eps if e["onset"] < test_from]; te = [e for e in eps if e["onset"] >= test_from]
        print(f"train episodes {len(tr)}, test episodes {len(te)} (onset >= {a.test_from})")
        rem = [(e["end"] - e["onset"]).total_seconds() / 60 for e in eps]
        print("episode length min: p10 %.0f p50 %.0f p90 %.0f max %.0f" % (*np.quantile(rem, [.1, .5, .9]), max(rem)))
        metrics = {"episode_length_min": dict(zip(["p10", "p50", "p90"], map(float, np.quantile(rem, [.1, .5, .9]))), max=float(max(rem)))}
        if len(te) >= 5:
            m, n = split_metrics(tr, te); metrics["time_split"] = dict(n_test_samples=n, **m)
            print("\nTIME SPLIT (test samples %d)" % n)
            for k, v in m.items(): print(f"  {k:13} pinball p10 {v['pinball_p10']:.1f} p50 {v['pinball_p50']:.1f} p90 {v['pinball_p90']:.1f} | MAE p50 {v['mae_p50_min']:.0f} | coverage p10 {v['coverage_p10']:.2f} p90 {v['coverage_p90']:.2f} | mean P90-P50 {v['mean_p90_minus_p50_min']:.0f}")
        # leave-one-year-out over years with at least 4 episodes
        years = sorted({e["onset"].year for e in eps}); agg = defaultdict(list); tot = 0
        for y in years:
            t_ = [e for e in eps if e["onset"].year == y]; r_ = [e for e in eps if e["onset"].year != y]
            if len(t_) < 4 or len(r_) < 30: continue
            m, n = split_metrics(r_, t_); tot += n
            for k, v in m.items(): agg[k].append((n, v))
        loyo = {k: {c: float(sum(n * v[c] for n, v in L) / sum(n for n, _ in L)) for c in L[0][1]} for k, L in agg.items()}
        metrics["leave_one_year_out"] = loyo
        print("\nLEAVE-ONE-YEAR-OUT (%d samples)" % tot)
        for k, v in loyo.items(): print(f"  {k:13} pinball p10 {v['pinball_p10']:.1f} p50 {v['pinball_p50']:.1f} p90 {v['pinball_p90']:.1f} | MAE p50 {v['mae_p50_min']:.0f} | coverage p10 {v['coverage_p10']:.2f} p90 {v['coverage_p90']:.2f} | mean P90-P50 {v['mean_p90_minus_p50_min']:.0f}")
        metrics["crosscheck_flight_history"] = crosscheck(conn, a.icao, v_in)
        print("\nflight-history cross-check:", metrics["crosscheck_flight_history"])
        X, y, _ = xy(eps)
        ms = fit_gbm(X, y)
        alt = alt_conditional(conn, a.icao, v_in, minima)
        print("alternate conditional cells:", len(alt))
        if a.write:
            grid = grid_rows(ms, X, y)
            with conn.transaction():
                rid = conn.execute("""INSERT INTO fogops.fog_model_run (icao, train_from, train_to, test_from, test_to, n_episodes_train, n_episodes_test, n_samples, params, metrics, notes)
                                      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING run_id""",
                                   (a.icao, rows[0][0].date(), rows[-1][0].date(), test_from.date(), rows[-1][0].date(), len(tr), len(te), len(y),
                                    json.dumps({"vis_in_m": v_in, "vis_clear_m": v_clear, "alt_minima_m": minima, "grid": dict(vis=VIS_G, age=AGE_G, hour=HOUR_G, spread=SPREAD_G, wind=WIND_G),
                                                "model": "GradientBoostingRegressor quantile 0.1/0.5/0.9 on log1p(minutes remaining), 150 trees depth 3",
                                                "final_fit": "all episodes (time-split metrics were measured before this fit)"}),
                                    json.dumps(metrics), "scripts/train_fog_model.py")).fetchone()[0]
                with conn.cursor() as cur:
                    with cur.copy("COPY fogops.fog_clear_quantile (run_id, vis_m, age_min, hour_utc, month, spread_c, wind_kt, n, p10, p50, p90) FROM STDIN") as cp:
                        for r in grid: cp.write_row((rid,) + r)
                    with cur.copy("COPY fogops.alt_fog_conditional (run_id, icao, hub_fog, season, hour_utc, n, n_below, p_below) FROM STDIN") as cp:
                        for r in alt: cp.write_row((rid,) + r)
                if a.activate:
                    conn.execute("UPDATE fogops.fog_model_run SET is_active = FALSE WHERE icao = %s AND is_active", (a.icao,))
                    conn.execute("UPDATE fogops.fog_model_run SET is_active = TRUE WHERE run_id = %s", (rid,))
            print(f"written: run {rid}, {len(grid)} grid cells, {len(alt)} alternate cells, active={a.activate}")


if __name__ == "__main__":
    main()
