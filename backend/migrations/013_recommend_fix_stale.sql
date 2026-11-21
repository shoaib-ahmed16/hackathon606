-- 013: fix recommend_for_flight() so the board follows the airport status again.
--  * It crashed ("malformed array literal") whenever crew legality was unverified on an airborne flight whose hub is open,
--    because a text literal was concatenated to a text[] with ||. Every reassessment job after an airport-status change
--    failed, so recommendations written while SHJ was CLOSED stayed on screen after it reopened. Now array_append().
--  * When there is nothing to recommend any more (hub open for a flight that has not left, landed flights), earlier PROPOSED
--    recommendations for that flight are marked EXPIRED instead of being left in place.
-- Everything else is identical to 009.

CREATE OR REPLACE FUNCTION recommend_for_flight(p_scenario_id INT, p_case_id INT, p_flight_id BIGINT,
                                                p_generated_by TEXT DEFAULT 'rules-engine v2',
                                                p_decision_window_min INT DEFAULT 90, p_approach_min INT DEFAULT 10)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    i RECORD; f flight%ROWTYPE; s flight_state%ROWTYPE; dv RECORD; ld RECORD;
    v_now TIMESTAMPTZ; v_eta TIMESTAMPTZ; v_hub TEXT; v_restricted BOOLEAN; v_crew_margin INT; v_endur INT;
    v_block INT; v_land TIMESTAMPTZ; v_new_etd TIMESTAMPTZ; v_delay INT; v_mins INT; v_watch TEXT[] := '{}';
    v_snap JSONB; v_ass JSONB; v_why TEXT;
BEGIN
    SELECT * INTO f FROM flight WHERE flight_id = p_flight_id;
    SELECT * INTO s FROM flight_state WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id;
    IF f.flight_id IS NULL OR s.flight_id IS NULL OR s.is_cancelled OR s.status IN ('CANCELLED') THEN RETURN NULL; END IF;
    SELECT * INTO i FROM flight_decision_inputs(p_scenario_id, p_flight_id);
    v_now := i.now_utc; v_hub := f.arr_iata; v_snap := to_jsonb(i);
    v_eta := coalesce(s.eta_utc, f.sta_utc);
    v_restricted := i.hub_status IN ('CLOSED', 'RESTRICTED')
                 OR (i.hub_status = 'OPEN' AND i.hub_lvp AND i.cockpit_all_lvp IS DISTINCT FROM TRUE);
    v_ass := jsonb_build_array(format('%s status: %s (%s)', v_hub, coalesce(i.hub_status, 'not on record'), coalesce(i.reopen_quality, 'none')),
                               format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
                               format('Decision window: %s min before arrival', p_decision_window_min));

    -- ---- diverted: the aircraft is at the alternate; the question is whether the crew can still bring it back
    SELECT * INTO dv FROM diversion WHERE scenario_id = p_scenario_id AND original_flight_id = p_flight_id
                                       AND status::text NOT IN ('DEPARTED', 'CLOSED', 'CANCELLED') ORDER BY diversion_id DESC LIMIT 1;
    IF dv.diversion_id IS NOT NULL THEN
        SELECT * INTO ld FROM latest_departure_calc WHERE scenario_id = p_scenario_id AND is_current
                      AND flight_id = coalesce(dv.recovery_flight_id, p_flight_id) ORDER BY calculated_at DESC LIMIT 1;
        IF ld.latest_legal_offblocks_utc IS NULL THEN
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'MONITOR', 0.5,
                format('At %s. No latest-departure time can be computed (crew data missing or unverified): verify the crew before deciding.', dv.alternate_iata),
                v_ass, v_snap, p_generated_by, '[]');
        ELSIF ld.latest_legal_offblocks_utc >= v_now THEN
            v_mins := floor(extract(epoch FROM ld.latest_legal_offblocks_utc - v_now) / 60)::int;
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'RECOVER', 0.8,
                format('RECOVER: depart %s by %s (%s min left) to reach %s inside the legal duty period. %s',
                       dv.alternate_iata, to_char(ld.latest_legal_offblocks_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), v_mins, v_hub,
                       coalesce('Return block ' || ld.block_time_min || ' min (' || ld.block_time_basis || ').', '')),
                v_ass, v_snap, p_generated_by,
                jsonb_build_array(jsonb_build_object('action', 'RECOVER', 'score', 1,
                    'reasons', jsonb_build_array(format('Latest legal off-blocks %s', to_char(ld.latest_legal_offblocks_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"')),
                                                 format('%s min of legal margin', v_mins),
                                                 coalesce('Operational target ' || to_char(ld.operational_target_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), 'No operational buffer set')))));
        ELSE
            v_why := CASE WHEN ld.latest_with_discretion_utc >= v_now
                          THEN format('The latest legal departure passed at %s. The captain could extend the duty (commander discretion) until %s, or a replacement crew can be called.',
                                      to_char(ld.latest_legal_offblocks_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), to_char(ld.latest_with_discretion_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'))
                          ELSE format('The latest legal departure passed at %s, even with commander discretion. A replacement crew is needed.',
                                      to_char(ld.latest_legal_offblocks_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"')) END;
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'CREW_REPLACE', 0.75, 'CREW REPLACEMENT: ' || v_why, v_ass, v_snap, p_generated_by,
                jsonb_build_array(jsonb_build_object('action', 'CREW_REPLACE', 'score', 1, 'reasons', jsonb_build_array('Use the replacement finder: legal, LVP-qualified and roster-safe standby crew', v_why))));
        END IF;
    END IF;

    -- ---- airborne
    IF s.status IN ('AIRBORNE', 'HOLDING', 'DIVERTING') THEN
        v_mins := floor(extract(epoch FROM v_eta - v_now) / 60)::int;
        v_crew_margin := CASE WHEN i.crew_known THEN floor(extract(epoch FROM i.legal_end_now - v_eta) / 60)::int END;
        v_endur := i.endurance_left_min;
        IF i.hub_status IS NULL THEN
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'MONITOR', 0.5,
                format('No airport status is on record for %s, so no hold or divert is proposed. Continue and verify %s (open, closed, stands, fuel); the engine re-ranks as soon as it is confirmed.', v_hub, v_hub),
                v_ass, v_snap, p_generated_by, '[]');
        ELSIF NOT v_restricted THEN
            IF v_crew_margin IS NOT NULL AND v_crew_margin < 60 THEN v_watch := v_watch || format('crew margin at arrival is %s min', v_crew_margin); END IF;
            IF NOT i.crew_known THEN v_watch := array_append(v_watch, 'crew legality is unverified'); END IF;
            IF v_endur IS NOT NULL AND v_endur < 30 THEN v_watch := v_watch || format('only %s min of fuel endurance', v_endur); END IF;
            IF cardinality(v_watch) > 0 THEN
                RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'MONITOR', 0.7,
                    format('Continue to %s (open), but watch: %s.', v_hub, array_to_string(v_watch, '; ')), v_ass, v_snap, p_generated_by, '[]');
            END IF;
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'NO_ACTION', 0.85,
                format('Continue to %s: the airport is open, arrival %s%s%s.', v_hub, to_char(v_eta AT TIME ZONE 'UTC', 'HH24:MI"Z"'),
                       CASE WHEN v_crew_margin IS NOT NULL THEN format(', crew margin %s min', v_crew_margin) ELSE '' END,
                       CASE WHEN v_endur IS NOT NULL THEN format(', fuel endurance %s min', v_endur) ELSE '' END),
                v_ass, v_snap, p_generated_by, '[]');
        ELSIF v_mins > p_decision_window_min THEN
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'MONITOR', 0.7,
                format('Arrives in %s min. %s is %s%s; the hold-or-divert decision point is about %s (%s min before arrival). The engine re-checks automatically.',
                       v_mins, v_hub, lower(coalesce(i.hub_status, 'restricted')), CASE WHEN i.hub_lvp THEN ' with LVP' ELSE '' END,
                       to_char((v_eta - make_interval(mins => p_decision_window_min)) AT TIME ZONE 'UTC', 'HH24:MI"Z"'), p_decision_window_min),
                v_ass, v_snap, p_generated_by, '[]');
        END IF;
        RETURN propose_hold_or_divert(p_scenario_id, p_case_id, p_flight_id, p_generated_by, p_approach_min);
    END IF;

    -- ---- not departed: a restricted destination may justify holding the aircraft on the ground
    IF s.status IN ('SCHEDULED', 'TAXI_OUT') AND s.atd_utc IS NULL AND v_restricted AND i.reopen_utc IS NOT NULL THEN
        v_block := floor(extract(epoch FROM f.sta_utc - f.std_utc) / 60)::int;
        v_land := greatest(i.reopen_utc, v_now) + make_interval(mins => p_approach_min);
        v_new_etd := v_land - make_interval(mins => v_block);
        v_delay := ceil(extract(epoch FROM v_new_etd - coalesce(s.etd_utc, f.std_utc)) / 60)::int;
        IF coalesce(s.eta_utc, f.sta_utc) >= v_land THEN
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'NO_ACTION', 0.8,
                format('Depart as planned: it arrives at %s after the forecast reopening (%s).', v_hub, to_char(v_land AT TIME ZONE 'UTC', 'HH24:MI"Z"')),
                v_ass, v_snap, p_generated_by, '[]');
        ELSIF v_delay >= 15 THEN
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'DELAY_DEPARTURE', 0.75,
                format('DELAY DEPARTURE by about %s min to %s so it lands after %s reopens (%s) instead of holding in the air.', v_delay,
                       to_char(v_new_etd AT TIME ZONE 'UTC', 'HH24:MI"Z"'), v_hub, to_char(v_land AT TIME ZONE 'UTC', 'HH24:MI"Z"')),
                v_ass, v_snap, p_generated_by,
                jsonb_build_array(jsonb_build_object('action', 'DELAY_DEPARTURE', 'score', 1,
                    'reasons', jsonb_build_array(format('New departure about %s', to_char(v_new_etd AT TIME ZONE 'UTC', 'HH24:MI"Z"')),
                                                 format('Avoids about %s min of airborne holding', v_delay),
                                                 format('%s forecast to reopen %s (%s)', v_hub, to_char(i.reopen_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), coalesce(i.reopen_quality, 'none'))))));
        END IF;
    END IF;
    -- Nothing to recommend now (landed, or the destination is no longer restricted): a proposal made under an earlier situation,
    -- such as DELAY_DEPARTURE written while the hub was closed, must not stay on the board as if it still held.
    UPDATE recommendation SET status = 'EXPIRED'
     WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id AND status = 'PROPOSED';
    RETURN NULL;
END $$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' AND p.proname = 'recommend_for_flight' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;

-- Refresh what the failed jobs left behind: one reassessment of every watched flight in each live scenario.
SELECT enqueue_reassessment(s.scenario_id, 'migration 013: refresh after recommend_for_flight fix', 'airport', 'SHJ')
  FROM scenario s WHERE EXISTS (SELECT 1 FROM reassessment_queue q WHERE q.scenario_id = s.scenario_id AND q.status = 'FAILED');
