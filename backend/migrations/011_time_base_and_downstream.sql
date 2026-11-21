-- 011: DB team drop "fogops_db (2)": time-base rules TB-1..TB-4, duty_started, downstream_impact().
-- Already in our DB from 004 (so not repeated): richer pax_connection, v_connection_risk, recovery-leg ON CONFLICT.
--  * flight_decision_inputs() gains flight_phase / anchor_utc / endurance_until / earliest_sign_in. Every hold/divert maths is
--    anchored at the "decision moment" of the flight (TB-1): now for HOLDING/AIRBORNE, projected arrival - 20 min before departure,
--    not divertible once diverted/landed/cancelled.
--  * propose_hold_or_divert() takes the new version as delivered (it was never patched by us).
--  * rank_alternates() = OUR 010 version (fuel policy, no repeat divert) + the new anchor maths and the two new blockers
--    FLIGHT_NOT_DIVERTIBLE and TIME_BASE_INCONSISTENT (TB-4).
--  * v_crew_legality_ranking.duty_started (TB-3): before sign-in the UI shows "duty starts", not a countdown.
--  * downstream_impact(): aircraft knock-on, crew next duty + rest, connections.
-- Suggestions are re-computed at the end so the board reflects the new rules.

SET search_path = fogops, public;

DROP FUNCTION IF EXISTS fogops.flight_decision_inputs(integer, bigint);
CREATE OR REPLACE FUNCTION flight_decision_inputs(p_scenario_id INT, p_flight_id BIGINT)
RETURNS TABLE (hub_iata CHAR(3), now_utc TIMESTAMPTZ, endurance_left_min INT, fuel_quality TEXT,
               hub_status TEXT, hub_lvp BOOLEAN, reopen_utc TIMESTAMPTZ, reopen_quality TEXT,
               cockpit_all_lvp BOOLEAN, crew_known BOOLEAN,
               legal_end_now TIMESTAMPTZ, disc_end_now TIMESTAMPTZ,
               legal_end_if_diverted TIMESTAMPTZ, disc_end_if_diverted TIMESTAMPTZ,
               -- time-base fields (rule TB-1..TB-4, see README "Time-base rules")
               flight_phase TEXT, anchor_utc TIMESTAMPTZ, endurance_until TIMESTAMPTZ, earliest_sign_in TIMESTAMPTZ)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE v_now TIMESTAMPTZ := scenario_now(p_scenario_id); f flight%ROWTYPE; rs rule_set%ROWTYPE;
        e RECORD; hs RECORD; c RECORD; st flight_state%ROWTYPE; v_phase TEXT; v_anchor TIMESTAMPTZ; v_si TIMESTAMPTZ;
        v_le TIMESTAMPTZ; v_de TIMESTAMPTZ; v_led TIMESTAMPTZ; v_ded TIMESTAMPTZ; v_known BOOLEAN := TRUE; n INT := 0;
BEGIN
    SELECT * INTO f FROM flight WHERE flight_id = p_flight_id;
    SELECT * INTO st FROM flight_state WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id;
    -- TB-1: the decision moment depends on where the flight is in its life, not on "now" alone
    v_phase := CASE WHEN st.status IN ('HOLDING') THEN 'HOLDING'
                    WHEN st.status IN ('AIRBORNE','TAXI_OUT') THEN 'AIRBORNE'
                    WHEN st.status IN ('DIVERTING','LANDED','ON_BLOCKS','CANCELLED') THEN 'NOT_APPLICABLE'
                    ELSE 'NOT_DEPARTED' END;
    v_anchor := CASE v_phase
                  WHEN 'HOLDING'  THEN v_now
                  WHEN 'AIRBORNE' THEN v_now      -- an airborne flight can divert now (position: hub area, see assumptions)
                  ELSE greatest(v_now, coalesce(st.eta_utc, f.sta_utc) - interval '20 minutes') END;  -- pre-departure: anchor at arrival
    SELECT * INTO rs FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', v_now);
    SELECT fe.as_of_utc + make_interval(mins => fe.est_holding_endurance_min) AS until, fe.quality::text AS q
      INTO e FROM flight_fuel_estimate fe
     WHERE fe.scenario_id = p_scenario_id AND fe.flight_id = p_flight_id ORDER BY fe.as_of_utc DESC LIMIT 1;
    SELECT * INTO hs FROM airport_status_event x
     WHERE x.scenario_id = p_scenario_id AND x.iata = f.arr_iata AND x.effective_from_utc <= v_now
     ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1;
    -- operating crew that gate legality: current legs (legs_counted) and legs + 1 after a diversion
    FOR c IN SELECT fc.* FROM fdp_calculation fc
               JOIN crew_duty_leg l ON l.duty_id = fc.duty_id AND l.scenario_id = fc.scenario_id
               JOIN crew_type ct ON ct.code = fc.position_code AND ct.gates_flight_legality
              WHERE fc.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active
                AND fc.is_current AND fc.crew_id IS NOT NULL LOOP
        n := n + 1;
        v_si := least(coalesce(v_si, c.sign_in_utc), c.sign_in_utc);
        IF c.status = 'VERIFICATION_REQUIRED' OR c.legal_end_utc IS NULL THEN v_known := FALSE; CONTINUE; END IF;
        v_le := least(coalesce(v_le, c.legal_end_utc), c.legal_end_utc);
        v_de := least(coalesce(v_de, c.discretion_end_utc), c.discretion_end_utc);
        DECLARE r fdp_rule%ROWTYPE; BEGIN
            r := lookup_fdp_rule(rs.rule_set_id, c.position_code, c.sign_in_local_time, c.legs_counted + 1);
            IF r.rule_id IS NULL THEN v_known := FALSE; CONTINUE; END IF;
            v_led := least(coalesce(v_led, c.sign_in_utc + make_interval(mins => r.max_fdp_min)),
                           c.sign_in_utc + make_interval(mins => r.max_fdp_min));
            v_ded := least(coalesce(v_ded, c.sign_in_utc + make_interval(mins => r.max_fdp_min + rs.commander_discretion_min)),
                           c.sign_in_utc + make_interval(mins => r.max_fdp_min + rs.commander_discretion_min));
        END;
    END LOOP;
    RETURN QUERY SELECT f.arr_iata, v_now,
        CASE WHEN e.until IS NULL THEN NULL ELSE floor(extract(epoch FROM e.until - v_now)/60)::int END, e.q,
        hs.op_status::text, coalesce(hs.lvp_in_force, FALSE),
        CASE WHEN hs.op_status = 'OPEN' THEN greatest(hs.effective_from_utc, v_now) ELSE hs.expected_reopen_utc END,
        CASE WHEN hs.op_status = 'OPEN' THEN 'MEASURED' ELSE hs.quality::text END,
        (SELECT bool_and(EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = ca.crew_id AND q.qual_code = 'LVP'))
           FROM crew_duty_leg l
           JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id
                                  AND ca.valid_to IS NULL AND ca.from_leg_seq <= l.leg_seq
           JOIN crew_type ct ON ct.code = ca.position_code AND ct.requires_lvp
          WHERE l.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active),
        v_known AND n > 0, v_le, v_de, v_led, v_ded,
        v_phase, v_anchor, e.until, v_si;
END $$;

CREATE OR REPLACE FUNCTION propose_hold_or_divert(p_scenario_id INT, p_case_id INT, p_flight_id BIGINT,
                                                  p_generated_by TEXT DEFAULT 'rules-engine v1',
                                                  p_approach_min INT DEFAULT 10,
                                                  p_min_hold_spare_min INT DEFAULT 15)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    i RECORD; v_rec BIGINT; v_hold_block JSONB := '[]'; v_hold_ok BOOLEAN; v_hold_score NUMERIC := 0;
    v_land TIMESTAMPTZ; v_spare INT; v_hold_crew INT; v_best RECORD; v_conf NUMERIC; v_type rec_type;
    v_rationale TEXT; v_hold_reasons TEXT[] := '{}';
BEGIN
    SELECT * INTO i FROM flight_decision_inputs(p_scenario_id, p_flight_id);

    -- HOLD evaluation: land at forecast reopening + approach
    v_land := CASE WHEN i.reopen_utc IS NULL THEN NULL
                   ELSE greatest(i.reopen_utc, i.anchor_utc) + make_interval(mins => p_approach_min) END;
    v_spare := floor(extract(epoch FROM i.endurance_until - v_land)/60)::int;
    v_hold_crew := floor(extract(epoch FROM i.legal_end_now - v_land)/60)::int;
    IF i.reopen_utc IS NULL THEN v_hold_block := v_hold_block || jsonb_build_object('code','REOPENING_TIME_UNKNOWN','verify',true); END IF;
    IF i.endurance_left_min IS NULL THEN v_hold_block := v_hold_block || jsonb_build_object('code','FUEL_ENDURANCE_UNKNOWN','verify',true); END IF;
    IF v_spare < 0 THEN v_hold_block := v_hold_block || jsonb_build_object('code','ENDURANCE_ENDS_BEFORE_REOPENING','short_by_min',-v_spare); END IF;
    IF i.hub_lvp AND i.cockpit_all_lvp IS DISTINCT FROM TRUE THEN
        v_hold_block := v_hold_block || jsonb_build_object('code','CREW_NOT_LVP_QUALIFIED_FOR_HUB'); END IF;
    IF NOT i.crew_known THEN v_hold_block := v_hold_block || jsonb_build_object('code','CREW_LEGALITY_UNVERIFIED','verify',true);
    ELSIF v_land > i.disc_end_now THEN v_hold_block := v_hold_block || jsonb_build_object('code','CREW_EXCEEDS_FDP_EVEN_WITH_DISCRETION'); END IF;
    v_hold_ok := jsonb_array_length(v_hold_block) = 0;
    -- Policy: a feasible hold with at least the fuel buffer beats any diversion (no extra sector,
    -- no pax/aircraft out of position). A feasible hold below the buffer ranks after executable diversions.
    IF v_hold_ok THEN
        v_hold_score := CASE WHEN v_spare >= p_min_hold_spare_min THEN round(1.0 + least(1, v_spare / 60.0), 3)
                             ELSE 0.2 END;
    END IF;
    v_hold_reasons := array_remove(ARRAY[
        CASE WHEN v_land IS NOT NULL THEN format('Landing at %s after forecast reopening (%s)', to_char(v_land AT TIME ZONE 'UTC','HH24:MI"Z"'), i.reopen_quality) END,
        CASE WHEN v_spare IS NOT NULL THEN format('Fuel spare at landing %s min (%s)', v_spare, i.fuel_quality) END,
        CASE WHEN v_hold_crew IS NOT NULL THEN format('Crew margin at landing %s min', v_hold_crew) END,
        CASE WHEN v_hold_crew < 0 AND v_land <= i.disc_end_now THEN 'Needs commander discretion' END,
        CASE WHEN v_hold_ok AND v_spare < p_min_hold_spare_min
             THEN format('Fuel spare below the %s min hold buffer', p_min_hold_spare_min) END], NULL);

    -- confidence falls with every non-measured input
    v_conf := 0.9 - CASE WHEN i.fuel_quality IN ('ESTIMATED','ASSUMED','SIMULATED') THEN 0.15 ELSE 0 END
                  - CASE WHEN i.reopen_quality = 'FORECAST' THEN 0.10 ELSE 0 END
                  - CASE WHEN NOT i.crew_known THEN 0.20 ELSE 0 END;

    INSERT INTO recommendation (scenario_id, case_id, flight_id, rec_type, confidence, rationale, assumptions,
                                uncertainty, required_approver_role, rule_set_id, input_snapshot, generated_by,
                                valid_until_utc)
    VALUES (p_scenario_id, p_case_id, p_flight_id, 'MONITOR', greatest(0.3, v_conf), 'pending', '[]', '{}',
            'DISPATCH', active_rule_set('GCAA FDP', i.now_utc), to_jsonb(i), p_generated_by,
            i.now_utc + interval '15 minutes')
    RETURNING rec_id INTO v_rec;

    -- options: HOLD + alternates, ranked together (executable first, then score)
    INSERT INTO recommendation_option (rec_id, rank, action, alternate_iata, hold_until_utc, est_arrival_utc,
                                       fuel_margin_min, crew_margin_min, score, is_executable,
                                       blocking_constraints, reasons)
    SELECT v_rec, row_number() OVER (ORDER BY x.execable DESC, x.score DESC), x.action, x.alt, x.hold_until,
           x.arr, x.fuel_m, x.crew_m, x.score, x.execable, x.blocking, x.reasons
      FROM (
        SELECT 'HOLD'::rec_type AS action, NULL::char(3) AS alt,
               coalesce(i.endurance_until, i.anchor_utc) AS hold_until,
               v_land AS arr, v_spare AS fuel_m, v_hold_crew AS crew_m, v_hold_score AS score,
               v_hold_ok AS execable, v_hold_block AS blocking, v_hold_reasons AS reasons
        UNION ALL
        SELECT 'DIVERT', r.alt_iata, NULL, r.est_arrival_utc, r.fuel_margin_min, r.crew_return_margin_min, r.score,
               r.is_executable, r.blocking_constraints, r.reasons
          FROM rank_alternates(p_scenario_id, p_flight_id) r
      ) x;

    SELECT * INTO v_best FROM recommendation_option WHERE rec_id = v_rec AND rank = 1;
    v_type := CASE WHEN v_best.is_executable THEN v_best.action ELSE 'MONITOR' END;
    v_rationale := CASE
        WHEN NOT v_best.is_executable THEN
            'No option has all operational inputs confirmed: manual verification required before holding or diverting.'
        WHEN v_type = 'HOLD' THEN
            format('HOLD: fuel and crew cover the forecast reopening (%s). %s',
                   to_char(i.reopen_utc AT TIME ZONE 'UTC','HH24:MI"Z"'), array_to_string(v_best.reasons, '; '))
        ELSE format('DIVERT %s. %s. %s', v_best.alternate_iata,
                    CASE WHEN v_hold_ok THEN format('Hold possible but only %s min fuel spare (< %s min buffer)', v_spare, p_min_hold_spare_min)
                         ELSE 'Hold not feasible: ' || (SELECT string_agg(x->>'code', ', ') FROM jsonb_array_elements(v_hold_block) x) END,
                    array_to_string(v_best.reasons, '; ')) END;

    UPDATE recommendation SET rec_type = v_type, rationale = v_rationale,
        assumptions = jsonb_build_array(
            format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
            format('Hub reopening quality: %s', coalesce(i.reopen_quality, 'none')),
            'Distance to alternates measured from the hub (aircraft assumed in the hub terminal area)',
            'Diversion counts as one extra sector for every operating crew member',
            CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                 THEN format('Flight not yet departed: pre-departure assessment, all times anchored at projected arrival %s (not at the current clock)',
                             to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'))
                 ELSE format('Decision moment %s (%s)', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'), lower(i.flight_phase)) END,
            'Alternate status/parking taken from the latest airport_status_event',
            format('Hold preferred when feasible with >= %s min fuel spare at landing', p_min_hold_spare_min)),
        uncertainty = jsonb_build_object('reopening_utc', i.reopen_utc, 'reopening_quality', i.reopen_quality,
                                         'endurance_left_min', i.endurance_left_min)
     WHERE rec_id = v_rec;
    RETURN v_rec;
END $$;

CREATE OR REPLACE FUNCTION fogops.rank_alternates(p_scenario_id integer, p_flight_id bigint, p_km_per_min numeric DEFAULT 7.0, p_approach_min integer DEFAULT 10)
 RETURNS TABLE(rank integer, alt_iata character, alt_name text, is_executable boolean, score numeric, op_status text, lvp_in_force boolean, weather_above_minima boolean, stands_left integer, fuel_ok boolean, handling_ok boolean, distance_km numeric, est_flight_min integer, est_arrival_utc timestamp with time zone, fuel_margin_min integer, return_block_min integer, return_block_basis text, ready_at_alt_utc timestamp with time zone, earliest_return_dep_utc timestamp with time zone, latest_legal_return_dep_utc timestamp with time zone, latest_return_dep_with_discretion_utc timestamp with time zone, crew_return_margin_min integer, crew_outcome text, road_positioning_min integer, historical_diversions integer, hist_median_ground_min integer, blocking_constraints jsonb, reasons text[], score_breakdown jsonb, flight_min_p90 integer, flight_time_basis text, final_reserve_min integer, fuel_basis text, bingo_utc timestamp with time zone, return_arrival_hub_utc timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fogops', 'public'
AS $function$
#variable_conflict use_column
DECLARE
    i RECORD;
    v_reserve   INT := coalesce((SELECT value FROM divert_policy WHERE key = 'final_reserve_min'), 30)::int;
    v_fob       NUMERIC; v_burn NUMERIC; v_fuel_min NUMERIC;   -- fuel on board converted to minutes of hold "now"
BEGIN
    SELECT * INTO i FROM flight_decision_inputs(p_scenario_id, p_flight_id);

    SELECT fe.fuel_on_board_kg, fe.burn_rate_hold_kg_per_hr,
           (fe.fuel_on_board_kg::numeric / nullif(fe.burn_rate_hold_kg_per_hr, 0) * 60)
             - greatest(0, extract(epoch FROM (i.now_utc - fe.as_of_utc)) / 60)
      INTO v_fob, v_burn, v_fuel_min
      FROM flight_fuel_estimate fe
     WHERE fe.scenario_id = p_scenario_id AND fe.flight_id = p_flight_id
     ORDER BY fe.as_of_utc DESC LIMIT 1;

    RETURN QUERY
    WITH alt AS (
        SELECT aa.*, ap.name AS alt_name, ap.min_ground_time_min,
               st.op_status::text AS op_status, st.lvp_in_force, st.weather_above_minima, st.parking_available,
               st.fuel_ok, st.handling_ok,
               distance_km(i.hub_iata, aa.alt_iata) AS dist,
               (SELECT count(*) FROM diversion dv
                 WHERE dv.scenario_id = p_scenario_id AND dv.alternate_iata = aa.alt_iata
                   AND dv.original_flight_id <> p_flight_id
                   AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED'))::int AS occupied,
               b.p90_block_min, b.median_block_min, b.sample_n,
               l.airborne_p50_min AS l50, l.airborne_p90_min AS l90, l.sample_n AS l_n, l.source AS l_src
          FROM alternate_airport aa JOIN airport ap ON ap.iata = aa.alt_iata
          LEFT JOIN LATERAL (SELECT * FROM airport_status_event x
                              WHERE x.scenario_id = p_scenario_id AND x.iata = aa.alt_iata
                                AND x.effective_from_utc <= i.now_utc
                              ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1) st ON TRUE
          LEFT JOIN block_time_reference b ON b.from_iata = aa.alt_iata AND b.to_iata = i.hub_iata
          LEFT JOIN leg_time_reference l ON l.from_iata = i.hub_iata AND l.to_iata = aa.alt_iata
         WHERE aa.hub_iata = i.hub_iata AND aa.is_active
           -- A flight is diverted at most once per scenario, and a recovery leg never goes back to the alternate it just left:
           -- so neither is ever offered as a diversion option again.
           AND NOT EXISTS (SELECT 1 FROM diversion dx WHERE dx.scenario_id = p_scenario_id AND dx.original_flight_id = p_flight_id)
           AND NOT EXISTS (SELECT 1 FROM diversion dx WHERE dx.scenario_id = p_scenario_id AND dx.recovery_flight_id = p_flight_id
                                                          AND dx.alternate_iata = aa.alt_iata)
    ), m AS (
        SELECT a.*,
               -- outbound leg: history first, distance estimate only if the pair has no history row
               coalesce(a.l50, (ceil(a.dist / p_km_per_min) + p_approach_min)::int)                         AS fl_min,
               coalesce(a.l90, ceil((ceil(a.dist / p_km_per_min) + p_approach_min) * 1.25)::int)            AS fl90,
               CASE WHEN a.l_src = 'HISTORICAL' THEN format('P50/P90 of %s historical flights %s-%s', a.l_n, i.hub_iata, a.alt_iata)
                    WHEN a.l_src = 'ESTIMATED'  THEN format('ESTIMATED from distance (%s historical flights, need more)', a.l_n)
                    ELSE 'ESTIMATED from distance (no reference row)' END                                   AS fl_basis,
               coalesce(a.p90_block_min, (ceil(a.dist / p_km_per_min) + p_approach_min + 10)::int)          AS ret_blk,
               coalesce(a.median_block_min, a.p90_block_min, (ceil(a.dist / p_km_per_min) + p_approach_min + 10)::int) AS ret_med,
               CASE WHEN a.p90_block_min IS NOT NULL THEN format('P90 of %s historical %s-%s', a.sample_n, a.alt_iata, i.hub_iata)
                    ELSE 'ESTIMATED from distance' END                                                      AS ret_basis,
               a.parking_available - a.occupied AS stands
          FROM alt a
    ), t AS (
        SELECT m.*,
               i.anchor_utc + make_interval(mins => m.fl_min) AS arr_utc,
               -- fuel margin = minutes of fuel left on arrival above the final reserve
               CASE WHEN v_fuel_min IS NOT NULL THEN floor(v_fuel_min - m.fl90 - v_reserve)::int
                    WHEN i.endurance_left_min IS NOT NULL THEN i.endurance_left_min - m.fl90
               END AS fuel_margin,
               CASE WHEN v_fuel_min IS NOT NULL
                         THEN format('Fuel on board %s kg at %s kg/h hold burn; leg P90 %s min + %s min final reserve (ICAO)', v_fob, v_burn, m.fl90, v_reserve)
                    WHEN i.endurance_left_min IS NOT NULL
                         THEN format('LEGACY: hold endurance %s min minus leg P90 %s min (no fuel-on-board / burn rate entered)', i.endurance_left_min, m.fl90)
               END AS fuel_basis,
               i.anchor_utc + make_interval(mins => m.fl_min + m.min_ground_time_min) AS ready,
               greatest(i.anchor_utc + make_interval(mins => m.fl_min + m.min_ground_time_min),
                        coalesce(i.reopen_utc - make_interval(mins => m.ret_blk),
                                 i.anchor_utc + make_interval(mins => m.fl_min + m.min_ground_time_min))) AS earliest_dep,
               i.legal_end_if_diverted - make_interval(mins => m.ret_blk) AS latest_legal,
               i.disc_end_if_diverted  - make_interval(mins => m.ret_blk) AS latest_disc
          FROM m
    ), o AS (
        SELECT t.*,
               floor(extract(epoch FROM t.latest_legal - t.earliest_dep)/60)::int AS crew_margin,
               CASE WHEN NOT i.crew_known OR t.latest_legal IS NULL THEN 'VERIFY_CREW'
                    WHEN t.latest_legal >= t.earliest_dep THEN 'CREW_CAN_RETURN'
                    WHEN t.latest_disc  >= t.earliest_dep THEN 'NEEDS_COMMANDER_DISCRETION'
                    WHEN t.road_positioning_min IS NOT NULL THEN 'NEEDS_REPLACEMENT_BY_ROAD'
                    ELSE 'NEEDS_REPLACEMENT_DEADHEAD' END AS outcome,
               (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM (VALUES
                  (CASE WHEN t.op_status IS NULL THEN jsonb_build_object('code','ALTERNATE_STATUS_UNKNOWN','verify',true) END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.op_status <> 'OPEN' THEN jsonb_build_object('code','ALTERNATE_NOT_OPEN','value',t.op_status) END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.weather_above_minima IS NULL THEN jsonb_build_object('code','WEATHER_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.weather_above_minima IS FALSE THEN jsonb_build_object('code','WEATHER_BELOW_MINIMA') END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.stands IS NULL THEN jsonb_build_object('code','PARKING_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.stands <= 0 THEN jsonb_build_object('code','NO_PARKING','occupied',t.occupied) END),
                  (CASE WHEN t.fuel_ok IS FALSE THEN jsonb_build_object('code','NO_FUEL_AT_ALTERNATE') END),
                  (CASE WHEN t.handling_ok IS FALSE THEN jsonb_build_object('code','NO_HANDLING') END),
                  (CASE WHEN t.fuel_margin IS NULL THEN jsonb_build_object('code','FUEL_ENDURANCE_UNKNOWN','verify',true) END),
                  (CASE WHEN t.fuel_margin < 0 THEN jsonb_build_object('code','CANNOT_REACH_WITH_FUEL','margin_min',t.fuel_margin,'final_reserve_min',v_reserve) END),
                  (CASE WHEN t.lvp_in_force AND i.cockpit_all_lvp IS DISTINCT FROM TRUE
                        THEN jsonb_build_object('code','CREW_NOT_LVP_QUALIFIED_FOR_ALTERNATE') END),
                  (CASE WHEN i.flight_phase = 'NOT_APPLICABLE'
                        THEN jsonb_build_object('code','FLIGHT_NOT_DIVERTIBLE','phase','already diverted, landed or cancelled') END),
                  -- TB-4: a return that would depart before the crew has even signed in means the time base is wrong
                  (CASE WHEN i.earliest_sign_in IS NOT NULL AND t.earliest_dep < i.earliest_sign_in
                        THEN jsonb_build_object('code','TIME_BASE_INCONSISTENT','verify',true,
                                                'earliest_return_dep', t.earliest_dep, 'crew_sign_in', i.earliest_sign_in) END)
                ) v(x) WHERE x IS NOT NULL) AS blocking
          FROM t
    ), sc AS (
        SELECT o.*,
               CASE WHEN o.fuel_margin IS NULL THEN 0 ELSE least(1, greatest(0, o.fuel_margin / 30.0)) END AS s_fuel,
               CASE o.outcome WHEN 'CREW_CAN_RETURN' THEN 1.0
                              WHEN 'NEEDS_COMMANDER_DISCRETION' THEN 0.6
                              WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN greatest(0.2, 0.5 - o.road_positioning_min / 400.0)
                              WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN 0.1 ELSE 0.3 END AS s_crew,
               1 - least(1, o.ret_blk / 120.0) AS s_rec,
               CASE WHEN o.stands IS NULL THEN 0 ELSE least(1, greatest(0, o.stands / 4.0)) END AS s_stand,
               least(1, o.historical_diversions / 30.0) AS s_hist
          FROM o
    ), fin AS (
        SELECT sc.*, round(0.30*s_fuel + 0.30*s_crew + 0.15*s_rec + 0.10*s_stand + 0.15*s_hist, 3) AS total
          FROM sc
    )
    SELECT (row_number() OVER (ORDER BY jsonb_array_length(fin.blocking) = 0 DESC, fin.total DESC))::int,
           fin.alt_iata, fin.alt_name, jsonb_array_length(fin.blocking) = 0, fin.total,
           fin.op_status, fin.lvp_in_force, fin.weather_above_minima, fin.stands, fin.fuel_ok, fin.handling_ok,
           fin.dist, fin.fl_min, fin.arr_utc, fin.fuel_margin, fin.ret_blk, fin.ret_basis, fin.ready, fin.earliest_dep,
           fin.latest_legal, fin.latest_disc, fin.crew_margin, fin.outcome, fin.road_positioning_min,
           fin.historical_diversions, fin.hist_median_ground_min, fin.blocking,
           array_remove(ARRAY[
               CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                    THEN format('Pre-departure assessment: times anchored at projected arrival %s', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"')) END,
               CASE WHEN fin.fuel_margin IS NOT NULL
                    THEN format('Fuel margin on arrival %s min above final reserve (leg %s min P50 / %s min P90, %s)',
                                fin.fuel_margin, fin.fl_min, fin.fl90, fin.fl_basis) END,
               CASE WHEN fin.fuel_margin IS NOT NULL AND fin.fuel_margin >= 0
                    THEN format('Leave the hold by %s UTC at the latest for this alternate', to_char((i.now_utc + make_interval(mins => fin.fuel_margin)) AT TIME ZONE 'UTC', 'HH24:MI')) END,
               CASE fin.outcome
                    WHEN 'CREW_CAN_RETURN' THEN format('Crew can fly %s-%s legally (%s min spare)', fin.alt_iata, i.hub_iata, fin.crew_margin)
                    WHEN 'NEEDS_COMMANDER_DISCRETION' THEN 'Return needs commander discretion'
                    WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN format('Replacement crew needed: %s min by road from %s', fin.road_positioning_min, i.hub_iata)
                    WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN 'Replacement crew needed: deadhead flight'
                    ELSE 'Crew legality unverified' END,
               CASE WHEN fin.stands IS NOT NULL THEN format('%s stand(s) left', fin.stands) END,
               format('%s-%s block %s min (%s)', fin.alt_iata, i.hub_iata, fin.ret_blk, fin.ret_basis),
               format('Back at %s about %s UTC (ground %s min + block %s min)', i.hub_iata,
                      to_char((fin.earliest_dep + make_interval(mins => fin.ret_med)) AT TIME ZONE 'UTC', 'HH24:MI'),
                      fin.min_ground_time_min, fin.ret_med),
               CASE WHEN fin.historical_diversions > 0 THEN format('Used for %s SHJ diversions in 2026', fin.historical_diversions) END],
               NULL),
           jsonb_build_object('fuel', round(fin.s_fuel,3), 'crew', round(fin.s_crew,3), 'recovery', round(fin.s_rec,3),
                              'stands', round(fin.s_stand,3), 'history', round(fin.s_hist,3),
                              'weights', '{"fuel":0.30,"crew":0.30,"recovery":0.15,"stands":0.10,"history":0.15}'::jsonb),
           fin.fl90, fin.fl_basis, v_reserve, fin.fuel_basis,
           CASE WHEN fin.fuel_margin IS NULL THEN NULL ELSE i.now_utc + make_interval(mins => fin.fuel_margin) END,
           fin.earliest_dep + make_interval(mins => fin.ret_med)
      FROM fin
     ORDER BY 1;
END $function$;

CREATE OR REPLACE VIEW v_crew_legality_ranking AS
SELECT fc.scenario_id, fc.crew_id, cm.full_name, fc.position_code, fc.duty_id,
       EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = fc.crew_id AND q.qual_code = 'LVP') AS lvp_qualified,
       (SELECT string_agg(fl.flight_no || ' ' || fl.dep_iata || '-' || fl.arr_iata, ' / ' ORDER BY l.leg_seq)
          FROM crew_duty_leg l JOIN flight fl ON fl.flight_id = l.flight_id
         WHERE l.scenario_id = fc.scenario_id AND l.duty_id = fc.duty_id AND l.is_active) AS duty_legs,
       fc.sign_in_utc, fc.band_tz, fc.sign_in_local_time, fc.legs_counted,
       fc.max_fdp_min, fmt_min(fc.max_fdp_min) AS max_fdp_hhmm,
       fc.legal_end_utc, fc.legal_end_utc AT TIME ZONE 'Asia/Dubai' AS legal_end_shj_local,
       fc.discretion_end_utc, fc.projected_end_utc,
       fc.margin_min, fmt_min(fc.margin_min) AS margin_hhmm,
       floor(extract(epoch FROM fc.legal_end_utc - scenario_now(fc.scenario_id))/60)::int AS minutes_until_legal_end,
       fc.status, fc.reasons, fc.inputs->>'rule_set' AS rule_set, fc.inputs->>'source_rule_id' AS rule_ref,
       fc.inputs->>'band' AS band, fc.calculated_at,
       -- TB-3: before sign-in the crew is not "using" time; show "duty starts HH:MMZ", not a countdown
       (fc.sign_in_utc <= scenario_now(fc.scenario_id)) AS duty_started
  FROM fdp_calculation fc JOIN crew_member cm ON cm.crew_id = fc.crew_id
 WHERE fc.is_current AND fc.crew_id IS NOT NULL
   AND coalesce(fc.inputs->>'projected_end_basis', '') <> 'ACTUAL';     -- duty still running

-- ---------------------------------------------------------------------
-- Q2: Where is aircraft X and what is it waiting for?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_aircraft_whereabouts AS
WITH fs AS (
    SELECT s.scenario_id, coalesce(s.registration, f.registration_planned) AS registration,
           f.flight_id, f.flight_no, f.dep_iata, f.arr_iata, s.actual_arr_iata, s.status,
           f.std_utc, s.etd_utc, s.eta_utc, s.atd_utc, s.ata_utc, s.is_holding,
           coalesce(s.atd_utc, s.etd_utc, f.std_utc) AS order_ts, s.last_received_at
      FROM flight_state s JOIN flight f ON f.flight_id = s.flight_id
     WHERE coalesce(s.registration, f.registration_planned) IS NOT NULL
       AND s.status <> 'CANCELLED'
), cur AS (
    -- in progress, otherwise the last completed flight
    SELECT DISTINCT ON (scenario_id, registration) *
      FROM fs
     WHERE status IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING','LANDED','ON_BLOCKS')
       AND order_ts <= scenario_now(scenario_id)
     ORDER BY scenario_id, registration, order_ts DESC
)
SELECT c.scenario_id, c.registration,
       CASE WHEN c.status IN ('AIRBORNE','HOLDING','DIVERTING')
                 THEN format('In the air on %s %s-%s%s', c.flight_no, c.dep_iata, coalesce(c.actual_arr_iata, c.arr_iata),
                             CASE WHEN c.status = 'HOLDING' THEN ' (holding)'
                                  WHEN c.status = 'DIVERTING' THEN ' (diverting)' ELSE '' END)
            WHEN c.status = 'TAXI_OUT' THEN format('Taxiing at %s for %s', c.dep_iata, c.flight_no)
            ELSE format('On ground at %s', coalesce(c.actual_arr_iata, c.arr_iata)) END AS position_text,
       CASE WHEN c.status IN ('ON_BLOCKS','LANDED') THEN coalesce(c.actual_arr_iata, c.arr_iata) END AS on_ground_at,
       c.flight_no AS current_or_last_flight, c.status AS last_status, c.eta_utc,
       floor(extract(epoch FROM scenario_now(c.scenario_id) - c.last_received_at)/60)::int AS data_age_min,
       (c.status IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING')
        AND scenario_now(c.scenario_id) > coalesce(c.eta_utc, c.order_ts) + interval '30 minutes') AS position_unverified,
       dv.diversion_id, dv.alternate_iata AS diverted_at, dv.recovery_flight_id,
       CASE WHEN dv.diversion_id IS NOT NULL AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED')
                 THEN dv.waiting_for
            WHEN c.status = 'HOLDING' THEN 'HUB_REOPENING'
            WHEN c.status IN ('AIRBORNE','DIVERTING') THEN 'LANDING'
            WHEN nx.flight_id IS NOT NULL AND coalesce(nx.etd_utc, nx.std_utc) > nx.std_utc THEN 'DELAYED_DEPARTURE'
            WHEN nx.flight_id IS NOT NULL THEN 'NEXT_DEPARTURE'
            ELSE 'NOTHING' END AS waiting_for,
       nx.flight_no AS next_flight, nx.dep_iata AS next_dep, nx.arr_iata AS next_arr,
       coalesce(nx.etd_utc, nx.std_utc) AS next_departure_utc,
       ld.latest_legal_offblocks_utc AS next_latest_legal_departure_utc,
       ld.operational_target_utc AS next_operational_target_utc
  FROM cur c
  LEFT JOIN diversion dv ON dv.scenario_id = c.scenario_id AND dv.original_flight_id = c.flight_id
  LEFT JOIN LATERAL (
        SELECT f2.flight_id, f2.flight_no, f2.dep_iata, f2.arr_iata, f2.std_utc, s2.etd_utc
          FROM flight f2 JOIN flight_state s2 ON s2.flight_id = f2.flight_id AND s2.scenario_id = c.scenario_id
         WHERE coalesce(s2.registration, f2.registration_planned) = c.registration
           AND s2.status = 'SCHEDULED' AND f2.std_utc >= c.std_utc AND f2.flight_id <> c.flight_id
         ORDER BY coalesce(s2.etd_utc, f2.std_utc) LIMIT 1) nx ON TRUE
  LEFT JOIN latest_departure_calc ld ON ld.scenario_id = c.scenario_id AND ld.is_current
       AND ld.flight_id = nx.flight_id;

CREATE OR REPLACE FUNCTION downstream_impact(p_scenario_id INT, p_flight_id BIGINT,
                                             p_ready_at_hub_utc TIMESTAMPTZ DEFAULT NULL,
                                             p_horizon_hours INT DEFAULT 24)
RETURNS TABLE (kind TEXT, seq INT, ref TEXT, route TEXT, planned_utc TIMESTAMPTZ, projected_utc TIMESTAMPTZ,
               delay_min INT, connecting_pax INT, impact TEXT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    f flight%ROWTYPE; s flight_state%ROWTYPE; v_reg TEXT; v_ready TIMESTAMPTZ; v_hub CHAR(3);
    nx RECORD; v_dep TIMESTAMPTZ; v_blk INT; v_gt INT; i INT := 0; v_rest INT; c RECORD; v_end TIMESTAMPTZ;
BEGIN
    SELECT * INTO f FROM flight WHERE flight_id = p_flight_id;
    SELECT * INTO s FROM flight_state WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id;
    v_reg := coalesce(s.registration, f.registration_planned);
    v_hub := f.arr_iata;
    SELECT min_ground_time_min INTO v_gt FROM airport WHERE iata = v_hub;
    -- aircraft ready at the hub: caller's what-if time, else projected on-blocks + turnaround
    v_ready := coalesce(p_ready_at_hub_utc, coalesce(s.ata_utc, s.eta_utc, f.sta_utc) + make_interval(mins => coalesce(v_gt, 40)));

    FOR nx IN SELECT f2.*, s2.etd_utc
                FROM flight f2 LEFT JOIN flight_state s2 ON s2.flight_id = f2.flight_id AND s2.scenario_id = p_scenario_id
               WHERE coalesce(s2.registration, f2.registration_planned) = v_reg
                 AND f2.std_utc > f.std_utc AND f2.std_utc < f.sta_utc + make_interval(hours => p_horizon_hours)
                 AND coalesce(s2.status::text, 'SCHEDULED') = 'SCHEDULED' AND f2.flight_id <> p_flight_id
               ORDER BY f2.std_utc
    LOOP
        i := i + 1;
        v_blk := ceil(extract(epoch FROM nx.sta_utc - nx.std_utc) / 60);
        v_dep := greatest(coalesce(nx.etd_utc, nx.std_utc), v_ready);
        kind := 'AIRCRAFT'; seq := i; ref := nx.flight_no; route := nx.dep_iata || '-' || nx.arr_iata;
        planned_utc := nx.std_utc; projected_utc := v_dep;
        delay_min := greatest(0, floor(extract(epoch FROM v_dep - nx.std_utc) / 60))::int;
        connecting_pax := coalesce((SELECT sum(pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = nx.flight_id), 0)::int;
        impact := CASE WHEN delay_min = 0 THEN 'On time (aircraft ready ' || to_char(v_ready AT TIME ZONE 'UTC','HH24:MI"Z"') || ')'
                       ELSE format('Delayed %s min: aircraft %s not back until %s', delay_min, v_reg,
                                   to_char(v_ready AT TIME ZONE 'UTC','DD HH24:MI"Z"')) END;
        RETURN NEXT;
        SELECT min_ground_time_min INTO v_gt FROM airport WHERE iata = nx.arr_iata;
        v_ready := v_dep + make_interval(mins => v_blk + coalesce(v_gt, 40));
    END LOOP;

    -- crew: next planned duty after this one, and whether minimum rest still fits
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720) INTO v_rest
      FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    FOR c IN
        SELECT DISTINCT ON (ca.crew_id) ca.crew_id, ca.position_code, fc.projected_end_utc,
               re.block_name, re.duty_type, re.start_utc
          FROM crew_duty_leg l
          JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id AND ca.valid_to IS NULL
          JOIN crew_type ct ON ct.code = ca.position_code AND ct.gates_flight_legality
          LEFT JOIN fdp_calculation fc ON fc.scenario_id = l.scenario_id AND fc.duty_id = l.duty_id
                                      AND fc.crew_id = ca.crew_id AND fc.is_current
          LEFT JOIN LATERAL (SELECT * FROM roster_entry re
                              WHERE re.crew_id = ca.crew_id AND re.duty_type IN ('FLIGHT','DUTY','TRAINING','SIM','EVENT')
                                AND re.start_utc > coalesce(fc.projected_end_utc, f.sta_utc)
                              ORDER BY re.start_utc LIMIT 1) re ON TRUE
         WHERE l.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active
         ORDER BY ca.crew_id
    LOOP
        v_end := greatest(coalesce(c.projected_end_utc, f.sta_utc), coalesce(p_ready_at_hub_utc - make_interval(mins => coalesce(v_gt,40)), c.projected_end_utc));
        kind := 'CREW'; seq := NULL; ref := c.position_code || ' ' || c.crew_id;
        route := coalesce(c.block_name, '—'); planned_utc := c.start_utc; projected_utc := v_end;
        delay_min := NULL; connecting_pax := NULL;
        impact := CASE WHEN c.start_utc IS NULL THEN 'No further duty in the roster window'
                       WHEN c.start_utc - v_end < make_interval(mins => v_rest)
                       THEN format('Rest conflict: only %s h before next duty (%s), minimum %s h',
                                   round(extract(epoch FROM c.start_utc - v_end)/3600.0, 1), c.duty_type, v_rest/60)
                       ELSE format('OK: %s h rest before next duty (%s)', round(extract(epoch FROM c.start_utc - v_end)/3600.0, 1), c.duty_type) END;
        RETURN NEXT;
    END LOOP;
END $$;

-- re-compute open suggestions under the new time base (same loop as 010)
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT DISTINCT rc.scenario_id, rc.case_id, rc.flight_id
               FROM recommendation rc JOIN disruption_case dc ON dc.case_id = rc.case_id
              WHERE rc.status = 'PROPOSED' AND dc.phase <> 'CLOSED' LOOP
        BEGIN
            PERFORM recommend_for_flight(r.scenario_id, r.case_id, r.flight_id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'could not refresh flight %: %', r.flight_id, SQLERRM;
        END;
    END LOOP;
END $$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
