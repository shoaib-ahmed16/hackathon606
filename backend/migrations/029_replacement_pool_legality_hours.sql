-- 029: Find replacement ranks by legality hours and looks beyond the standby slots.
--
-- Before: only crew holding an AVAILABLE standby slot were considered (104 of 528 captains), ranked by roster conflict / weekly workload.
-- Now, for the replacement's report time (SHJ local DAY of v_ref, see 028):
--   * SIGNED_IN  : the crew member has a duty with a sign-in that day (and it is not the duty being replaced).
--                  legality hours = approved max FDP of THEIR duty (its sign-in band and legs, fdp_calculation) minus the FDP that
--                  duty already uses (sign-in to projected on-blocks). Their duty must not overlap the replacement window.
--   * STANDBY    : holds an AVAILABLE standby slot covering the report time -> legality hours = approved max FDP for the report time.
--   * NO_SIGN_IN : active crew of that position with no duty that day and no standby slot -> treated as standby, same hours.
--   Blocked crew are never offered: any overlapping LEAVE / REST / TRAINING / SIM / GRT / DUTY / FLIGHT roster entry or any other duty
--   (window = report time .. projected end + minimum rest), wrong LVP, no FDP rule. Only STANDBY crew still show a blocked reason.
-- Suggestions are ordered by legality hours, most first (legal for the remaining legs, no conflict). is_suggested = the best five of them.
-- N+1 (one more sector) is computed from the approved rule for crew who have no duty that day and is NULL (verify) for signed-in crew.
-- New columns: pool_source, legality_min (hours available), need_min (FDP the flight needs from the report time).
SET search_path = fogops, public;

DROP FUNCTION IF EXISTS fogops.crew_replacement_options(integer, bigint, text, character, smallint);

CREATE FUNCTION crew_replacement_options(p_scenario_id INT, p_duty_id BIGINT, p_position TEXT,
                                         p_destination CHAR(3), p_from_leg_seq SMALLINT DEFAULT 1)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT, standby_id BIGINT, pattern_name TEXT, lvp_qualified BOOLEAN,
               base_iata CHAR(3), positioning_min INT, positioning_basis TEXT, available_at_utc TIMESTAMPTZ, new_sign_in_utc TIMESTAMPTZ,
               legs_n INT, max_fdp_n_min INT, legal_end_n_utc TIMESTAMPTZ, margin_n_min INT, ok_n BOOLEAN,
               legs_n1 INT, max_fdp_n1_min INT, legal_end_n1_utc TIMESTAMPTZ, margin_n1_min INT, ok_n1 BOOLEAN,
               projected_end_utc TIMESTAMPTZ, roster_conflict BOOLEAN, conflicts JSONB,
               week_duty_min INT, week_flying_min INT, pool_avg_duty_min INT, below_avg BOOLEAN, is_suggested BOOLEAN, verdict TEXT,
               from_leg_seq INT, report_station CHAR(3),
               pool_source TEXT, legality_min INT, need_min INT)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_rs INT := active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    v_rest INT; v_hub CHAR(3) := 'SHJ'; v_last BIGINT; v_proj TIMESTAMPTZ; v_legs INT; v_from INT; v_blk INTERVAL;
    v_band_tz TEXT; v_lvp_needed BOOLEAN; v_road INT; v_ref TIMESTAMPTZ; v_day DATE;
BEGIN
    SELECT greatest(v_now, min(fc.sign_in_utc)) INTO v_ref
      FROM fdp_calculation fc
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.is_current AND fc.crew_id IS NOT NULL;
    v_ref := coalesce(v_ref, v_now);
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720),
           CASE WHEN band_reference = 'FIXED_TZ' THEN band_tz ELSE 'Asia/Dubai' END
      INTO v_rest, v_band_tz FROM rule_set WHERE rule_set_id = v_rs;
    v_day := (v_ref AT TIME ZONE v_band_tz)::date;
    SELECT a.road_positioning_min INTO v_road FROM alternate_airport a
     WHERE a.hub_iata = v_hub AND a.alt_iata = p_destination;

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
        SELECT cm.crew_id, cm.full_name, cm.crew_type_code, cm.base_iata,
               sb.standby_id, sb.pattern_name,
               own.duty_id AS own_duty, own.max_fdp_min AS own_max,
               floor(extract(epoch FROM own.projected_end_utc - own.sign_in_utc) / 60)::int AS own_used,
               CASE WHEN own.duty_id IS NOT NULL THEN 'SIGNED_IN' WHEN sb.standby_id IS NOT NULL THEN 'STANDBY' ELSE 'NO_SIGN_IN' END AS src,
               EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = cm.crew_id AND q.qual_code = 'LVP') AS lvp,
               CASE WHEN cm.base_iata = p_destination THEN 0 WHEN p_destination = v_hub THEN 0 ELSE v_road END AS pos,
               CASE WHEN cm.base_iata = p_destination THEN 'CANDIDATE_BASE_IS_DESTINATION'
                    WHEN p_destination = v_hub THEN 'DESTINATION_IS_HUB'
                    WHEN v_road IS NOT NULL THEN 'ROAD_FROM_HUB' END AS pos_basis,
               (SELECT coalesce(sum(re.duty_min), 0)::int FROM roster_entry re
                 WHERE re.crew_id = cm.crew_id AND re.start_utc >= v_now - interval '7 days' AND re.start_utc < v_now
                   AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')) AS wk_duty,
               (SELECT coalesce(sum(re.flying_min), 0)::int FROM roster_entry re
                 WHERE re.crew_id = cm.crew_id AND re.start_utc >= v_now - interval '7 days' AND re.start_utc < v_now
                   AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')) AS wk_fly
          FROM crew_member cm
          LEFT JOIN LATERAL (SELECT s.* FROM standby_slot s
                              WHERE s.crew_id = cm.crew_id AND s.status = 'AVAILABLE' AND v_ref BETWEEN s.start_utc AND s.end_utc
                              ORDER BY s.start_utc LIMIT 1) sb ON TRUE
          LEFT JOIN LATERAL (SELECT fc.duty_id, fc.max_fdp_min, fc.sign_in_utc, fc.projected_end_utc FROM fdp_calculation fc
                              WHERE fc.scenario_id = p_scenario_id AND fc.crew_id = cm.crew_id AND fc.is_current
                                AND fc.duty_id <> p_duty_id AND fc.sign_in_utc IS NOT NULL
                                AND (fc.sign_in_utc AT TIME ZONE v_band_tz)::date = v_day
                              ORDER BY fc.sign_in_utc LIMIT 1) own ON TRUE
         WHERE cm.is_active AND cm.crew_type_code = p_position
    ), calc AS (
        SELECT c.*, greatest(v_ref, v_now + make_interval(mins => coalesce(c.pos, 0))) AS si,
               avg(c.wk_duty) OVER () AS avg_duty
          FROM cand c
    ), calc2 AS (
        SELECT c.*, r.max_fdp_min AS mx, r1.max_fdp_min AS mx1,
               CASE WHEN v_proj IS NULL THEN NULL ELSE greatest(v_proj, c.si + coalesce(v_blk, interval '0')) END AS pe
          FROM calc c
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code, (c.si AT TIME ZONE v_band_tz)::time, v_legs) r ON TRUE
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code, (c.si AT TIME ZONE v_band_tz)::time, v_legs + 1) r1 ON TRUE
    ), calc3 AS (
        SELECT c.*,
               -- legality hours: signed in = approved max FDP of their duty minus what it already uses; otherwise the approved max FDP
               CASE WHEN c.src = 'SIGNED_IN' THEN c.own_max - c.own_used ELSE c.mx END AS avail,
               CASE WHEN c.pe IS NULL THEN NULL ELSE floor(extract(epoch FROM c.pe - c.si) / 60)::int END AS need
          FROM calc2 c
    ), conf AS (
        SELECT c.crew_id,
               coalesce(jsonb_agg(jsonb_build_object('duty_type', re.duty_type, 'block', re.block_name,
                        'start_local', re.start_local, 'end_local', re.end_local))
                        FILTER (WHERE re.roster_id IS NOT NULL), '[]') AS roster_conf,
               (SELECT count(*) FROM fdp_calculation od
                 WHERE od.scenario_id = p_scenario_id AND od.crew_id = c.crew_id AND od.is_current AND od.duty_id <> p_duty_id
                   AND od.sign_in_utc IS NOT NULL
                   AND od.sign_in_utc < coalesce(c.pe, c.si) + make_interval(mins => v_rest)
                   AND coalesce(od.projected_end_utc, od.legal_end_utc, od.sign_in_utc) + make_interval(mins => v_rest) > c.si) AS other_duties
          FROM calc3 c
          LEFT JOIN roster_entry re ON re.crew_id = c.crew_id
               AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT','LEAVE','REST')
               AND re.start_utc < coalesce(c.pe, c.si) + make_interval(mins => v_rest)
               AND re.end_utc > c.si
         GROUP BY c.crew_id, c.pe, c.si
    ), res AS (
        SELECT c.*, cf.roster_conf,
               (jsonb_array_length(cf.roster_conf) > 0 OR cf.other_duties > 0) AS has_conf,
               CASE WHEN c.avail IS NULL OR c.need IS NULL THEN NULL ELSE c.avail >= c.need END AS n_ok,
               CASE WHEN c.src = 'SIGNED_IN' OR c.mx1 IS NULL OR c.need IS NULL THEN NULL ELSE c.mx1 >= c.need END AS n1_ok,
               CASE WHEN c.pos IS NULL THEN 'VERIFY: no positioning time configured for ' || p_destination
                    WHEN v_lvp_needed AND NOT c.lvp THEN 'NOT LVP QUALIFIED (LVP in force at destination)'
                    WHEN c.avail IS NULL THEN 'VERIFY: no FDP rule for this crew type/legs'
                    WHEN c.need IS NULL THEN 'VERIFY: projected landing unknown'
                    WHEN c.avail < c.need THEN 'NOT LEGAL for remaining legs'
                    WHEN jsonb_array_length(cf.roster_conf) > 0 OR cf.other_duties > 0 THEN 'LEGAL but breaks planned roster'
                    ELSE 'CANDIDATE' END AS verd
          FROM calc3 c JOIN conf cf USING (crew_id)
    ), ranked AS (
        SELECT x.*, row_number() OVER (ORDER BY (x.verd = 'CANDIDATE') DESC, x.avail DESC NULLS LAST,
                                                 coalesce(x.n1_ok, FALSE) DESC, x.wk_duty, x.crew_id) AS rn
          FROM res x WHERE x.verd = 'CANDIDATE' OR x.src = 'STANDBY'
    )
    SELECT x.crew_id, x.full_name, x.crew_type_code, x.standby_id, x.pattern_name, x.lvp, x.base_iata,
           x.pos, x.pos_basis, x.si, x.si,
           v_legs, CASE WHEN x.src = 'SIGNED_IN' THEN x.own_max ELSE x.mx END, x.si + make_interval(mins => x.avail),
           x.avail - x.need, x.n_ok,
           v_legs + 1, x.mx1, x.si + make_interval(mins => x.mx1), x.mx1 - x.need, x.n1_ok,
           x.pe, x.has_conf, x.roster_conf,
           x.wk_duty, x.wk_fly, round(x.avg_duty)::int, (x.wk_duty <= x.avg_duty),
           (x.verd = 'CANDIDATE' AND x.rn <= 5),
           x.verd, v_from, p_destination,
           x.src, x.avail, x.need
      FROM ranked x ORDER BY x.rn;
END $$;

-- standby_candidates() (Ask, recovery plan) reads the same function: same columns as before, same answer.
CREATE OR REPLACE FUNCTION standby_candidates(p_scenario_id INT, p_duty_id BIGINT, p_position TEXT, p_station CHAR(3), p_from_leg_seq SMALLINT)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT, standby_id BIGINT, pattern_name TEXT, lvp_qualified BOOLEAN,
               positioning_min INT, new_sign_in_utc TIMESTAMPTZ, legs_to_operate INT, max_fdp_min INT, legal_end_utc TIMESTAMPTZ,
               projected_end_utc TIMESTAMPTZ, margin_min INT, roster_conflict BOOLEAN, conflicts JSONB, verdict TEXT)
LANGUAGE sql STABLE SET search_path = fogops, public AS $$
    SELECT o.crew_id, o.full_name, o.position_code, o.standby_id, o.pattern_name, o.lvp_qualified,
           o.positioning_min, o.new_sign_in_utc, o.legs_n, o.max_fdp_n_min, o.legal_end_n_utc,
           o.projected_end_utc, o.margin_n_min, o.roster_conflict, o.conflicts, o.verdict
      FROM crew_replacement_options(p_scenario_id, p_duty_id, p_position, p_station, p_from_leg_seq) o
$$;
