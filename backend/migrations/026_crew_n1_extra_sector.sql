-- Crew Control: N+1 that includes the extra sector (only meaningful when a diversion is in play).
-- crew_leg_outlook() only shows how the approved FDP limit tightens with one more sector. The real extra sector after a
-- diversion is the return alternate -> hub. This uses the engine's own numbers for the best-ranked alternate of the duty's
-- last flight (rank_alternates: earliest return departure and the P90 return block time with its basis label) and measures
-- each crew member's N+1 legal end against departure + block, the same rule as the engine's crew return margin.
-- When rank_alternates returns no row every value is NULL (never a guess). Read-only, safe to re-run.
CREATE OR REPLACE FUNCTION crew_n1_extra_sector(p_scenario_id INT, p_duty_id BIGINT)
RETURNS TABLE (crew_id INT, alt_iata CHAR(3), return_block_min INT, return_block_basis TEXT,
               return_dep_utc TIMESTAMPTZ, return_arrival_utc TIMESTAMPTZ,
               margin_n1_extra_min INT, status_n1_extra TEXT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE rs rule_set%ROWTYPE; v_last BIGINT; a RECORD; o RECORD; v_m INT; v_dm INT; v_st TEXT; v_arr TIMESTAMPTZ;
BEGIN
    SELECT * INTO rs FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    SELECT l.flight_id INTO v_last FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
     ORDER BY l.leg_seq DESC LIMIT 1;
    SELECT r.alt_iata, r.return_block_min, r.return_block_basis, r.earliest_return_dep_utc
      INTO a FROM rank_alternates(p_scenario_id, v_last) r ORDER BY r.rank LIMIT 1;
    v_arr := a.earliest_return_dep_utc + make_interval(mins => a.return_block_min);
    FOR o IN SELECT * FROM crew_leg_outlook(p_scenario_id, p_duty_id) LOOP
        v_m := NULL; v_dm := NULL; v_st := 'VERIFICATION_REQUIRED';
        IF v_arr IS NOT NULL AND o.legal_end_n1_utc IS NOT NULL THEN
            v_m  := floor(extract(epoch FROM o.legal_end_n1_utc - v_arr) / 60)::int;
            v_dm := floor(extract(epoch FROM o.legal_end_n1_utc + make_interval(mins => rs.commander_discretion_min) - v_arr) / 60)::int;
            v_st := CASE WHEN v_dm < 0 THEN 'EXCEEDED' WHEN v_m < 0 THEN 'DISCRETION_REQUIRED'
                         WHEN v_m < rs.at_risk_threshold_min THEN 'AT_RISK' ELSE 'LEGAL' END;
        END IF;
        RETURN QUERY SELECT o.crew_id, a.alt_iata, a.return_block_min, a.return_block_basis,
                            a.earliest_return_dep_utc, v_arr, v_m, v_st;
    END LOOP;
END $$;
