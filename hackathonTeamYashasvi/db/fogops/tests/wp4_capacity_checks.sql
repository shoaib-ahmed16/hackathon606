-- WP-4 capacity checks. Run ONLY on a scratch copy (never the shared database); everything rolls back.
--   docker exec -i <postgres-container> psql -U postgres -d <scratch_db> -v ON_ERROR_STOP=1 < db/fogops/tests/wp4_capacity_checks.sql
-- Needs: migrations V1..V9 applied, the loaded OCC data (flights 192 and 197 are the two diversions to RKT in the REPLAY scenario).
-- Any failed expectation raises an exception and the run stops; success prints "WP-4 capacity checks: all passed".
BEGIN;
SET LOCAL search_path TO fogops, hist, public;
SELECT set_config('fogops.skip_audit', 'on', TRUE);
DELETE FROM airport_capacity;   -- start from nothing configured (rolled back with everything else)
CREATE FUNCTION pg_temp.expect(p_name TEXT, p_ok BOOLEAN) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAILED: %', p_name; END IF; RAISE NOTICE 'ok  %', p_name; END $$;

DO $$
DECLARE
    h RECORD; c RECORD; j JSONB; v_rep INT; v_live INT; v_n INT; v_free INT;
BEGIN
    SELECT scenario_id INTO v_live FROM scenario WHERE kind = 'LIVE' ORDER BY scenario_id LIMIT 1;
    SELECT scenario_id INTO v_rep FROM scenario WHERE kind = 'REPLAY' ORDER BY scenario_id LIMIT 1;

    -- 1/2 history: arrivals per hour and simultaneous ground occupancy (reproduces the analysis in the pull request)
    SELECT * INTO h FROM airport_history_capacity('RKT');
    PERFORM pg_temp.expect('RKT sample_n 817, peak 3/hr, ground peak 7', h.sample_n = 817 AND h.peak_arrivals_per_hr = 3 AND h.peak_ground = 7);
    SELECT * INTO h FROM airport_history_capacity('MCT');
    PERFORM pg_temp.expect('MCT sample_n 512, peak 2/hr, ground peak 3', h.sample_n = 512 AND h.peak_arrivals_per_hr = 2 AND h.peak_ground = 3);
    SELECT * INTO h FROM airport_history_capacity('FJR');
    PERFORM pg_temp.expect('FJR sample_n 11, peak 9/hr, ground peak 12', h.sample_n = 11 AND h.peak_arrivals_per_hr = 9 AND h.peak_ground = 12);
    PERFORM pg_temp.expect('policy min_capacity_sample_hours = 100 and ASSUMED', (SELECT value = 100 AND basis LIKE 'ASSUMED%' FROM divert_policy WHERE key = 'min_capacity_sample_hours'));

    -- 3 insufficient sample: FJR/AAN/AUH/DWC unknown, NULL not 0, quality NULL
    FOR c IN SELECT * FROM unnest(ARRAY['FJR','AAN','AUH','DWC']) i, LATERAL alt_stand_capacity(v_live, i::char(3), scenario_now(v_live)) LOOP
        PERFORM pg_temp.expect(c.i || ' unknown from thin history', c.stands_total IS NULL AND c.arrivals_per_hr IS NULL AND c.quality IS NULL AND c.basis LIKE 'Unknown%');
    END LOOP;

    -- 6 history precedence (enough hours), labelled as estimate
    SELECT * INTO c FROM alt_stand_capacity(v_live, 'RKT', scenario_now(v_live));
    PERFORM pg_temp.expect('RKT from history', c.stands_total = 7 AND c.arrivals_per_hr = 3 AND c.quality = 'ESTIMATED_FROM_HISTORY' AND c.basis LIKE '%LOWER BOUND%');

    -- 5 configured beats history
    INSERT INTO airport_capacity (iata, stands_assumed, arrivals_per_hr_assumed, basis) VALUES ('RKT', 12, 5, 'test'), ('FJR', 20, 8, 'test');
    SELECT * INTO c FROM alt_stand_capacity(v_live, 'RKT', scenario_now(v_live));
    PERFORM pg_temp.expect('configured beats history', c.stands_total = 12 AND c.arrivals_per_hr = 5 AND c.quality = 'ASSUMED' AND c.basis = 'test');

    -- 4 manual status entry beats configured (stands) and keeps its stored quality
    INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, effective_from_utc, quality, note)
         VALUES (v_live, 'RKT', 'OPEN', 4, scenario_now(v_live) - interval '30 minutes', 'MANUAL', 'wp4 test');
    SELECT * INTO c FROM alt_stand_capacity(v_live, 'RKT', scenario_now(v_live));
    PERFORM pg_temp.expect('status entry beats configured', c.stands_total = 4 AND c.quality = 'MANUAL' AND c.arrivals_per_hr = 5);
    SELECT * INTO c FROM alt_stand_capacity(v_live, 'RKT', scenario_now(v_live) - interval '2 hours');
    PERFORM pg_temp.expect('entry not yet effective is ignored (time travel)', c.stands_total = 12);

    -- no movements in the data: occupancy is unknown, not zero, and verification is required
    j := airport_capacity_assess(v_live, 'FJR');
    PERFORM pg_temp.expect('no movement evidence is flagged', (j#>>'{occupancy,stays_in_data}')::int = 0 AND (j#>>'{occupancy,movement_evidence}')::boolean = FALSE AND (j->>'verification_required')::boolean);

    -- 7 unknown stays unknown in the assessment and never claims availability
    j := airport_capacity_assess(v_live, 'AAN', NULL, 1);
    PERFORM pg_temp.expect('unknown capacity -> UNKNOWN_VERIFICATION_REQUIRED', j->>'outcome' = 'UNKNOWN_VERIFICATION_REQUIRED' AND (j#>'{stands,total}') = 'null'::jsonb);

    -- 9 duplicate occupancy: flights 192/197 appear in BOTH flight_state.actual_arr_iata and diversion, but are one stay each
    SELECT count(*), count(DISTINCT flight_id) INTO v_n, v_free FROM airport_stays(v_rep, 'RKT') WHERE flight_id IN (192, 197);
    PERFORM pg_temp.expect('diverted flights counted once', v_n = 2 AND v_free = 2);
    -- the status entry (RKT, replay) says 4 free at 01:00; both diversions landed after it -> 2 free now
    INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, effective_from_utc, quality)
         VALUES (v_rep, 'RKT', 'OPEN', 4, '2026-11-21 01:00+00', 'MANUAL');
    j := airport_capacity_assess(v_rep, 'RKT');
    PERFORM pg_temp.expect('4 free at entry minus 2 diversions landed since = 2', (j#>>'{stands,free_before}')::int = 2);
    -- assessing a flight that is already diverted there must not count it a second time
    j := airport_capacity_assess(v_rep, 'RKT', NULL, 0, 192);
    PERFORM pg_temp.expect('assessed flight already diverted: not double counted', (j#>>'{stands,free_before}')::int = 4 AND (j#>>'{stands,free_after}')::int = 3);

    -- 8 additional diversions (what-if): numbers move, outcome follows the thresholds, nothing is written
    j := airport_capacity_assess(v_rep, 'RKT', NULL, 1);
    PERFORM pg_temp.expect('+1 diversion: 2 -> 1 stands, CONSTRAINED', (j#>>'{stands,free_after}')::int = 1 AND j->>'outcome' = 'CAPACITY_CONSTRAINED');
    j := airport_capacity_assess(v_rep, 'RKT', NULL, 3);
    PERFORM pg_temp.expect('+3 diversions: -1 stands, EXCEEDED', (j#>>'{stands,free_after}')::int = -1 AND j->>'outcome' = 'CAPACITY_EXCEEDED');
    SELECT count(*) INTO v_n FROM diversion WHERE scenario_id = v_rep; PERFORM pg_temp.expect('what-if wrote no diversions', v_n = 2);

    -- cancelled flights leave the picture
    UPDATE flight_state SET is_cancelled = TRUE WHERE scenario_id = v_rep AND flight_id = 192;
    j := airport_capacity_assess(v_rep, 'RKT');
    PERFORM pg_temp.expect('cancelled diversion frees a stand', (j#>>'{stands,free_before}')::int = 3);

    -- a shortfall against a history figure is never "exceeded", only "constrained"
    j := airport_capacity_assess(v_live, 'MCT', NULL, 10);
    PERFORM pg_temp.expect('history shortfall -> CONSTRAINED, verification required', j->>'outcome' = 'CAPACITY_CONSTRAINED' AND (j->>'verification_required')::boolean);
    RAISE NOTICE 'WP-4 capacity checks: all passed';
END $$;
ROLLBACK;
