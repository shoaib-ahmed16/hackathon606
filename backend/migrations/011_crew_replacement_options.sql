-- Crew Control: replacement finder that follows the flight's destination, checks the current legs (N) and one more
-- sector (N+1) against the approved FDP rules, and ranks by weekly workload.
-- Additive only: standby_candidates() is left untouched. All legality maths stays in the approved rule tables
-- (lookup_fdp_rule); nothing here invents a rule. Safe to re-run (CREATE OR REPLACE).

-- ---------------------------------------------------------------------
-- 1. Crew already on a duty: legality for the current legs (N) and for one more sector (N+1).
--    N is the stored fdp_calculation; N+1 is the same sign-in re-checked with legs_counted + 1.
--    The extra sector's own flying time is NOT added (same convention as flight_decision_inputs):
--    N+1 only shows how the approved limit tightens when a sector is added.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_leg_outlook(p_scenario_id INT, p_duty_id BIGINT)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT,
               legs_n INT, max_fdp_n_min INT, margin_n_min INT, status_n TEXT,
               legs_n1 INT, max_fdp_n1_min INT, legal_end_n1_utc TIMESTAMPTZ, margin_n1_min INT, status_n1 TEXT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE rs rule_set%ROWTYPE; c RECORD; r fdp_rule%ROWTYPE;
        v_le TIMESTAMPTZ; v_m INT; v_dm INT; v_st TEXT;
BEGIN
    SELECT * INTO rs FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    FOR c IN SELECT fc.*, cm.full_name AS name FROM fdp_calculation fc JOIN crew_member cm ON cm.crew_id = fc.crew_id
              WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.is_current AND fc.crew_id IS NOT NULL
              ORDER BY fc.margin_min NULLS FIRST, fc.crew_id LOOP
        v_le := NULL; v_m := NULL; v_dm := NULL; v_st := 'VERIFICATION_REQUIRED';
        IF c.sign_in_utc IS NOT NULL AND c.sign_in_local_time IS NOT NULL AND c.projected_end_utc IS NOT NULL
           AND c.status <> 'VERIFICATION_REQUIRED' THEN
            r := lookup_fdp_rule(rs.rule_set_id, c.position_code, c.sign_in_local_time, c.legs_counted + 1);
            IF r.rule_id IS NOT NULL THEN
                v_le := c.sign_in_utc + make_interval(mins => r.max_fdp_min);
                v_m  := floor(extract(epoch FROM v_le - c.projected_end_utc) / 60)::int;
                v_dm := floor(extract(epoch FROM v_le + make_interval(mins => rs.commander_discretion_min) - c.projected_end_utc) / 60)::int;
                v_st := CASE WHEN v_dm < 0 THEN 'EXCEEDED' WHEN v_m < 0 THEN 'DISCRETION_REQUIRED'
                             WHEN v_m < rs.at_risk_threshold_min THEN 'AT_RISK' ELSE 'LEGAL' END;
            END IF;
        END IF;
        RETURN QUERY SELECT c.crew_id, c.name, c.position_code,
                            c.legs_counted::int, c.max_fdp_min, c.margin_min, c.status::text,
                            c.legs_counted::int + 1, r.max_fdp_min, v_le, v_m, v_st;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 2. Replacement options for a duty, evaluated for the flight's destination.
--    p_destination = where the flight lands (the diversion airport when diverted, else the planned arrival).
--    Positioning: 0 when the candidate's base is the destination or the destination is the hub, otherwise the configured
--    road time hub -> destination (alternate_airport, labelled ASSUMED there). No configured time -> VERIFY, never a guess.
--    Weekly workload: duty and flying minutes in roster_entry over the 7 days before "now" (the loaded roster may cover
--    less). It is a workload comparison, not a legal limit: no weekly cap is configured in the approved rules.
--    is_suggested = candidate, legal for N and for N+1, and weekly duty at or below the pool average
--    ("at or" so that a pool with equal or missing history, e.g. all 0, still gets suggestions). below_avg means the same test.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION crew_replacement_options(p_scenario_id INT, p_duty_id BIGINT, p_position TEXT,
                                                    p_destination CHAR(3), p_from_leg_seq SMALLINT DEFAULT 1)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT, standby_id BIGINT, pattern_name TEXT,
               lvp_qualified BOOLEAN, base_iata CHAR(3),
               positioning_min INT, positioning_basis TEXT, available_at_utc TIMESTAMPTZ, new_sign_in_utc TIMESTAMPTZ,
               legs_n INT, max_fdp_n_min INT, legal_end_n_utc TIMESTAMPTZ, margin_n_min INT, ok_n BOOLEAN,
               legs_n1 INT, max_fdp_n1_min INT, legal_end_n1_utc TIMESTAMPTZ, margin_n1_min INT, ok_n1 BOOLEAN,
               projected_end_utc TIMESTAMPTZ, roster_conflict BOOLEAN, conflicts JSONB,
               week_duty_min INT, week_flying_min INT, pool_avg_duty_min INT, below_avg BOOLEAN,
               is_suggested BOOLEAN, verdict TEXT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_rs INT := active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    v_rest INT; v_hub CHAR(3) := 'SHJ'; v_last BIGINT; v_proj TIMESTAMPTZ; v_legs INT;
    v_band_tz TEXT; v_lvp_needed BOOLEAN; v_road INT;
BEGIN
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720),
           CASE WHEN band_reference = 'FIXED_TZ' THEN band_tz ELSE 'Asia/Dubai' END
      INTO v_rest, v_band_tz FROM rule_set WHERE rule_set_id = v_rs;
    SELECT a.road_positioning_min INTO v_road FROM alternate_airport a
     WHERE a.hub_iata = v_hub AND a.alt_iata = p_destination;
    SELECT count(*) INTO v_legs FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
       AND l.leg_seq >= p_from_leg_seq AND l.leg_source <> 'POSITIONING';
    SELECT l.flight_id INTO v_last FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
     ORDER BY l.leg_seq DESC LIMIT 1;
    SELECT ts INTO v_proj FROM projected_on_blocks(p_scenario_id, v_last);
    v_lvp_needed := (SELECT requires_lvp FROM crew_type WHERE code = p_position)
                    AND EXISTS (SELECT 1 FROM crew_duty_leg l JOIN flight f ON f.flight_id = l.flight_id
                                 WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
                                   AND l.leg_seq >= p_from_leg_seq AND lvp_in_force(p_scenario_id, f.arr_iata));

    RETURN QUERY
    WITH cand AS (
        SELECT sb.crew_id, cm.full_name, sb.crew_type_code, sb.standby_id, sb.pattern_name, cm.base_iata,
               EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = sb.crew_id AND q.qual_code = 'LVP') AS lvp,
               CASE WHEN cm.base_iata = p_destination THEN 0
                    WHEN p_destination = v_hub THEN 0
                    ELSE v_road END AS pos,
               CASE WHEN cm.base_iata = p_destination THEN 'CANDIDATE_BASE_IS_DESTINATION'
                    WHEN p_destination = v_hub THEN 'DESTINATION_IS_HUB'
                    WHEN v_road IS NOT NULL THEN 'ROAD_FROM_HUB' END AS pos_basis,
               (SELECT coalesce(sum(re.duty_min), 0)::int FROM roster_entry re
                 WHERE re.crew_id = sb.crew_id AND re.start_utc >= v_now - interval '7 days' AND re.start_utc < v_now
                   AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')) AS wk_duty,
               (SELECT coalesce(sum(re.flying_min), 0)::int FROM roster_entry re
                 WHERE re.crew_id = sb.crew_id AND re.start_utc >= v_now - interval '7 days' AND re.start_utc < v_now
                   AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')) AS wk_fly
          FROM standby_slot sb JOIN crew_member cm ON cm.crew_id = sb.crew_id
         WHERE sb.crew_type_code = p_position AND sb.status = 'AVAILABLE'
           AND v_now BETWEEN sb.start_utc AND sb.end_utc
           AND NOT EXISTS (SELECT 1 FROM crew_assignment ca JOIN crew_duty cd ON cd.duty_id = ca.duty_id
                            WHERE ca.scenario_id = p_scenario_id AND ca.crew_id = sb.crew_id AND ca.valid_to IS NULL
                              AND cd.sign_in_utc BETWEEN v_now - interval '14 hours' AND v_now + interval '14 hours')
    ), calc AS (
        SELECT c.*, r.max_fdp_min AS mx, r1.max_fdp_min AS mx1,
               v_now + make_interval(mins => r.max_fdp_min)  AS le,
               v_now + make_interval(mins => r1.max_fdp_min) AS le1,
               avg(c.wk_duty) OVER () AS avg_duty
          FROM cand c
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code, (v_now AT TIME ZONE v_band_tz)::time, v_legs) r ON TRUE
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code, (v_now AT TIME ZONE v_band_tz)::time, v_legs + 1) r1 ON TRUE
    ), conf AS (
        SELECT c.crew_id,
               coalesce(jsonb_agg(jsonb_build_object('duty_type', re.duty_type, 'block', re.block_name,
                        'start_local', re.start_local, 'end_local', re.end_local))
                        FILTER (WHERE re.roster_id IS NOT NULL), '[]') AS conflicts
          FROM calc c
          LEFT JOIN roster_entry re ON re.crew_id = c.crew_id
               AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')
               AND re.start_utc < coalesce(greatest(v_proj, c.le), c.le) + make_interval(mins => v_rest)
               AND re.end_utc > v_now
         GROUP BY c.crew_id
    ), res AS (
        SELECT c.*, cf.conflicts,
               jsonb_array_length(cf.conflicts) > 0 AS has_conf,
               CASE WHEN c.mx IS NULL OR v_proj IS NULL THEN NULL ELSE c.le >= v_proj END AS n_ok,
               CASE WHEN c.mx1 IS NULL OR v_proj IS NULL THEN NULL ELSE c.le1 >= v_proj END AS n1_ok,
               CASE WHEN c.pos IS NULL THEN 'VERIFY: no positioning time configured for ' || p_destination
                    WHEN v_lvp_needed AND NOT c.lvp THEN 'NOT LVP QUALIFIED (LVP in force at destination)'
                    WHEN c.mx IS NULL THEN 'VERIFY: no FDP rule for this crew type/legs'
                    WHEN v_proj IS NULL THEN 'VERIFY: projected landing unknown'
                    WHEN c.le < v_proj THEN 'NOT LEGAL for remaining legs'
                    WHEN jsonb_array_length(cf.conflicts) > 0 THEN 'LEGAL but breaks planned roster'
                    ELSE 'CANDIDATE' END AS verd
          FROM calc c JOIN conf cf USING (crew_id)
    )
    SELECT x.crew_id, x.full_name, x.crew_type_code, x.standby_id, x.pattern_name, x.lvp, x.base_iata,
           x.pos, x.pos_basis, v_now + make_interval(mins => coalesce(x.pos, 0)), v_now,
           v_legs, x.mx, x.le, floor(extract(epoch FROM x.le - v_proj)/60)::int, x.n_ok,
           v_legs + 1, x.mx1, x.le1, floor(extract(epoch FROM x.le1 - v_proj)/60)::int, x.n1_ok,
           v_proj, x.has_conf, x.conflicts,
           x.wk_duty, x.wk_fly, round(x.avg_duty)::int, (x.wk_duty <= x.avg_duty),
           (x.verd = 'CANDIDATE' AND coalesce(x.n1_ok, FALSE) AND x.wk_duty <= x.avg_duty),
           x.verd
      FROM res x
     ORDER BY (x.verd = 'CANDIDATE') DESC,
              coalesce(x.n1_ok, FALSE) DESC,
              (x.wk_duty <= x.avg_duty) DESC,
              x.wk_duty,
              floor(extract(epoch FROM x.le - v_proj)/60) DESC NULLS LAST,
              x.crew_id;
END $$;
