-- 025: hold-vs-divert on ONE scale: expected delay-equivalent minutes (lowest wins).
-- Replaces the 015 rule "a hold with >= 15 min fuel spare beats every diversion" (hold scored 1.0-2.0, divert 0-1.0).
--   * the reopening time is a distribution (P50 + spread by quality), not one point
--   * a hold keeps its way out: the latest time the aircraft can still start diverting (bingo of the best executable alternate)
--     is the decision-by time; P(fog outlasts it) x cost of a late divert is charged to the hold
--   * if no alternate is executable the hold carries the no-fallback cost for the chance that fog outlasts the fuel
--   * every option also pays connecting pax (missed + half of tight), crew outcome, and a divert its fixed out-of-position cost
--   * station slots (WP-4 capacity module, 003): every alternate is checked with airport_capacity_assess() at its estimated arrival.
--     Stands or arrival slots EXCEEDED (a figure from a status entry or a configured assumption) blocks the alternate; CONSTRAINED costs minutes;
--     UNKNOWN is shown as "needs verification" and never blocks or counts as free. History-only figures are a lower bound, so they only ever constrain.
--     The hub's own landing slot after reopening adds queue delay to the hold when a known arrival rate is lower than the traffic scheduled in that hour.
-- rank_alternates() and its hard constraints are untouched; its blocking and "verify" codes still make an option non-executable.
-- All constants are in divert_policy, labelled ASSUMED until calibrated (no hold-duration or forecast-vs-actual data exists).
SET search_path = fogops, hist, public;

INSERT INTO divert_policy (key, value, unit, basis) VALUES
 ('reopen_spread_wide_frac',   0.50, 'fraction of time-to-reopen', 'ASSUMED: P90 reopening = P50 + max(min, frac x time to P50) when the reopening is a forecast/manual/simulated value'),
 ('reopen_spread_wide_min',    30,   'min', 'ASSUMED: minimum P90 spread for a forecast reopening'),
 ('reopen_spread_narrow_frac', 0.15, 'fraction of time-to-reopen', 'ASSUMED: same, when the reopening is MEASURED'),
 ('reopen_spread_narrow_min',  10,   'min', 'ASSUMED: minimum P90 spread for a measured reopening'),
 ('cost_divert_fixed_min',     60,   'delay-min', 'ASSUMED: aircraft out of position, handling, passenger care, extra sector'),
 ('cost_pax_missed_min',       2,    'delay-min per pax', 'ASSUMED: one missed connecting passenger (a tight one counts half)'),
 ('cost_crew_discretion_min',  30,   'delay-min', 'ASSUMED: option needs commander discretion'),
 ('cost_crew_road_extra_min',  60,   'delay-min', 'ASSUMED: crew replaced by road (on top of the road minutes)'),
 ('cost_crew_deadhead_min',    180,  'delay-min', 'ASSUMED: crew replaced by deadhead'),
 ('cost_crew_verify_min',      60,   'delay-min', 'ASSUMED: crew legality unverified'),
 ('cost_stand_tight_min',      30,   'delay-min', 'ASSUMED: alternate has at most 1 free stand'),
 ('cost_no_fallback_min',      600,  'delay-min', 'ASSUMED: hold runs out of fuel with no alternate reachable'),
 ('cost_capacity_constrained_min', 30, 'delay-min', 'ASSUMED: alternate is at its stand or arrival-slot limit (at most 1 left) or a history-only figure is exceeded'),
 ('slot_queue_share',          0.5,  'fraction', 'ASSUMED: hub landing queue delay = share x backlog hours (scheduled arrivals in the hour above the known arrival rate)'),
 ('slot_delay_max_min',        180,  'min', 'ASSUMED: cap on the hub slot queue delay added to a hold'),
 ('cost_thin_margin_min',      30,   'delay-min', 'ASSUMED: hold lands with less fuel spare than the hold buffer (p_min_hold_spare_min, 15 min): little room for a changed forecast')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION norm_cdf(x double precision) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
  -- Abramowitz-Stegun 7.1.26 erf approximation, absolute error < 1.5e-7
  SELECT 0.5 * (1 + sign(x) * (1 - (((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t) * exp(-z * z)))
    FROM (SELECT abs(x) / sqrt(2.0) AS z, 1.0 / (1.0 + 0.3275911 * abs(x) / sqrt(2.0)) AS t) s
$$;

CREATE OR REPLACE FUNCTION propose_hold_or_divert(p_scenario_id integer, p_case_id integer, p_flight_id bigint, p_generated_by text DEFAULT 'rules-engine v3'::text, p_approach_min integer DEFAULT 10, p_min_hold_spare_min integer DEFAULT 15)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'fogops', 'public'
AS $function$
DECLARE
    i RECORD; v_rec BIGINT; v_hold_block JSONB := '[]'; v_hold_ok BOOLEAN;
    v_land TIMESTAMPTZ; v_spare INT; v_hold_crew INT; v_best RECORD; v_conf NUMERIC; v_type rec_type;
    v_rationale TEXT; v_hold_reasons TEXT[] := '{}'; v_ci RECORD; v_ext INT; v_hist_used BOOLEAN := FALSE;
    v_alts JSONB; v_hubcap RECORD; v_hub JSONB; v_slot_delay INT := 0; v_slot_thin BOOLEAN := FALSE; v_slot_note TEXT; v_over NUMERIC;
    pol  CONSTANT JSONB := (SELECT jsonb_object_agg(key, value) FROM divert_policy);
    -- reopening distribution
    v_ttc NUMERIC; v_wide BOOLEAN; v_spread NUMERIC; v_sigma NUMERIC; v_p90 TIMESTAMPTZ;
    -- fallback and costs
    v_db TIMESTAMPTZ; v_db_alt CHAR(3); v_best_div NUMERIC; v_p_late NUMERIC; v_late_cost NUMERIC;
    v_wait NUMERIC; v_hold_cost NUMERIC; v_hold_pax NUMERIC; v_hold_crew_cost NUMERIC; v_hold_score NUMERIC := 0;
    f_fixed  NUMERIC := coalesce((pol->>'cost_divert_fixed_min')::numeric, 60);
    f_pax    NUMERIC := coalesce((pol->>'cost_pax_missed_min')::numeric, 2);
    f_disc   NUMERIC := coalesce((pol->>'cost_crew_discretion_min')::numeric, 30);
    f_road   NUMERIC := coalesce((pol->>'cost_crew_road_extra_min')::numeric, 60);
    f_dead   NUMERIC := coalesce((pol->>'cost_crew_deadhead_min')::numeric, 180);
    f_verify NUMERIC := coalesce((pol->>'cost_crew_verify_min')::numeric, 60);
    f_stand  NUMERIC := coalesce((pol->>'cost_stand_tight_min')::numeric, 30);
    f_nofb   NUMERIC := coalesce((pol->>'cost_no_fallback_min')::numeric, 600);
    f_capc   NUMERIC := coalesce((pol->>'cost_capacity_constrained_min')::numeric, 30);
    f_thin   NUMERIC := coalesce((pol->>'cost_thin_margin_min')::numeric, 30);
BEGIN
    SELECT * INTO i FROM flight_decision_inputs(p_scenario_id, p_flight_id);

    -- candidate diversions, computed once (jsonb so they can be re-read several times)
    SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_alts FROM rank_alternates(p_scenario_id, p_flight_id) r;

    -- HOLD: land at the P50 reopening + approach; P90 reopening gives the spread
    v_land := CASE WHEN i.reopen_utc IS NULL THEN NULL
                   ELSE greatest(i.reopen_utc, i.anchor_utc) + make_interval(mins => p_approach_min) END;
    -- the hub's own landing slot after reopening: a KNOWN arrival rate (status entry or configured) lower than the traffic scheduled
    -- in that hour makes aircraft queue; a history-only rate is a lower bound, so it only adds a risk cost
    IF v_land IS NOT NULL THEN
        SELECT * INTO v_hubcap FROM airport_capacity_resolve(p_scenario_id, i.hub_iata, v_land);
        IF coalesce(v_hubcap.arrivals_per_hr, 0) > 0 THEN
            v_hub := airport_capacity_assess(p_scenario_id, i.hub_iata, v_land, 0, p_flight_id, 0, 1);
            v_over := (v_hub->'arrivals_per_hr'->>'projected_in_hour')::numeric - v_hubcap.arrivals_per_hr;
            IF v_over > 0 THEN
                IF v_hubcap.arrivals_source = 'HISTORY' THEN
                    v_slot_thin := TRUE;
                    v_slot_note := format('Landing slots at %s: %s arrivals already planned in the hour against a history peak of %s (a lower bound): extra risk added',
                                          i.hub_iata, v_hub->'arrivals_per_hr'->>'projected_in_hour', v_hubcap.arrivals_per_hr);
                ELSE
                    v_slot_delay := least(coalesce((pol->>'slot_delay_max_min')::numeric, 180),
                                          round(60 * v_over / v_hubcap.arrivals_per_hr * coalesce((pol->>'slot_queue_share')::numeric, 0.5)))::int;
                    v_land := v_land + make_interval(mins => v_slot_delay);
                    v_slot_note := format('Landing slots at %s: %s arrivals planned in the hour against %s per hour (%s): about %s min queue delay added',
                                          i.hub_iata, v_hub->'arrivals_per_hr'->>'projected_in_hour', v_hubcap.arrivals_per_hr, v_hubcap.arrivals_source, v_slot_delay);
                END IF;
            END IF;
        END IF;
    END IF;
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

    IF i.reopen_utc IS NOT NULL THEN
        v_ttc  := greatest(0, extract(epoch FROM (i.reopen_utc - i.anchor_utc))/60);
        v_wide := i.reopen_quality IS DISTINCT FROM 'MEASURED';
        v_spread := greatest(CASE WHEN v_wide THEN coalesce((pol->>'reopen_spread_wide_min')::numeric, 30) ELSE coalesce((pol->>'reopen_spread_narrow_min')::numeric, 10) END,
                             v_ttc * CASE WHEN v_wide THEN coalesce((pol->>'reopen_spread_wide_frac')::numeric, 0.5) ELSE coalesce((pol->>'reopen_spread_narrow_frac')::numeric, 0.15) END);
        v_sigma := v_spread / 1.2816;                       -- P90 = P50 + 1.2816 sigma
        v_p90 := i.reopen_utc + make_interval(mins => v_spread::int);
    END IF;

    SELECT * INTO v_ci FROM connection_impact(p_scenario_id, p_flight_id, v_land);
    v_ext := CASE WHEN v_hold_crew < 0 AND v_land <= i.disc_end_now THEN -v_hold_crew END;
    v_hold_pax := f_pax * (coalesce(v_ci.pax_missed, 0) + 0.5 * coalesce(v_ci.pax_tight, 0));
    v_hold_crew_cost := CASE WHEN NOT i.crew_known THEN f_verify WHEN v_ext IS NOT NULL THEN f_disc ELSE 0 END;

    -- divert options with their cost (minutes from now until the aircraft is back at the hub, plus penalties)
    IF to_regclass('pg_temp._pd_alt') IS NULL THEN
    CREATE TEMP TABLE _pd_alt (alt CHAR(3), cost NUMERIC, pax_cost NUMERIC, crew_cost NUMERIC, ci_pax_missed INT, ci_pax_tight INT, ci_conn INT, ci_total INT, cap_outcome TEXT, cap_block JSONB, cap_note TEXT) ON COMMIT DROP;
    END IF;
    TRUNCATE _pd_alt;
    INSERT INTO _pd_alt
    SELECT a.alt_iata,
           greatest(0, extract(epoch FROM (a.return_arrival_hub_utc - i.anchor_utc))/60) + f_fixed
             + f_pax * (coalesce(ci.pax_missed,0) + 0.5 * coalesce(ci.pax_tight,0))
             + CASE a.crew_outcome WHEN 'CREW_CAN_RETURN' THEN 0
                                   WHEN 'NEEDS_COMMANDER_DISCRETION' THEN f_disc
                                   WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN coalesce(a.road_positioning_min, 0) + f_road
                                   WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN f_dead
                                   ELSE f_verify END
             + CASE WHEN a.stands_left IS NOT NULL AND a.stands_left <= 1 THEN f_stand ELSE 0 END
             + CASE WHEN cp->>'outcome' = 'CAPACITY_CONSTRAINED' THEN f_capc ELSE 0 END,
           f_pax * (coalesce(ci.pax_missed,0) + 0.5 * coalesce(ci.pax_tight,0)),
           CASE a.crew_outcome WHEN 'CREW_CAN_RETURN' THEN 0 WHEN 'NEEDS_COMMANDER_DISCRETION' THEN f_disc
                               WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN coalesce(a.road_positioning_min, 0) + f_road
                               WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN f_dead ELSE f_verify END,
           ci.pax_missed, ci.pax_tight, ci.connections, ci.pax_total,
           cp->>'outcome',
           CASE WHEN cp->>'outcome' = 'CAPACITY_EXCEEDED' THEN jsonb_build_object(
                'code', CASE WHEN cp->>'stands_outcome' = 'EXCEEDED' THEN 'NO_STAND_CAPACITY' ELSE 'NO_ARRIVAL_SLOT' END,
                'detail', cp->'reasons'->>CASE WHEN cp->>'stands_outcome' = 'EXCEEDED' THEN 0 ELSE 1 END) END,
           format('Station capacity at %s (%s UTC): %s. %s', a.alt_iata, to_char(coalesce(a.est_arrival_utc, i.now_utc) AT TIME ZONE 'UTC','HH24:MI'),
                  CASE cp->>'outcome' WHEN 'CAPACITY_AVAILABLE' THEN 'stands and arrival slots available'
                                      WHEN 'CAPACITY_CONSTRAINED' THEN 'at the limit (at most 1 stand or slot left)'
                                      WHEN 'CAPACITY_EXCEEDED' THEN 'NO stand or arrival slot left'
                                      ELSE 'stands or arrival slots UNKNOWN: needs verification with the station' END,
                  coalesce(cp->'reasons'->>1, ''))
      FROM jsonb_to_recordset(v_alts) AS a(alt_iata char(3), est_arrival_utc timestamptz, return_arrival_hub_utc timestamptz, crew_outcome text, road_positioning_min int, stands_left int)
      CROSS JOIN LATERAL connection_impact(p_scenario_id, p_flight_id, a.return_arrival_hub_utc) ci
      CROSS JOIN LATERAL airport_capacity_assess(p_scenario_id, a.alt_iata, coalesce(a.est_arrival_utc, i.now_utc), 0, p_flight_id, 0, 1) cp;

    -- fallback of the hold: the executable alternate with the lowest cost; the aircraft can wait until its bingo time
    SELECT (a->>'bingo_utc')::timestamptz, (a->>'alt_iata')::char(3), d.cost INTO v_db, v_db_alt, v_best_div
      FROM jsonb_array_elements(v_alts) a JOIN _pd_alt d ON d.alt = (a->>'alt_iata')::char(3)
     WHERE (a->>'is_executable')::boolean AND d.cap_block IS NULL AND (a->>'bingo_utc') IS NOT NULL AND (a->>'bingo_utc')::timestamptz > i.anchor_utc
     ORDER BY d.cost LIMIT 1;

    IF v_sigma IS NOT NULL AND v_sigma > 0 THEN
        IF v_db IS NOT NULL THEN
            v_p_late := 1 - norm_cdf((extract(epoch FROM (v_db - i.reopen_utc))/60) / v_sigma);
            v_late_cost := extract(epoch FROM (v_db - i.anchor_utc))/60 + v_best_div;
        ELSE
            v_p_late := CASE WHEN i.endurance_until IS NULL THEN 1
                             ELSE 1 - norm_cdf((extract(epoch FROM (i.endurance_until - make_interval(mins => p_approach_min) - i.reopen_utc))/60) / v_sigma) END;
            v_late_cost := f_nofb;
        END IF;
    ELSIF i.reopen_utc IS NOT NULL THEN
        v_p_late := 0; v_late_cost := 0;
    END IF;

    IF v_hold_ok THEN
        v_wait := extract(epoch FROM (v_land - i.anchor_utc))/60;
        v_hold_cost := (1 - v_p_late) * (v_wait + v_hold_pax + v_hold_crew_cost) + v_p_late * v_late_cost
                       + CASE WHEN v_spare < p_min_hold_spare_min THEN f_thin ELSE 0 END
                       + CASE WHEN v_slot_thin THEN f_capc ELSE 0 END;
        v_hold_score := round(100.0 / (1 + v_hold_cost / 60.0), 3);
    END IF;

    v_hold_reasons := array_remove(ARRAY[
        CASE WHEN v_land IS NOT NULL THEN format('Landing at %s after forecast reopening (%s)', to_char(v_land AT TIME ZONE 'UTC','HH24:MI"Z"'), i.reopen_quality) END,
        CASE WHEN v_p90 IS NOT NULL THEN format('Reopening P90 %s: %s%% chance fog lasts past %s', to_char(v_p90 AT TIME ZONE 'UTC','HH24:MI"Z"'),
                 round(100 * v_p_late)::int, CASE WHEN v_db IS NOT NULL THEN to_char(v_db AT TIME ZONE 'UTC','HH24:MI"Z"') || ' (last moment to divert to ' || v_db_alt || ')'
                                                  ELSE 'the fuel limit (no alternate reachable)' END) END,
        CASE WHEN v_spare IS NOT NULL THEN format('Fuel spare at landing %s min (%s)', v_spare, i.fuel_quality) END,
        CASE WHEN v_hold_crew IS NOT NULL THEN format('Crew margin at landing %s min', v_hold_crew) END,
        CASE WHEN v_ext IS NOT NULL THEN format('Needs commander discretion: about %s min beyond the legal duty (the captain decides)', v_ext) END,
        CASE WHEN v_ci.connections > 0 THEN format('Connections at landing: %s pax miss, %s tight (of %s connecting pax)', v_ci.pax_missed, v_ci.pax_tight, v_ci.pax_total) END,
        v_slot_note,
        CASE WHEN v_hold_ok AND v_spare < p_min_hold_spare_min THEN format('Fuel spare below the %s min hold buffer (+%s delay-min risk)', p_min_hold_spare_min, round(f_thin)) END,
        CASE WHEN v_hold_ok THEN format('Expected cost %s delay-min (wait %s, connections %s, crew %s, late-divert risk %s)', round(v_hold_cost), round(v_wait), round(v_hold_pax), round(v_hold_crew_cost), round(v_p_late * v_late_cost)) END], NULL);

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

    INSERT INTO recommendation_option (rec_id, rank, action, alternate_iata, hold_until_utc, est_arrival_utc,
                                       fuel_margin_min, crew_margin_min, score, is_executable,
                                       blocking_constraints, reasons)
    SELECT v_rec, row_number() OVER (ORDER BY x.execable DESC, x.score DESC), x.action, x.alt, x.hold_until,
           x.arr, x.fuel_m, x.crew_m, x.score, x.execable, x.blocking, x.reasons
      FROM (
        SELECT 'HOLD'::rec_type AS action, NULL::char(3) AS alt,
               coalesce(v_db, i.endurance_until, i.anchor_utc) AS hold_until,
               v_land AS arr, v_spare AS fuel_m, v_hold_crew AS crew_m, v_hold_score AS score,
               v_hold_ok AS execable, v_hold_block AS blocking, v_hold_reasons AS reasons
        UNION ALL
        SELECT 'DIVERT', a.alt_iata, NULL, a.est_arrival_utc, a.fuel_margin_min, a.crew_return_margin_min,
               round(100.0 / (1 + d.cost / 60.0), 3),
               a.is_executable AND d.cap_block IS NULL,
               CASE WHEN d.cap_block IS NULL THEN a.blocking_constraints ELSE coalesce(a.blocking_constraints, '[]'::jsonb) || d.cap_block END,
               array_remove((SELECT array_agg(t) FROM jsonb_array_elements_text(a.reasons) t) || ARRAY[
                   d.cap_note,
                   format('Expected cost %s delay-min (return to %s %s min from now incl. %s fixed, connections %s, crew %s)', round(d.cost), i.hub_iata,
                          round(extract(epoch FROM (a.return_arrival_hub_utc - i.anchor_utc))/60), round(f_fixed), round(d.pax_cost), round(d.crew_cost)),
                   CASE WHEN d.ci_conn > 0 THEN format('Connections on return to %s: %s pax miss, %s tight (of %s connecting pax)', i.hub_iata, d.ci_pax_missed, d.ci_pax_tight, d.ci_total) END], NULL)
          FROM jsonb_to_recordset(v_alts) AS a(alt_iata char(3), est_arrival_utc timestamptz, fuel_margin_min int, crew_return_margin_min int,
                                               is_executable boolean, blocking_constraints jsonb, reasons jsonb, return_arrival_hub_utc timestamptz)
          JOIN _pd_alt d ON d.alt = a.alt_iata
      ) x;

    SELECT * INTO v_best FROM recommendation_option WHERE rec_id = v_rec AND rank = 1;
    v_hist_used := v_best.action = 'DIVERT' AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_alts) a
                                                         WHERE a->>'alt_iata' = v_best.alternate_iata AND a->>'op_status' = 'OPEN (history)');
    v_type := CASE WHEN v_best.is_executable THEN v_best.action ELSE 'MONITOR' END;
    v_rationale := CASE
        WHEN NOT v_best.is_executable THEN
            'No option has all operational inputs confirmed: manual verification required before holding or diverting.'
        WHEN v_type = 'HOLD' THEN
            format('HOLD: lowest expected cost (%s delay-min). Fuel and crew cover the forecast reopening (%s). %s', round(v_hold_cost),
                   to_char(i.reopen_utc AT TIME ZONE 'UTC','HH24:MI"Z"'), array_to_string(v_best.reasons, '; '))
        ELSE format('DIVERT %s: lowest expected cost. %s. %s', v_best.alternate_iata,
                    CASE WHEN v_hold_ok THEN format('Hold would cost about %s delay-min (%s%% chance fog outlasts the fuel/diversion limit)', round(v_hold_cost), round(100 * v_p_late))
                         ELSE 'Hold not feasible: ' || (SELECT string_agg(x->>'code', ', ') FROM jsonb_array_elements(v_hold_block) x) END,
                    array_to_string(v_best.reasons, '; ')) END;

    UPDATE recommendation SET rec_type = v_type, rationale = v_rationale,
        confidence = greatest(0.3, confidence - CASE WHEN v_hist_used THEN 0.10 ELSE 0 END
                                              - CASE WHEN v_type = 'HOLD' AND v_p_late > 0.25 THEN 0.10 ELSE 0 END),
        assumptions = jsonb_build_array(
            format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
            format('Hub reopening quality: %s', coalesce(i.reopen_quality, 'none')),
            'Options compared on expected delay-equivalent minutes; the cost constants in divert_policy (cost_*) are ASSUMED, not calibrated',
            'Reopening is modelled as a normal distribution around the stated time, P90 spread from reopen_spread_* (ASSUMED)',
            'Distance to alternates measured from the hub (aircraft assumed in the hub terminal area)',
            'Diversion counts as one extra sector for every operating crew member',
            CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                 THEN format('Flight not yet departed: pre-departure assessment, all times anchored at projected arrival %s (not at the current clock)',
                             to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'))
                 ELSE format('Decision moment %s (%s)', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'), lower(i.flight_phase)) END,
            CASE WHEN v_hist_used THEN 'Alternate availability and stands come from the supplied flight history (no live status); a station entry overrides them'
                 ELSE 'Alternate status/parking taken from the latest airport_status_event, else from the supplied history' END),
        uncertainty = jsonb_build_object('reopening_utc', i.reopen_utc, 'reopening_p90_utc', v_p90, 'reopening_quality', i.reopen_quality,
                                         'endurance_left_min', i.endurance_left_min, 'p_fog_outlasts_decision_by', round(v_p_late, 3),
                                         'decision_by_utc', v_db, 'fallback_alternate', v_db_alt,
                                         'hold_cost_min', round(v_hold_cost), 'cost_unit', 'delay-equivalent minutes (ASSUMED weights)')
     WHERE rec_id = v_rec;
    RETURN v_rec;
END $function$;

-- a changed configured capacity (stands or arrivals per hour) re-ranks every open case: queue one reassessment per scenario with an open case
CREATE OR REPLACE FUNCTION trg_reassess_capacity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE s RECORD;
BEGIN
    FOR s IN SELECT DISTINCT scenario_id, hub_iata FROM disruption_case WHERE phase <> 'CLOSED' LOOP
        PERFORM enqueue_reassessment(s.scenario_id, 'CAPACITY_CHANGE', 'airport', s.hub_iata, jsonb_build_object('op', TG_OP));
    END LOOP;
    RETURN NULL;
END $$;
ALTER FUNCTION trg_reassess_capacity() SET search_path = fogops, public;
DROP TRIGGER IF EXISTS reassess_capacity ON airport_capacity;
CREATE TRIGGER reassess_capacity AFTER INSERT OR UPDATE OR DELETE ON airport_capacity
    FOR EACH STATEMENT EXECUTE FUNCTION trg_reassess_capacity();
