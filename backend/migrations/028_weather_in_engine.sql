-- 028: the fitted fog model and live/archived METAR enter the hold-vs-divert engine (replaces propose_hold_or_divert of 025).
--   * Reopening: a person's time stays the median. The model supplies the spread (P90 = median x model ratio, 1.2-4x). With no entered time and a fresh
--     fog observation, the model's median is used and labelled ESTIMATED_MODEL (confidence -0.15). Otherwise the assumed spread of 025 applies.
--   * Alternates: a fresh METAR below the minima blocks the alternate (WEATHER_BELOW_MINIMA_METAR, even if an older entry says OK: safety first);
--     a fresh METAR above minima replaces a MISSING weather entry (WEATHER_UNCONFIRMED) but every other unconfirmed item still blocks;
--     expected cost of fog at arrival (alt_fog_risk x cost_alt_fog_second_divert_min) is added to the divert.
--   * Weather never changes airport status and never decides; stale or missing data changes nothing.
--   * Every recommendation now says WHY this option beat the next one (largest cost component, and what the cheaper-looking option has that the
--     cost does not reward) and lists what the model does NOT account for (recommendation.rationale, uncertainty.why / uncertainty.not_accounted_for).
--   * Per-scenario switch scenario.use_external_weather (migration 026): ON = stored real METAR at the scenario clock (LIVE default); OFF = only what the
--     user enters (REPLAY / what-if default): the fog model then runs on the visibility and time of the user's own status entries and a real METAR can
--     neither block nor fill in an alternate. A person's entries win in both modes; alt_fog_risk is a historical prior and applies in both.
SET search_path = fogops, hist, public;
INSERT INTO divert_policy (key, value, unit, basis) VALUES
 ('cost_alt_fog_second_divert_min', 120, 'delay-min', 'ASSUMED: cost of finding the alternate in fog on arrival (second diversion), times the fitted chance of that')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION propose_hold_or_divert(p_scenario_id integer, p_case_id integer, p_flight_id bigint, p_generated_by text DEFAULT 'rules-engine v3'::text, p_approach_min integer DEFAULT 10, p_min_hold_spare_min integer DEFAULT 15)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'fogops', 'public'
AS $function$
DECLARE
    i RECORD; v_rec BIGINT; v_hold_block JSONB := '[]'; v_hold_ok BOOLEAN;
    v_land TIMESTAMPTZ; v_spare INT; v_hold_crew INT; v_best RECORD; v_conf NUMERIC; v_type rec_type;
    v_rationale TEXT; v_hold_reasons TEXT[] := '{}'; v_ci RECORD; v_ext INT; v_hist_used BOOLEAN := FALSE;
    v_why TEXT; v_unc JSONB; v_unc_short TEXT; v_win RECORD; v_run RECORD; v_data_age NUMERIC; v_key TEXT; v_gap NUMERIC;
    v_use_wx BOOLEAN; v_wx_mode TEXT; v_reopen TIMESTAMPTZ; v_rq TEXT; v_fz RECORD; v_hub_icao CHAR(4); v_model_note TEXT; v_wx_conf NUMERIC := 0; v_r90 NUMERIC; v_hub_fog BOOLEAN;
    f_altfog NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'cost_alt_fog_second_divert_min'), 120);
    v_wx_max_age NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'weather_max_age_min'), 90);
    v_minima NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'alt_minima_vis_m'), 800);
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

    -- weather (EXTERNAL data, migrations 026/027): a person's reopening time always wins; the fitted fog model supplies the spread, or the
    -- reopening itself (ESTIMATED_MODEL) when none was entered. No fresh observation / not in fog / no active model = nothing used.
    v_reopen := i.reopen_utc; v_rq := i.reopen_quality;
    SELECT icao INTO v_hub_icao FROM airport WHERE iata = i.hub_iata;
    SELECT coalesce(use_external_weather, FALSE) INTO v_use_wx FROM scenario WHERE scenario_id = p_scenario_id;
    IF v_use_wx THEN
        SELECT * INTO v_fz FROM fog_clear_forecast(v_hub_icao, i.now_utc);
        v_wx_mode := 'real weather (stored METAR at the scenario clock)';
    ELSE
        SELECT * INTO v_fz FROM fog_clear_forecast_entered(p_scenario_id, i.hub_iata, i.now_utc);
        v_wx_mode := 'your entries only (real weather switched off for this scenario)';
    END IF;
    -- a closed or restricted hub is treated as fog for the alternate risk (the person's status wins over a clear METAR; conservative when the cause is not fog)
    v_hub_fog := coalesce(v_fz.in_fog, FALSE) OR i.hub_status IS DISTINCT FROM 'OPEN';
    IF v_fz.p50_min IS NOT NULL AND v_fz.p50_min > 0 THEN
        IF i.reopen_utc IS NULL THEN
            v_reopen := i.now_utc + make_interval(mins => round(v_fz.p50_min)::int);
            v_rq := 'ESTIMATED_MODEL'; v_wx_conf := 0.15;
            v_model_note := format('No reopening time entered: using the fog model on ' || CASE WHEN v_use_wx THEN 'external METAR data' ELSE 'your entered status' END || ' (visibility %s m, fog for %s min): clearing in about %s min (P10 %s, P90 %s), ESTIMATED',
                                   v_fz.vis_m, v_fz.age_min, round(v_fz.p50_min), round(v_fz.p10_min), round(v_fz.p90_min));
        ELSE
            v_r90 := least(4, greatest(1.2, v_fz.p90_min / v_fz.p50_min));
            v_model_note := format('Reopening spread from the fog model on ' || CASE WHEN v_use_wx THEN 'external METAR data' ELSE 'your entered status' END || ' (visibility %s m, fog for %s min): P90 is %sx the median, ESTIMATED',
                                   v_fz.vis_m, v_fz.age_min, round(v_r90, 2));
        END IF;
    END IF;

    -- candidate diversions, computed once (jsonb so they can be re-read several times)
    SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_alts FROM rank_alternates(p_scenario_id, p_flight_id) r;

    -- HOLD: land at the P50 reopening + approach; P90 reopening gives the spread
    v_land := CASE WHEN v_reopen IS NULL THEN NULL
                   ELSE greatest(v_reopen, i.anchor_utc) + make_interval(mins => p_approach_min) END;
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
    IF v_reopen IS NULL THEN v_hold_block := v_hold_block || jsonb_build_object('code','REOPENING_TIME_UNKNOWN','verify',true); END IF;
    IF i.endurance_left_min IS NULL THEN v_hold_block := v_hold_block || jsonb_build_object('code','FUEL_ENDURANCE_UNKNOWN','verify',true); END IF;
    IF v_spare < 0 THEN v_hold_block := v_hold_block || jsonb_build_object('code','ENDURANCE_ENDS_BEFORE_REOPENING','short_by_min',-v_spare); END IF;
    IF i.hub_lvp AND i.cockpit_all_lvp IS DISTINCT FROM TRUE THEN
        v_hold_block := v_hold_block || jsonb_build_object('code','CREW_NOT_LVP_QUALIFIED_FOR_HUB'); END IF;
    IF NOT i.crew_known THEN v_hold_block := v_hold_block || jsonb_build_object('code','CREW_LEGALITY_UNVERIFIED','verify',true);
    ELSIF v_land > i.disc_end_now THEN v_hold_block := v_hold_block || jsonb_build_object('code','CREW_EXCEEDS_FDP_EVEN_WITH_DISCRETION'); END IF;
    v_hold_ok := jsonb_array_length(v_hold_block) = 0;

    IF v_reopen IS NOT NULL THEN
        v_ttc  := greatest(0, extract(epoch FROM (v_reopen - i.anchor_utc))/60);
        v_wide := v_rq IS DISTINCT FROM 'MEASURED';
        v_spread := greatest(CASE WHEN v_wide THEN coalesce((pol->>'reopen_spread_wide_min')::numeric, 30) ELSE coalesce((pol->>'reopen_spread_narrow_min')::numeric, 10) END,
                             v_ttc * CASE WHEN v_wide THEN coalesce((pol->>'reopen_spread_wide_frac')::numeric, 0.5) ELSE coalesce((pol->>'reopen_spread_narrow_frac')::numeric, 0.15) END);
        IF v_fz.p50_min IS NOT NULL AND v_fz.p50_min > 0 THEN   -- the model's own uncertainty replaces the assumed spread
            v_spread := greatest(coalesce((pol->>'reopen_spread_narrow_min')::numeric, 10),
                                 CASE WHEN i.reopen_utc IS NULL THEN v_fz.p90_min - v_fz.p50_min ELSE v_ttc * (v_r90 - 1) END);
        END IF;
        v_sigma := v_spread / 1.2816;                       -- P90 = P50 + 1.2816 sigma
        v_p90 := v_reopen + make_interval(mins => v_spread::int);
    END IF;

    SELECT * INTO v_ci FROM connection_impact(p_scenario_id, p_flight_id, v_land);
    v_ext := CASE WHEN v_hold_crew < 0 AND v_land <= i.disc_end_now THEN -v_hold_crew END;
    v_hold_pax := f_pax * (coalesce(v_ci.pax_missed, 0) + 0.5 * coalesce(v_ci.pax_tight, 0));
    v_hold_crew_cost := CASE WHEN NOT i.crew_known THEN f_verify WHEN v_ext IS NOT NULL THEN f_disc ELSE 0 END;

    -- divert options with their cost (minutes from now until the aircraft is back at the hub, plus penalties)
    IF to_regclass('pg_temp._pd_alt') IS NULL THEN
    CREATE TEMP TABLE _pd_alt (alt CHAR(3), cost NUMERIC, pax_cost NUMERIC, crew_cost NUMERIC, ci_pax_missed INT, ci_pax_tight INT, ci_conn INT, ci_total INT,
                               cap_note TEXT, exe BOOLEAN, blocking JSONB, wx_note TEXT, fog_p NUMERIC, fog_cost NUMERIC, comp JSONB, flt_min INT, fuel_m INT) ON COMMIT DROP;
    END IF;
    TRUNCATE _pd_alt;
    INSERT INTO _pd_alt
    SELECT b.alt_iata, b.base_cost + b.fog_cost, b.pax_cost, b.crew_cost, b.pax_missed, b.pax_tight, b.connections, b.pax_total, b.cap_note,
           (b.is_executable OR b.lift) AND b.cap_block IS NULL AND b.wx_block IS NULL,
           (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM jsonb_array_elements(coalesce(b.blocking_constraints, '[]'::jsonb)) x
             WHERE NOT (b.lift AND x->>'code' = 'WEATHER_UNCONFIRMED'))
             || CASE WHEN b.cap_block IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(b.cap_block) END
             || CASE WHEN b.wx_block IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(b.wx_block) END,
           CASE WHEN b.alt_vis IS NULL AND b.fog_p IS NULL THEN NULL
                ELSE concat_ws('; ',
                     CASE WHEN b.alt_vis IS NOT NULL THEN format('Weather at %s: METAR %s UTC visibility %s m (EXTERNAL_OBSERVED)%s', b.alt_iata, to_char(b.alt_obs AT TIME ZONE 'UTC','HH24:MI'), b.alt_vis,
                                                                CASE WHEN b.lift THEN ', used because no weather entry exists' WHEN b.wx_block IS NOT NULL THEN ', BELOW minima' ELSE '' END) END,
                     CASE WHEN b.fog_p IS NOT NULL THEN format('chance %s is below minima by arrival %s%% (ESTIMATED_MODEL from METAR history, +%s delay-min expected)', b.alt_iata, round(100 * b.fog_p), round(b.fog_cost)) END) END,
           b.fog_p, b.fog_cost,
           jsonb_build_object('return', round(b.ret_min), 'fixed', round(f_fixed), 'connections', round(b.pax_cost), 'crew', round(b.crew_cost),
                              'stands', b.stand_cost, 'capacity', b.capc_cost, 'fog', round(b.fog_cost)),
           b.est_flight_min, b.fuel_margin_min
      FROM (
        SELECT a.alt_iata, a.is_executable, a.blocking_constraints, a.est_flight_min, a.fuel_margin_min,
               greatest(0, extract(epoch FROM (a.return_arrival_hub_utc - i.anchor_utc))/60) AS ret_min,
               CASE WHEN a.stands_left IS NOT NULL AND a.stands_left <= 1 THEN f_stand ELSE 0 END AS stand_cost,
               CASE WHEN cp->>'outcome' = 'CAPACITY_CONSTRAINED' THEN f_capc ELSE 0 END AS capc_cost,
               greatest(0, extract(epoch FROM (a.return_arrival_hub_utc - i.anchor_utc))/60) + f_fixed
                 + f_pax * (coalesce(ci.pax_missed,0) + 0.5 * coalesce(ci.pax_tight,0))
                 + CASE a.crew_outcome WHEN 'CREW_CAN_RETURN' THEN 0
                                       WHEN 'NEEDS_COMMANDER_DISCRETION' THEN f_disc
                                       WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN coalesce(a.road_positioning_min, 0) + f_road
                                       WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN f_dead
                                       ELSE f_verify END
                 + CASE WHEN a.stands_left IS NOT NULL AND a.stands_left <= 1 THEN f_stand ELSE 0 END
                 + CASE WHEN cp->>'outcome' = 'CAPACITY_CONSTRAINED' THEN f_capc ELSE 0 END AS base_cost,
               f_pax * (coalesce(ci.pax_missed,0) + 0.5 * coalesce(ci.pax_tight,0)) AS pax_cost,
               CASE a.crew_outcome WHEN 'CREW_CAN_RETURN' THEN 0 WHEN 'NEEDS_COMMANDER_DISCRETION' THEN f_disc
                                   WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN coalesce(a.road_positioning_min, 0) + f_road
                                   WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN f_dead ELSE f_verify END AS crew_cost,
               ci.pax_missed, ci.pax_tight, ci.connections, ci.pax_total,
               CASE WHEN cp->>'outcome' = 'CAPACITY_EXCEEDED' THEN jsonb_build_object(
                    'code', CASE WHEN cp->>'stands_outcome' = 'EXCEEDED' THEN 'NO_STAND_CAPACITY' ELSE 'NO_ARRIVAL_SLOT' END,
                    'detail', cp->'reasons'->>CASE WHEN cp->>'stands_outcome' = 'EXCEEDED' THEN 0 ELSE 1 END) END AS cap_block,
               format('Station capacity at %s (%s UTC): %s. %s', a.alt_iata, to_char(coalesce(a.est_arrival_utc, i.now_utc) AT TIME ZONE 'UTC','HH24:MI'),
                      CASE cp->>'outcome' WHEN 'CAPACITY_AVAILABLE' THEN 'stands and arrival slots available'
                                          WHEN 'CAPACITY_CONSTRAINED' THEN 'at the limit (at most 1 stand or slot left)'
                                          WHEN 'CAPACITY_EXCEEDED' THEN 'NO stand or arrival slot left'
                                          ELSE 'stands or arrival slots UNKNOWN: needs verification with the station' END,
                      coalesce(cp->'reasons'->>1, '')) AS cap_note,
               w.vsby_m AS alt_vis, w.obs_utc AS alt_obs,
               CASE WHEN w.vsby_m < v_minima THEN jsonb_build_object('code', 'WEATHER_BELOW_MINIMA_METAR',
                    'detail', format('METAR %s UTC: visibility %s m is below the %s m limit (EXTERNAL_OBSERVED)', to_char(w.obs_utc AT TIME ZONE 'UTC','HH24:MI'), w.vsby_m, v_minima)) END AS wx_block,
               -- a missing weather entry is replaced by a fresh METAR above minima, but every other unconfirmed item still blocks
               (w.vsby_m >= v_minima
                AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(a.blocking_constraints, '[]'::jsonb)) x WHERE x->>'code' = 'WEATHER_UNCONFIRMED')
                AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(a.blocking_constraints, '[]'::jsonb)) x WHERE x->>'code' <> 'WEATHER_UNCONFIRMED')) AS lift,
               fr.p_below AS fog_p, coalesce(fr.p_below, 0) * f_altfog AS fog_cost
          FROM jsonb_to_recordset(v_alts) AS a(alt_iata char(3), est_arrival_utc timestamptz, return_arrival_hub_utc timestamptz, crew_outcome text, road_positioning_min int, stands_left int,
                                               est_flight_min int, fuel_margin_min int, is_executable boolean, blocking_constraints jsonb)
          CROSS JOIN LATERAL connection_impact(p_scenario_id, p_flight_id, a.return_arrival_hub_utc) ci
          CROSS JOIN LATERAL airport_capacity_assess(p_scenario_id, a.alt_iata, coalesce(a.est_arrival_utc, i.now_utc), 0, p_flight_id, 0, 1) cp
          LEFT JOIN LATERAL (SELECT o.vsby_m, o.obs_utc FROM weather_obs o JOIN weather_station s ON s.icao = o.icao
                              WHERE v_use_wx AND s.iata = a.alt_iata AND o.obs_utc <= i.now_utc AND o.obs_utc > i.now_utc - make_interval(mins => v_wx_max_age::int) AND o.vsby_m IS NOT NULL
                              ORDER BY o.obs_utc DESC LIMIT 1) w ON TRUE
          LEFT JOIN LATERAL (SELECT r.p_below FROM weather_station s, alt_fog_risk(s.icao, v_hub_fog, coalesce(a.est_arrival_utc, i.now_utc) - interval '1 hour') r
                              WHERE s.iata = a.alt_iata LIMIT 1) fr ON TRUE
      ) b;

    -- fallback of the hold: the executable alternate with the lowest cost; the aircraft can wait until its bingo time
    SELECT (a->>'bingo_utc')::timestamptz, (a->>'alt_iata')::char(3), d.cost INTO v_db, v_db_alt, v_best_div
      FROM jsonb_array_elements(v_alts) a JOIN _pd_alt d ON d.alt = (a->>'alt_iata')::char(3)
     WHERE d.exe AND (a->>'bingo_utc') IS NOT NULL AND (a->>'bingo_utc')::timestamptz > i.anchor_utc
     ORDER BY d.cost LIMIT 1;

    IF v_sigma IS NOT NULL AND v_sigma > 0 THEN
        IF v_db IS NOT NULL THEN
            v_p_late := 1 - norm_cdf((extract(epoch FROM (v_db - v_reopen))/60) / v_sigma);
            v_late_cost := extract(epoch FROM (v_db - i.anchor_utc))/60 + v_best_div;
        ELSE
            v_p_late := CASE WHEN i.endurance_until IS NULL THEN 1
                             ELSE 1 - norm_cdf((extract(epoch FROM (i.endurance_until - make_interval(mins => p_approach_min) - v_reopen))/60) / v_sigma) END;
            v_late_cost := f_nofb;
        END IF;
    ELSIF v_reopen IS NOT NULL THEN
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
        CASE WHEN v_land IS NOT NULL THEN format('Landing at %s after forecast reopening (%s)', to_char(v_land AT TIME ZONE 'UTC','HH24:MI"Z"'), v_rq) END,
        CASE WHEN v_p90 IS NOT NULL THEN format('Reopening P90 %s: %s%% chance fog lasts past %s', to_char(v_p90 AT TIME ZONE 'UTC','HH24:MI"Z"'),
                 round(100 * v_p_late)::int, CASE WHEN v_db IS NOT NULL THEN to_char(v_db AT TIME ZONE 'UTC','HH24:MI"Z"') || ' (last moment to divert to ' || v_db_alt || ')'
                                                  ELSE 'the fuel limit (no alternate reachable)' END) END,
        CASE WHEN v_spare IS NOT NULL THEN format('Fuel spare at landing %s min (%s)', v_spare, i.fuel_quality) END,
        CASE WHEN v_hold_crew IS NOT NULL THEN format('Crew margin at landing %s min', v_hold_crew) END,
        CASE WHEN v_ext IS NOT NULL THEN format('Needs commander discretion: about %s min beyond the legal duty (the captain decides)', v_ext) END,
        CASE WHEN v_ci.connections > 0 THEN format('Connections at landing: %s pax miss, %s tight (of %s connecting pax)', v_ci.pax_missed, v_ci.pax_tight, v_ci.pax_total) END,
        v_slot_note,
        v_model_note,
        CASE WHEN v_hold_ok AND v_spare < p_min_hold_spare_min THEN format('Fuel spare below the %s min hold buffer (+%s delay-min risk)', p_min_hold_spare_min, round(f_thin)) END,
        CASE WHEN v_hold_ok THEN format('Expected cost %s delay-min (wait %s, connections %s, crew %s, late-divert risk %s)', round(v_hold_cost), round(v_wait), round(v_hold_pax), round(v_hold_crew_cost), round(v_p_late * v_late_cost)) END], NULL);

    v_conf := 0.9 - CASE WHEN i.fuel_quality IN ('ESTIMATED','ASSUMED','SIMULATED') THEN 0.15 ELSE 0 END
                  - CASE WHEN v_rq = 'FORECAST' THEN 0.10 ELSE 0 END
                  - CASE WHEN NOT i.crew_known THEN 0.20 ELSE 0 END - v_wx_conf;

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
               d.exe, d.blocking,
               array_remove((SELECT array_agg(t) FROM jsonb_array_elements_text(a.reasons) t) || ARRAY[
                   d.cap_note, d.wx_note,
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
    -- WHY this option, and what the model does NOT account for (rationale text, uncertainty.why, uncertainty.not_accounted_for)
    IF v_type = 'DIVERT' THEN
        SELECT d.* INTO v_win FROM _pd_alt d WHERE d.alt = v_best.alternate_iata;
        SELECT d.* INTO v_run FROM _pd_alt d WHERE d.exe AND d.alt <> v_best.alternate_iata ORDER BY d.cost LIMIT 1;
        IF v_run.alt IS NOT NULL THEN
            SELECT k.key, (v_run.comp->>k.key)::numeric - (v_win.comp->>k.key)::numeric INTO v_key, v_gap
              FROM jsonb_object_keys(v_win.comp) AS k(key) ORDER BY 2 DESC LIMIT 1;
            v_why := format('%s is cheaper than %s (%s vs %s delay-min expected)%s.', v_win.alt, v_run.alt, round(v_win.cost), round(v_run.cost),
                CASE WHEN v_gap IS NULL OR v_gap < 1 THEN ': the two are almost tied'
                     ELSE '. Largest difference: ' || CASE v_key
                        WHEN 'fog' THEN format('%s has a %s%% chance of being below minima at arrival (from the fog history, +%s delay-min) against %s%% for %s',
                                               v_run.alt, round(100 * coalesce(v_run.fog_p, 0)), round(v_run.fog_cost), round(100 * coalesce(v_win.fog_p, 0)), v_win.alt)
                        WHEN 'return' THEN format('%s gets the aircraft back to %s about %s min sooner', v_win.alt, i.hub_iata, round(v_gap))
                        WHEN 'connections' THEN format('fewer connecting passengers miss their flight via %s (%s min of cost less)', v_win.alt, round(v_gap))
                        WHEN 'crew' THEN format('a better crew outcome via %s (%s min of cost less)', v_win.alt, round(v_gap))
                        WHEN 'stands' THEN format('%s has more free stands', v_win.alt)
                        WHEN 'capacity' THEN format('%s has more arrival slots / stands left', v_win.alt)
                        ELSE 'the fixed cost of a diversion' END END);
            IF v_run.flt_min < v_win.flt_min OR v_run.fuel_m > v_win.fuel_m THEN
                v_why := v_why || format(' %s is %s, but the cost does not reward that: fuel margin only has to stay at or above zero.', v_run.alt,
                    concat_ws(' and ', CASE WHEN v_run.flt_min < v_win.flt_min THEN format('nearer (%s vs %s min flight)', v_run.flt_min, v_win.flt_min) END,
                                       CASE WHEN v_run.fuel_m > v_win.fuel_m THEN format('has more fuel margin (%s vs %s min)', v_run.fuel_m, v_win.fuel_m) END));
            END IF;
        ELSE
            v_why := format('%s is the only diversion that can be executed.', v_best.alternate_iata);
        END IF;
        v_why := v_why || CASE WHEN v_hold_ok THEN format(' Holding would cost about %s delay-min.', round(v_hold_cost))
                               ELSE ' Holding is not possible: ' || (SELECT string_agg(x->>'code', ', ') FROM jsonb_array_elements(v_hold_block) x) || '.' END;
    ELSIF v_type = 'HOLD' THEN
        SELECT d.* INTO v_run FROM _pd_alt d WHERE d.exe ORDER BY d.cost LIMIT 1;
        v_why := CASE WHEN v_run.alt IS NULL THEN 'No diversion can be executed, so holding is the only option.'
                      ELSE format('Holding is cheaper than diverting to %s (%s vs %s delay-min expected).', v_run.alt, round(v_hold_cost), round(v_run.cost)) END;
    END IF;
    v_data_age := (SELECT extract(epoch FROM (i.now_utc - coalesce(fs.last_event_ts, fs.last_received_at))) / 60
                     FROM flight_state fs WHERE fs.scenario_id = p_scenario_id AND fs.flight_id = p_flight_id);
    v_unc := to_jsonb(array_remove(ARRAY[
        CASE WHEN i.fuel_quality IS NULL OR i.fuel_quality IN ('ESTIMATED','ASSUMED','SIMULATED') THEN
             format('Fuel on board is %s: it can be off by about 15-20 min of hold at P90. Each option''s fuel margin is measured against a fixed P90 trip fuel, so that error is not priced (a thin margin is not penalised unless it is below zero)', lower(coalesce(i.fuel_quality, 'unknown'))) END,
        CASE WHEN v_data_age > 20 THEN format('Position and ETA data are %s min old: the aircraft may not be where it is assumed to be (the hub terminal area)', round(v_data_age)) END,
        CASE WHEN NOT i.crew_known THEN 'Crew legality is not verified for every crew member: the crew cost uses a flat penalty' END,
        'How long the fog lasts: one distribution around the stated reopening time (spread fitted on METAR history, no weather-forecast skill); fog longer than the P90 is not covered',
        'Weather at the alternates: the history of fog at each alternate when the hub is in fog (plus a fresh METAR when real weather is switched on); the forecast (TAF) for each alternate is not used',
        'Cost weights (missed connection, crew replacement, fixed diversion cost, capacity) are assumptions, not calibrated',
        'Not modelled: wind and ATC delays, other aircraft diverting to the same alternate (including other airlines), the alternate''s own fuel-to-alternate, runway / NOTAM / curfew limits, passenger care and compensation costs'
    ], NULL));
    v_unc_short := concat_ws('; ',
        CASE WHEN i.fuel_quality IS NULL OR i.fuel_quality IN ('ESTIMATED','ASSUMED','SIMULATED') THEN 'fuel on board is an estimate (about +/-15-20 min) and a thin fuel margin is not penalised' END,
        CASE WHEN v_data_age > 20 THEN format('position/ETA data is %s min old', round(v_data_age)) END,
        CASE WHEN NOT i.crew_known THEN 'crew legality unverified' END,
        'fog longer than the P90', 'forecasts (TAF) at the alternates', 'cost weights are assumptions', 'wind/ATC delays and other aircraft diverting to the same alternate');

    v_rationale := CASE
        WHEN NOT v_best.is_executable THEN
            'No option has all operational inputs confirmed: manual verification required before holding or diverting.'
        WHEN v_type = 'HOLD' THEN
            format('HOLD: lowest expected cost (%s delay-min). %s Fuel and crew cover the forecast reopening (%s). Details: %s', round(v_hold_cost), coalesce(v_why, ''),
                   to_char(v_reopen AT TIME ZONE 'UTC','HH24:MI"Z"'), array_to_string(v_best.reasons, '; '))
        ELSE format('DIVERT %s: lowest expected cost. %s Details: %s', v_best.alternate_iata, coalesce(v_why, ''), array_to_string(v_best.reasons, '; ')) END;

    UPDATE recommendation SET rec_type = v_type,
        rationale = v_rationale || ' Not accounted for: ' || v_unc_short || '.',
        confidence = greatest(0.3, confidence - CASE WHEN v_hist_used THEN 0.10 ELSE 0 END
                                              - CASE WHEN v_type = 'HOLD' AND v_p_late > 0.25 THEN 0.10 ELSE 0 END),
        assumptions = jsonb_build_array(
            format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
            format('Hub reopening quality: %s', coalesce(v_rq, 'none')),
            'Options compared on expected delay-equivalent minutes; the cost constants in divert_policy (cost_*) are ASSUMED, not calibrated',
            CASE WHEN v_fz.p50_min IS NOT NULL THEN 'Reopening is modelled as a normal distribution around the stated time; the P90 spread comes from the fog model fitted on external METAR history (ESTIMATED)'
                 ELSE 'Reopening is modelled as a normal distribution around the stated time, P90 spread from reopen_spread_* (ASSUMED; no fresh fog observation or model)' END,
            format('Weather used: %s', v_wx_mode),
            'Alternate weather: a person''s entry wins; otherwise a fresh METAR (EXTERNAL_OBSERVED) and the fitted chance of fog at arrival (ESTIMATED_MODEL) are used and labelled',
            'Distance to alternates measured from the hub (aircraft assumed in the hub terminal area)',
            'Diversion counts as one extra sector for every operating crew member',
            CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                 THEN format('Flight not yet departed: pre-departure assessment, all times anchored at projected arrival %s (not at the current clock)',
                             to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'))
                 ELSE format('Decision moment %s (%s)', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'), lower(i.flight_phase)) END,
            CASE WHEN v_hist_used THEN 'Alternate availability and stands come from the supplied flight history (no live status); a station entry overrides them'
                 ELSE 'Alternate status/parking taken from the latest airport_status_event, else from the supplied history' END),
        uncertainty = jsonb_build_object('reopening_utc', v_reopen, 'reopening_p90_utc', v_p90, 'reopening_quality', v_rq,
                                         'endurance_left_min', i.endurance_left_min, 'p_fog_outlasts_decision_by', round(v_p_late, 3),
                                         'decision_by_utc', v_db, 'fallback_alternate', v_db_alt,
                                         'weather_model', CASE WHEN v_fz.p50_min IS NOT NULL THEN jsonb_build_object('run_id', v_fz.run_id, 'quality', v_fz.quality, 'p10_min', round(v_fz.p10_min), 'p50_min', round(v_fz.p50_min), 'p90_min', round(v_fz.p90_min), 'n_support', v_fz.n_support, 'vis_m', v_fz.vis_m, 'fog_age_min', v_fz.age_min, 'used_as', CASE WHEN i.reopen_utc IS NULL THEN 'reopening' ELSE 'spread' END, 'mode', CASE WHEN v_use_wx THEN 'REAL_WEATHER' ELSE 'ENTERED_ONLY' END) END,
                                         'weather_switch', v_use_wx, 'why', v_why, 'not_accounted_for', v_unc,
                                         'hold_cost_min', round(v_hold_cost), 'cost_unit', 'delay-equivalent minutes (ASSUMED weights)')
     WHERE rec_id = v_rec;
    RETURN v_rec;
END $function$;
