-- 028: the replacement finder works for duties that have not started.
-- 013 judged every standby crew as signing in NOW. For a duty two days ahead that window ends long before the flight, so every
-- candidate came back 'NOT LEGAL for remaining legs' and Find replacement showed no suggestion. Now the replacement reports at the
-- duty's own report time when that is later than now + positioning (a duty already running behaves exactly as before), standby
-- availability and the roster-conflict window are checked at that time.
-- Suggested = a clean CANDIDATE (legal for the remaining legs, LVP, no roster conflict) at or below the pool's weekly average; legality for
-- one more sector (N+1) only ranks candidates, it no longer blocks a suggestion (a what-if before any diversion is initiated). Same signature as 013: standby_candidates() follows.
SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION crew_replacement_options(p_scenario_id INT, p_duty_id BIGINT, p_position TEXT,
                                                    p_destination CHAR(3), p_from_leg_seq SMALLINT DEFAULT 1)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT, standby_id BIGINT, pattern_name TEXT, lvp_qualified BOOLEAN,
               base_iata CHAR(3), positioning_min INT, positioning_basis TEXT, available_at_utc TIMESTAMPTZ, new_sign_in_utc TIMESTAMPTZ,
               legs_n INT, max_fdp_n_min INT, legal_end_n_utc TIMESTAMPTZ, margin_n_min INT, ok_n BOOLEAN,
               legs_n1 INT, max_fdp_n1_min INT, legal_end_n1_utc TIMESTAMPTZ, margin_n1_min INT, ok_n1 BOOLEAN,
               projected_end_utc TIMESTAMPTZ, roster_conflict BOOLEAN, conflicts JSONB,
               week_duty_min INT, week_flying_min INT, pool_avg_duty_min INT, below_avg BOOLEAN, is_suggested BOOLEAN, verdict TEXT,
               from_leg_seq INT, report_station CHAR(3))
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_rs INT := active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    v_rest INT; v_hub CHAR(3) := 'SHJ'; v_last BIGINT; v_proj TIMESTAMPTZ; v_legs INT; v_from INT; v_blk INTERVAL;
    v_band_tz TEXT; v_lvp_needed BOOLEAN; v_road INT; v_ref TIMESTAMPTZ;
BEGIN
    -- reference moment: a duty that has not started yet is replaced for ITS OWN report time, not for "now"
    -- (a replacement who signs in now would be judged against a window that ends days before the flight)
    SELECT greatest(v_now, min(fc.sign_in_utc)) INTO v_ref
      FROM fdp_calculation fc
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.is_current AND fc.crew_id IS NOT NULL;
    v_ref := coalesce(v_ref, v_now);
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720),
           CASE WHEN band_reference = 'FIXED_TZ' THEN band_tz ELSE 'Asia/Dubai' END
      INTO v_rest, v_band_tz FROM rule_set WHERE rule_set_id = v_rs;
    SELECT a.road_positioning_min INTO v_road FROM alternate_airport a
     WHERE a.hub_iata = v_hub AND a.alt_iata = p_destination;

    -- the replacement starts after the last leg that has already been flown (landed, including at an alternate)
    SELECT greatest(p_from_leg_seq, coalesce(max(l.leg_seq) FILTER (WHERE s.ata_utc IS NOT NULL), 0) + 1)
      INTO v_from
      FROM crew_duty_leg l LEFT JOIN flight_state s ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active;
    SELECT greatest(1, count(*)) INTO v_legs FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
       AND l.leg_seq >= v_from AND l.leg_source <> 'POSITIONING';
    SELECT l.flight_id INTO v_last FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
     ORDER BY l.leg_seq DESC LIMIT 1;
    SELECT ts INTO v_proj FROM projected_on_blocks(p_scenario_id, v_last);
    SELECT f.sta_utc - f.std_utc INTO v_blk FROM flight f WHERE f.flight_id = v_last;
    v_lvp_needed := (SELECT requires_lvp FROM crew_type WHERE code = p_position)
                    AND EXISTS (SELECT 1 FROM crew_duty_leg l JOIN flight f ON f.flight_id = l.flight_id
                                 WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
                                   AND l.leg_seq >= v_from AND lvp_in_force(p_scenario_id, f.arr_iata));

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
           AND v_ref BETWEEN sb.start_utc AND sb.end_utc
           AND NOT EXISTS (SELECT 1 FROM crew_assignment ca JOIN crew_duty cd ON cd.duty_id = ca.duty_id
                            WHERE ca.scenario_id = p_scenario_id AND ca.crew_id = sb.crew_id AND ca.valid_to IS NULL
                              AND cd.sign_in_utc BETWEEN v_ref - interval '14 hours' AND v_ref + interval '14 hours')
    ), calc AS (
        SELECT c.*, greatest(v_ref, v_now + make_interval(mins => coalesce(c.pos, 0))) AS si,
               r.max_fdp_min AS mx, r1.max_fdp_min AS mx1,
               avg(c.wk_duty) OVER () AS avg_duty
          FROM cand c
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code,
                       ((greatest(v_ref, v_now + make_interval(mins => coalesce(c.pos, 0)))) AT TIME ZONE v_band_tz)::time, v_legs) r ON TRUE
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code,
                       ((greatest(v_ref, v_now + make_interval(mins => coalesce(c.pos, 0)))) AT TIME ZONE v_band_tz)::time, v_legs + 1) r1 ON TRUE
    ), calc2 AS (
        SELECT c.*, c.si + make_interval(mins => c.mx)  AS le,
                    c.si + make_interval(mins => c.mx1) AS le1,
                    -- the flight cannot end before this crew has reached the aircraft and flown the last leg
                    CASE WHEN v_proj IS NULL THEN NULL ELSE greatest(v_proj, c.si + coalesce(v_blk, interval '0')) END AS pe
          FROM calc c
    ), conf AS (
        SELECT c.crew_id,
               coalesce(jsonb_agg(jsonb_build_object('duty_type', re.duty_type, 'block', re.block_name,
                        'start_local', re.start_local, 'end_local', re.end_local))
                        FILTER (WHERE re.roster_id IS NOT NULL), '[]') AS conflicts
          FROM calc2 c
          LEFT JOIN roster_entry re ON re.crew_id = c.crew_id
               AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')
               AND re.start_utc < coalesce(greatest(c.pe, c.le), c.le) + make_interval(mins => v_rest)
               AND re.end_utc > c.si
         GROUP BY c.crew_id
    ), res AS (
        SELECT c.*, cf.conflicts,
               jsonb_array_length(cf.conflicts) > 0 AS has_conf,
               CASE WHEN c.mx IS NULL OR c.pe IS NULL THEN NULL ELSE c.le >= c.pe END AS n_ok,
               CASE WHEN c.mx1 IS NULL OR c.pe IS NULL THEN NULL ELSE c.le1 >= c.pe END AS n1_ok,
               CASE WHEN c.pos IS NULL THEN 'VERIFY: no positioning time configured for ' || p_destination
                    WHEN v_lvp_needed AND NOT c.lvp THEN 'NOT LVP QUALIFIED (LVP in force at destination)'
                    WHEN c.mx IS NULL THEN 'VERIFY: no FDP rule for this crew type/legs'
                    WHEN c.pe IS NULL THEN 'VERIFY: projected landing unknown'
                    WHEN c.le < c.pe THEN 'NOT LEGAL for remaining legs'
                    WHEN jsonb_array_length(cf.conflicts) > 0 THEN 'LEGAL but breaks planned roster'
                    ELSE 'CANDIDATE' END AS verd
          FROM calc2 c JOIN conf cf USING (crew_id)
    )
    SELECT x.crew_id, x.full_name, x.crew_type_code, x.standby_id, x.pattern_name, x.lvp, x.base_iata,
           x.pos, x.pos_basis, x.si, x.si,
           v_legs, x.mx, x.le, floor(extract(epoch FROM x.le - x.pe)/60)::int, x.n_ok,
           v_legs + 1, x.mx1, x.le1, floor(extract(epoch FROM x.le1 - x.pe)/60)::int, x.n1_ok,
           x.pe, x.has_conf, x.conflicts,
           x.wk_duty, x.wk_fly, round(x.avg_duty)::int, (x.wk_duty <= x.avg_duty),
           (x.verd = 'CANDIDATE' AND x.wk_duty <= x.avg_duty),
           x.verd, v_from, p_destination
      FROM res x
     ORDER BY (x.verd = 'CANDIDATE') DESC,
              coalesce(x.n1_ok, FALSE) DESC,
              (x.wk_duty <= x.avg_duty) DESC,
              x.wk_duty,
              floor(extract(epoch FROM x.le - x.pe)/60) DESC NULLS LAST,
              x.crew_id;
END $$;

