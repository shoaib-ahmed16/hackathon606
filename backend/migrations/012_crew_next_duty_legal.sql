-- Crew Control: from when is the crew legal to start the NEXT duty/flight.
-- = projected end of the current duty (on-blocks of the last leg) + the rule set's minimum rest.
-- The minimum rest is ASSUMED in the supplied data (rule_set.parameters.min_rest_note); it is returned with that label,
-- and NULL (never a default) when the parameter is missing. Read-only, safe to re-run.
CREATE OR REPLACE FUNCTION crew_next_duty_legal(p_scenario_id INT, p_duty_id BIGINT)
RETURNS TABLE (crew_id INT, duty_end_utc TIMESTAMPTZ, rest_min INT, rest_quality TEXT, next_legal_from_utc TIMESTAMPTZ)
LANGUAGE sql STABLE AS $$
    WITH rs AS (
        SELECT (parameters->>'min_rest_after_duty_min')::int AS rest,
               CASE WHEN parameters->>'min_rest_note' ILIKE 'ASSUMED%' THEN 'ASSUMED' ELSE 'MEASURED' END AS q
          FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', scenario_now(p_scenario_id))
    )
    SELECT fc.crew_id, fc.projected_end_utc, rs.rest, rs.q,
           CASE WHEN fc.projected_end_utc IS NULL OR rs.rest IS NULL THEN NULL
                ELSE fc.projected_end_utc + make_interval(mins => rs.rest) END
      FROM fdp_calculation fc CROSS JOIN rs
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.is_current AND fc.crew_id IS NOT NULL
$$;
