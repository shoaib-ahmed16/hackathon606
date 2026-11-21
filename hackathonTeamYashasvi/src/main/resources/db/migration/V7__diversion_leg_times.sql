-- 001: historical flight times between the hub and each alternate (how long a diversion takes), and the
--      fuel policy constants used to judge it. Source = hist.flight (Jan-Nov 2026 actuals), never invented:
--      pairs without enough history fall back to great-circle distance and are tagged ESTIMATED.

CREATE TABLE IF NOT EXISTS fogops.divert_policy (
    key          TEXT PRIMARY KEY,
    value        NUMERIC NOT NULL,
    unit         TEXT NOT NULL,
    basis        TEXT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO fogops.divert_policy (key, value, unit, basis) VALUES
    ('final_reserve_min',   30,  'min',       'Final reserve fuel = 30 min at holding speed, 1,500 ft above aerodrome elevation (ICAO Annex 6 Part I, turbine aeroplanes). An aircraft must never land below it.'),
    ('min_leg_sample_n',    5,   'flights',   'Minimum historical flights on a hub-alternate pair before history is trusted over the distance estimate.'),
    ('leg_min_airborne',    5,   'min',       'Airborne times outside 5-150 min on these short sectors are treated as data errors (tech stops, air returns, bad timestamps) and excluded.'),
    ('leg_max_airborne',    150, 'min',       'See leg_min_airborne.'),
    ('fallback_speed_kmpm', 8,   'km/min',    'ASSUMED average ground speed (480 km/h) for a short sector incl. climb/descent, used only where history is missing.'),
    ('fallback_terminal_min', 8, 'min',       'ASSUMED terminal-area allowance added to the distance estimate, used only where history is missing.'),
    ('fallback_p90_factor', 1.25, 'x',        'ASSUMED P90/P50 ratio applied to the distance estimate (observed ratio on history is ~1.2-1.4).')
ON CONFLICT (key) DO NOTHING;

-- Airborne time (take-off to touchdown) from the hub area to an alternate. Airborne, not block: a diverting
-- aircraft is already in the air, so taxi time does not apply. Rows exist in both directions.
CREATE TABLE IF NOT EXISTS fogops.leg_time_reference (
    from_iata        CHAR(3) NOT NULL REFERENCES fogops.airport,
    to_iata          CHAR(3) NOT NULL REFERENCES fogops.airport,
    airborne_p50_min INT NOT NULL,   -- planning / ETA value
    airborne_p90_min INT NOT NULL,   -- conservative value used for the fuel check
    sample_n         INT NOT NULL,
    source           TEXT NOT NULL CHECK (source IN ('HISTORICAL','ESTIMATED')),
    distance_km      NUMERIC,
    computed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (from_iata, to_iata)
);

-- Rebuild the table from history. Call it again whenever hist.flight is reloaded or alternates change.
CREATE OR REPLACE FUNCTION fogops.refresh_leg_time_reference() RETURNS INT
LANGUAGE plpgsql SET search_path TO 'fogops', 'hist', 'public' AS $$
DECLARE
    v_min_n INT   := (SELECT value FROM divert_policy WHERE key = 'min_leg_sample_n');
    v_lo    NUMERIC := (SELECT value FROM divert_policy WHERE key = 'leg_min_airborne');
    v_hi    NUMERIC := (SELECT value FROM divert_policy WHERE key = 'leg_max_airborne');
    v_spd   NUMERIC := (SELECT value FROM divert_policy WHERE key = 'fallback_speed_kmpm');
    v_term  NUMERIC := (SELECT value FROM divert_policy WHERE key = 'fallback_terminal_min');
    v_p90f  NUMERIC := (SELECT value FROM divert_policy WHERE key = 'fallback_p90_factor');
    v_n INT;
BEGIN
    DELETE FROM leg_time_reference;
    INSERT INTO leg_time_reference (from_iata, to_iata, airborne_p50_min, airborne_p90_min, sample_n, source, distance_km)
    WITH pairs AS (
        SELECT DISTINCT aa.hub_iata AS a, aa.alt_iata AS b FROM alternate_airport aa WHERE aa.is_active
    ), hist_t AS (   -- both directions pooled: the sector is the same airway pair
        SELECT p.a, p.b,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY m) AS p50,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY m) AS p90,
               count(*) AS n
          FROM pairs p
          JOIN LATERAL (SELECT extract(epoch FROM (h.tdown_utc - h.toff_utc)) / 60 AS m
                          FROM hist.flight h
                         WHERE ((h.dep_iata = p.a AND h.arr_iata = p.b) OR (h.dep_iata = p.b AND h.arr_iata = p.a))
                           AND h.tdown_utc > h.toff_utc) x ON x.m BETWEEN v_lo AND v_hi
          GROUP BY 1, 2
    ), calc AS (
        SELECT p.a, p.b, distance_km(p.a, p.b) AS d, ht.p50, ht.p90, coalesce(ht.n, 0) AS n
          FROM pairs p LEFT JOIN hist_t ht ON ht.a = p.a AND ht.b = p.b
    ), rows AS (
        SELECT a AS f, b AS t, d,
               CASE WHEN n >= v_min_n THEN ceil(p50) ELSE ceil(d / v_spd + v_term) END AS p50,
               CASE WHEN n >= v_min_n THEN ceil(p90) ELSE ceil((d / v_spd + v_term) * v_p90f) END AS p90,
               n, CASE WHEN n >= v_min_n THEN 'HISTORICAL' ELSE 'ESTIMATED' END AS src
          FROM calc WHERE d IS NOT NULL
    )
    SELECT f, t, p50::int, p90::int, n::int, src, round(d, 1) FROM rows
    UNION ALL
    SELECT t, f, p50::int, p90::int, n::int, src, round(d, 1) FROM rows;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

SELECT fogops.refresh_leg_time_reference();
