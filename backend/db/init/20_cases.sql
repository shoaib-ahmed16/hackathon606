-- One watch-list case per day of the Excel data on the LIVE scenario (real flights, real crew, real legality).
-- Runs once after the data dump. New cases can be created any time from the UI ("Create case").
DO $$
DECLARE d DATE; v_case INT; v_scn INT;
BEGIN
    SELECT scenario_id INTO v_scn FROM fogops.scenario WHERE kind = 'LIVE' ORDER BY scenario_id LIMIT 1;
    PERFORM fogops.set_actor((SELECT user_id FROM fogops.app_user WHERE username = 'occ.dm'));
    FOR d IN SELECT generate_series(DATE '2026-11-20', DATE '2026-11-23', INTERVAL '1 day')::date LOOP
        INSERT INTO fogops.disruption_case (scenario_id, title, hub_iata, cause, phase, opened_by)
        VALUES (v_scn, 'SHJ arrivals ' || to_char(d, 'DD Mon YYYY') || ' (operational data)', 'SHJ', 'OPS', 'MONITORING',
                (SELECT user_id FROM fogops.app_user WHERE username = 'occ.dm'))
        RETURNING case_id INTO v_case;
        INSERT INTO fogops.case_flight (case_id, flight_id)
        SELECT v_case, f.flight_id FROM fogops.flight f
         WHERE f.arr_iata = 'SHJ' AND f.flight_kind = 'SCHEDULED'
           AND f.sta_utc >= d::timestamptz AND f.sta_utc < (d + 1)::timestamptz;
    END LOOP;
END $$;
