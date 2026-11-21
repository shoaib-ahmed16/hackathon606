-- Run ONCE, after load_data.sh, on the LIVE scenario (it needs the loaded flights). Synthetic data only.
--   psql -v ON_ERROR_STOP=1 -f db/fogops/seed_cases.sql
--
-- (The station.* users for the diversion stations are already created by load_data.py.)
-- One MONITORING watch-list case per day of the Excel data (20-23 Nov 2026):
--     every SCHEDULED flight arriving at SHJ that day, opened by the OCC duty manager.
-- Re-running is safe: it never duplicates a day's case.
SET search_path = fogops, public;

DO $$
DECLARE
    d DATE;
    v_case INT;
    v_scn INT;
    v_occ INT;
    v_title TEXT;
BEGIN
    SELECT scenario_id INTO v_scn FROM scenario WHERE kind = 'LIVE' AND is_active ORDER BY scenario_id LIMIT 1;
    SELECT user_id INTO v_occ FROM app_user WHERE username = 'occ.dm';
    IF v_scn IS NULL OR v_occ IS NULL THEN
        RAISE EXCEPTION 'LIVE scenario or user occ.dm missing: apply the Flyway migrations first';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM flight LIMIT 1) THEN
        RAISE EXCEPTION 'No flights loaded: run db/fogops/load_data.sh before seed_cases.sql';
    END IF;
    PERFORM set_actor(v_occ);
    FOR d IN SELECT generate_series(DATE '2026-11-20', DATE '2026-11-23', INTERVAL '1 day')::date LOOP
        v_title := 'SHJ arrivals ' || to_char(d, 'DD Mon YYYY') || ' (operational data)';
        CONTINUE WHEN EXISTS (SELECT 1 FROM disruption_case WHERE scenario_id = v_scn AND title = v_title);
        INSERT INTO disruption_case (scenario_id, title, hub_iata, cause, phase, opened_by)
        VALUES (v_scn, v_title, 'SHJ', 'OPS', 'MONITORING', v_occ)
        RETURNING case_id INTO v_case;
        INSERT INTO case_flight (case_id, flight_id)
        SELECT v_case, f.flight_id FROM flight f
         WHERE f.arr_iata = 'SHJ' AND f.flight_kind = 'SCHEDULED'
           AND f.sta_utc >= d::timestamptz AND f.sta_utc < (d + 1)::timestamptz;
    END LOOP;
END $$;
