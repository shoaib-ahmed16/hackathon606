-- 014: estimated fuel for airborne flights, from the supplied Historical_fuel_data.xlsx.
--
-- Live fuel for flights in the air is not in the supplied data, so flight_fuel_estimate was empty and every airborne flight showed
-- "? verify / fuel endurance not reported". This builds an ESTIMATE (quality = ESTIMATED, never MEASURED) per airborne flight:
--
--   landing fuel L      P25 of remaining_fuel on landing for the same route in history (conservative: a quarter of flights landed
--                       with less); falls back to the destination, then to all flights when the route has < 10 samples
--   cruise burn b       median (fuel at departure - landing fuel) / airborne time on that route (kg/h)
--   fuel now            L + b * minutes to go                                       -> fuel_on_board_kg
--   hold burn           2400 kg/h, ASSUMED (history has no holding burn)           -> burn_rate_hold_kg_per_hr
--   final reserve       30 min at hold burn = 1200 kg (divert_policy.final_reserve_min, ICAO Annex 6)
--   endurance           minutes to go + (L - final reserve) / hold burn             -> est_holding_endurance_min
--                       i.e. time from now until the aircraft would reach final reserve if it flew to the hub and held there.
--
-- A MEASURED / MANUAL / FORECAST estimate is never replaced. An ESTIMATED one is refreshed after p_refresh_min scenario minutes
-- (the ETA may have moved). Each new estimate queues a reassessment of that flight, so its recommendation is recomputed.

CREATE TABLE IF NOT EXISTS fuel_route_stats (
    scope             TEXT NOT NULL CHECK (scope IN ('ROUTE', 'DEST', 'ALL')),
    origin_iata       TEXT,
    dest_iata         TEXT,
    n                 INT  NOT NULL,
    landing_fuel_p25  INT  NOT NULL,
    landing_fuel_p50  INT  NOT NULL,
    cruise_burn_kg_hr INT  NOT NULL,
    built_from        TEXT NOT NULL DEFAULT 'Historical_fuel_data.xlsx + Historical_Flight_Data (plausible rows, airborne 20-400 min)',
    built_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_fuel_route_stats ON fuel_route_stats (scope, coalesce(origin_iata, ''), coalesce(dest_iata, ''));

TRUNCATE fuel_route_stats;
WITH j AS (
    SELECT DISTINCT ON (fu.hist_fuel_id)
           trim(fu.origin_iata) AS o, trim(fu.destination_iata) AS d, fu.remaining_fuel AS rem,
           (fu.fuel_onboard_departure - fu.remaining_fuel) / nullif(extract(epoch FROM (h.tdown_utc - h.toff_utc)) / 3600.0, 0) AS burn
      FROM hist.fuel fu
      JOIN hist.flight h ON h.registration = fu.registration AND h.flight_no = fu.flight_no AND h.atd_utc IS NOT NULL
                        AND fu.atd_utc IS NOT NULL AND abs(extract(epoch FROM (h.atd_utc - fu.atd_utc))) < 600
     WHERE fu.is_plausible AND h.toff_utc IS NOT NULL AND h.tdown_utc IS NOT NULL
       AND extract(epoch FROM (h.tdown_utc - h.toff_utc)) / 60 BETWEEN 20 AND 400
     ORDER BY fu.hist_fuel_id
), good AS (SELECT * FROM j WHERE burn BETWEEN 1200 AND 5000)
INSERT INTO fuel_route_stats (scope, origin_iata, dest_iata, n, landing_fuel_p25, landing_fuel_p50, cruise_burn_kg_hr)
SELECT 'ROUTE', o, d, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY rem)),
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY rem)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY burn)) FROM good GROUP BY o, d
UNION ALL
SELECT 'DEST', NULL, d, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY rem)),
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY rem)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY burn)) FROM good GROUP BY d
UNION ALL
SELECT 'ALL', NULL, NULL, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY rem)),
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY rem)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY burn)) FROM good;

CREATE OR REPLACE FUNCTION estimate_airborne_fuel(p_scenario_id INT, p_hold_burn_kg_hr INT DEFAULT 2400,
                                                  p_min_samples INT DEFAULT 10, p_refresh_min INT DEFAULT 30)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_res_min INT := coalesce((SELECT value FROM divert_policy WHERE key = 'final_reserve_min'), 30)::int;
    v_res_kg  INT := round(v_res_min * p_hold_burn_kg_hr / 60.0);
    r RECORD; st RECORD; v_mtg INT; v_end INT; v_fuel INT; v_done INT := 0;
BEGIN
    FOR r IN
        SELECT f.flight_id, trim(f.dep_iata) AS o, trim(f.arr_iata) AS d, coalesce(s.eta_utc, f.sta_utc) AS eta, s.status::text AS status
          FROM flight_state s JOIN flight f ON f.flight_id = s.flight_id
         WHERE s.scenario_id = p_scenario_id AND s.status IN ('AIRBORNE', 'HOLDING')
           AND NOT EXISTS (SELECT 1 FROM flight_fuel_estimate e WHERE e.scenario_id = p_scenario_id AND e.flight_id = f.flight_id
                              AND (e.quality IN ('MEASURED', 'MANUAL', 'FORECAST')
                                   OR (e.quality = 'ESTIMATED' AND e.as_of_utc > v_now - make_interval(mins => p_refresh_min))))
    LOOP
        SELECT * INTO st FROM (
            SELECT 1 AS pri, * FROM fuel_route_stats WHERE scope = 'ROUTE' AND origin_iata = r.o AND dest_iata = r.d AND n >= p_min_samples
            UNION ALL
            SELECT 2, * FROM fuel_route_stats WHERE scope = 'DEST' AND dest_iata = r.d AND n >= p_min_samples
            UNION ALL
            SELECT 3, * FROM fuel_route_stats WHERE scope = 'ALL') x ORDER BY pri LIMIT 1;
        CONTINUE WHEN st.scope IS NULL;
        v_mtg  := CASE WHEN r.status = 'HOLDING' THEN 0 ELSE greatest(0, floor(extract(epoch FROM r.eta - v_now) / 60)::int) END;
        v_fuel := round(st.landing_fuel_p25 + st.cruise_burn_kg_hr * v_mtg / 60.0);
        v_end  := v_mtg + greatest(0, floor((st.landing_fuel_p25 - v_res_kg) * 60.0 / p_hold_burn_kg_hr)::int);
        INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg,
                                          burn_rate_hold_kg_per_hr, est_holding_endurance_min, quality, basis)
        VALUES (p_scenario_id, r.flight_id, v_now, v_fuel, v_res_kg, p_hold_burn_kg_hr, v_end, 'ESTIMATED',
                jsonb_build_object('method', 'route history',
                                   'source', 'Historical_fuel_data.xlsx',
                                   'stats_scope', st.scope, 'route', r.o || '-' || r.d, 'samples', st.n,
                                   'landing_fuel_p25_kg', st.landing_fuel_p25, 'landing_fuel_p50_kg', st.landing_fuel_p50,
                                   'cruise_burn_kg_per_hr', st.cruise_burn_kg_hr,
                                   'hold_burn_kg_per_hr_ASSUMED', p_hold_burn_kg_hr,
                                   'final_reserve_min', v_res_min, 'final_reserve_kg', v_res_kg,
                                   'minutes_to_go', v_mtg, 'eta_utc', r.eta));
        PERFORM enqueue_reassessment(p_scenario_id, 'fuel estimated', 'flight', r.flight_id::text);
        v_done := v_done + 1;
    END LOOP;
    RETURN v_done;
END $$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' AND p.proname = 'estimate_airborne_fuel' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;

-- fill the live scenario now
SELECT estimate_airborne_fuel(scenario_id) FROM scenario WHERE kind = 'LIVE' AND is_active;
