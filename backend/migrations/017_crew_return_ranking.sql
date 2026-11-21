-- 017: crew return to the hub now counts in the diversion ranking.
--
-- A crew member needs to be back at the hub when their NEXT FLIGHT duty starts there (the first airport of the roster block, e.g.
-- 'SHJ-MCT/MCT-SHJ'). Standby, training, sim and leave do not count, nor does a flight that starts at another airport.
--   * none of the operating crew needs to be back  -> return time has no effect on the ranking
--   * some do                                      -> the alternate's score blends in a return score, weighted by the share of crew
--                                                     who need it: quicker return scores higher, too late scores 0 (and is flagged)
-- It does not block an alternate (a replacement crew or re-roster is possible). Weights are ASSUMED and live in divert_policy.

SET search_path = fogops, hist, public;

INSERT INTO divert_policy (key, value, unit, basis) VALUES
  ('crew_return_weight',    0.20, 'share', 'ASSUMED: share of an alternate''s score given to the crew return when every operating crew member flies from the hub next.'),
  ('crew_return_ref_min',   600,  'min',   'ASSUMED: a return taking this long scores the floor; quicker returns score higher (nearest airport best).'),
  ('crew_return_floor',     0.30, 'score', 'ASSUMED: lowest return score for a return that still makes the next flight.'),
  ('crew_return_tight_min', 120,  'min',   'ASSUMED: if the crew arrive with less than this spare before their next flight, the return score is multiplied by 0.6.')
ON CONFLICT (key) DO NOTHING;

DROP FUNCTION IF EXISTS crew_return_options(integer, bigint, character, timestamp with time zone);
CREATE FUNCTION crew_return_options(p_scenario_id INT, p_flight_id BIGINT, p_station CHAR(3), p_from_utc TIMESTAMPTZ)
RETURNS TABLE (mode TEXT, n_crew INT, n_need_hub INT, depart_utc TIMESTAMPTZ, arrive_hub_utc TIMESTAMPTZ, duration_min INT, via TEXT,
               next_duty_utc TIMESTAMPTZ, next_flight_route TEXT, margin_min INT, feasible BOOLEAN, basis TEXT, note TEXT)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_hub CHAR(3); v_n INT; v_need INT; v_next TIMESTAMPTZ; v_route TEXT; v_any BOOLEAN := FALSE; p airport_pair_travel%ROWTYPE; d RECORD;
    v_chk INT := coalesce((SELECT value FROM divert_policy WHERE key = 'deadhead_checkin_min'), 60)::int;
BEGIN
    SELECT trim(f.arr_iata) INTO v_hub FROM flight f WHERE f.flight_id = p_flight_id;
    -- operating crew of this flight's duty and, for each, the next FLIGHT duty after the duty ends; only those starting at the hub matter
    SELECT count(*)::int,
           (count(*) FILTER (WHERE left(x.nf_block, 3) = v_hub))::int,
           min(x.nf_start) FILTER (WHERE left(x.nf_block, 3) = v_hub),
           (array_agg(x.nf_block ORDER BY x.nf_start) FILTER (WHERE left(x.nf_block, 3) = v_hub))[1]
      INTO v_n, v_need, v_next, v_route
      FROM (SELECT DISTINCT ON (ca.crew_id) ca.crew_id, re.start_utc AS nf_start, re.block_name AS nf_block
              FROM crew_duty_leg l
              JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id AND ca.valid_to IS NULL
              JOIN crew_type ct ON ct.code = ca.position_code AND ct.gates_flight_legality
              JOIN flight fl ON fl.flight_id = p_flight_id
              LEFT JOIN fdp_calculation fc ON fc.scenario_id = l.scenario_id AND fc.duty_id = l.duty_id AND fc.crew_id = ca.crew_id AND fc.is_current
              LEFT JOIN LATERAL (SELECT r.start_utc, r.block_name FROM roster_entry r
                                  WHERE r.crew_id = ca.crew_id AND r.duty_type = 'FLIGHT'
                                    AND r.start_utc > coalesce(fc.projected_end_utc, fl.sta_utc)
                                  ORDER BY r.start_utc LIMIT 1) re ON TRUE
             WHERE l.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active
             ORDER BY ca.crew_id) x;

    SELECT * INTO p FROM airport_pair_travel t WHERE t.from_iata = p_station AND t.to_iata = v_hub;
    IF FOUND AND p.road_in_time THEN
        v_any := TRUE;
        mode := 'ROAD'; n_crew := v_n; n_need_hub := v_need; depart_utc := p_from_utc; duration_min := p.road_min;
        arrive_hub_utc := p_from_utc + make_interval(mins => p.road_min); via := format('road, %s km', round(p.road_km));
        next_duty_utc := v_next; next_flight_route := v_route; margin_min := floor(extract(epoch FROM v_next - arrive_hub_utc) / 60)::int;
        feasible := v_next IS NULL OR arrive_hub_utc <= v_next; basis := 'SYNTHETIC road time'; note := NULL;
        RETURN NEXT;
    END IF;

    SELECT f.flight_no AS fno, coalesce(s.etd_utc, f.std_utc) AS dep, coalesce(s.eta_utc, f.sta_utc) AS arr INTO d
      FROM flight f LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
     WHERE trim(f.dep_iata) = p_station AND trim(f.arr_iata) = v_hub AND coalesce(s.is_cancelled, FALSE) = FALSE
       AND coalesce(s.status::text, 'SCHEDULED') IN ('SCHEDULED', 'TAXI_OUT')
       AND coalesce(s.etd_utc, f.std_utc) >= p_from_utc + make_interval(mins => v_chk)
     ORDER BY coalesce(s.etd_utc, f.std_utc) LIMIT 1;
    IF FOUND THEN
        v_any := TRUE;
        mode := 'DEADHEAD'; n_crew := v_n; n_need_hub := v_need; depart_utc := d.dep; arrive_hub_utc := d.arr;
        duration_min := floor(extract(epoch FROM d.arr - p_from_utc) / 60)::int; via := 'flight ' || d.fno;
        next_duty_utc := v_next; next_flight_route := v_route; margin_min := floor(extract(epoch FROM v_next - d.arr) / 60)::int;
        feasible := v_next IS NULL OR d.arr <= v_next; basis := 'scheduled flight; seats ASSUMED available';
        note := format('crew at the station %s min before departure', v_chk);
        RETURN NEXT;
    END IF;

    IF NOT v_any THEN
        mode := 'NONE'; n_crew := v_n; n_need_hub := v_need; depart_utc := NULL; arrive_hub_utc := NULL; duration_min := NULL; via := NULL;
        next_duty_utc := v_next; next_flight_route := v_route; margin_min := NULL; feasible := FALSE; basis := 'none';
        note := 'No road transfer in time and no scheduled flight back to the hub';
        RETURN NEXT;
    END IF;
END $$;

-- The best way back (earliest arrival) turned into a ranking weight and score.
CREATE FUNCTION crew_return_factor(p_scenario_id INT, p_flight_id BIGINT, p_station CHAR(3), p_from_utc TIMESTAMPTZ,
                                   OUT weight NUMERIC, OUT s_return NUMERIC, OUT n_need INT, OUT n_crew INT,
                                   OUT feasible BOOLEAN, OUT margin_min INT, OUT duration_min INT, OUT mode TEXT)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_w     NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'crew_return_weight'), 0.20);
    v_ref   NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'crew_return_ref_min'), 600);
    v_floor NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'crew_return_floor'), 0.30);
    v_tight NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'crew_return_tight_min'), 120);
BEGIN
    weight := 0; s_return := NULL; n_need := 0; n_crew := 0; feasible := NULL; margin_min := NULL; duration_min := NULL; mode := NULL;
    SELECT o.n_crew, o.n_need_hub, o.feasible, o.margin_min, o.duration_min, o.mode
      INTO n_crew, n_need, feasible, margin_min, duration_min, mode
      FROM crew_return_options(p_scenario_id, p_flight_id, p_station, p_from_utc) o ORDER BY o.arrive_hub_utc NULLS LAST LIMIT 1;
    IF NOT FOUND OR coalesce(n_need, 0) = 0 OR coalesce(n_crew, 0) = 0 THEN
        weight := 0; s_return := NULL; RETURN;       -- nobody flies from the hub next: return time does not count
    END IF;
    weight := round(v_w * n_need / n_crew, 4);
    s_return := CASE WHEN NOT feasible OR mode = 'NONE' THEN 0
                     ELSE round(greatest(v_floor, 1 - duration_min / v_ref) * CASE WHEN margin_min < v_tight THEN 0.6 ELSE 1 END, 3) END;
END $$;

CREATE OR REPLACE FUNCTION crew_return_summary(p_scenario_id INT, p_flight_id BIGINT, p_station CHAR(3), p_from_utc TIMESTAMPTZ)
RETURNS TEXT LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
DECLARE b RECORD; v_hub CHAR(3); v_next TEXT;
BEGIN
    SELECT trim(f.arr_iata) INTO v_hub FROM flight f WHERE f.flight_id = p_flight_id;
    SELECT * INTO b FROM crew_return_options(p_scenario_id, p_flight_id, p_station, p_from_utc) o ORDER BY o.arrive_hub_utc NULLS LAST LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_next := CASE WHEN b.next_duty_utc IS NOT NULL
                   THEN format('first: %s at %s', b.next_flight_route, to_char(b.next_duty_utc AT TIME ZONE 'UTC', 'DD HH24:MI"Z"')) END;
    IF coalesce(b.n_need_hub, 0) = 0 THEN
        RETURN format('None of the %s operating crew has a next flight from %s, so the return from %s does not affect the ranking%s',
                      coalesce(b.n_crew, 0), v_hub, p_station,
                      CASE WHEN b.mode = 'NONE' THEN '' ELSE format(' (they could be back by %s via %s)', to_char(b.arrive_hub_utc AT TIME ZONE 'UTC', 'DD HH24:MI"Z"'), b.via) END);
    END IF;
    IF b.mode = 'NONE' THEN
        RETURN format('%s of the %s crew fly from %s next (%s) and there is no road transfer in time or scheduled flight back from %s: re-roster or replace the crew',
                      b.n_need_hub, b.n_crew, v_hub, v_next, p_station);
    END IF;
    IF b.feasible THEN
        RETURN format('%s of the %s crew fly from %s next (%s): back by %s (%s; %s), %s h %s min spare; return time counts in the ranking',
                      b.n_need_hub, b.n_crew, v_hub, v_next, to_char(b.arrive_hub_utc AT TIME ZONE 'UTC', 'DD HH24:MI"Z"'), b.via, b.basis,
                      b.margin_min / 60, b.margin_min % 60);
    END IF;
    RETURN format('%s of the %s crew would miss their next flight from %s (%s): back only by %s (%s), %s h %s min late; re-roster or replace the crew',
                  b.n_need_hub, b.n_crew, v_hub, v_next, to_char(b.arrive_hub_utc AT TIME ZONE 'UTC', 'DD HH24:MI"Z"'), b.via,
                  (-b.margin_min) / 60, (-b.margin_min) % 60);
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
               coalesce(st.fuel_ok, aa.fuel_available) AS fuel_ok, coalesce(st.handling_ok, aa.handling_contract) AS handling_ok,
               (st.op_status IS NOT NULL) AS has_live,
               (SELECT u.role_code FROM app_user u WHERE u.user_id = st.entered_by) AS live_by,
               hs.evidence AS h_evidence, hs.fog_days_with_landing AS h_days, hs.fog_days AS h_fog, hs.diverted_in AS h_div,
               hs.peak_concurrent AS h_peak, hs.peak_day AS h_peak_day, hs.weather_delay_rate AS h_wx,
               (st.op_status IS NULL AND hs.evidence IN ('STRONG', 'PROVEN')) AS hist_ok,
               distance_km(i.hub_iata, aa.alt_iata) AS dist,
               (SELECT count(*) FROM diversion dv
                 WHERE dv.scenario_id = p_scenario_id AND dv.alternate_iata = aa.alt_iata
                   AND dv.original_flight_id <> p_flight_id
                   AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED'))::int AS occupied,
               b.p90_block_min, b.median_block_min, b.sample_n,
               l.airborne_p50_min AS l50, l.airborne_p90_min AS l90, l.sample_n AS l_n, l.source AS l_src,
               pt.trip_fuel_p90_kg AS trip_p90, pt.fuel_basis AS trip_basis, pt.fuel_n AS trip_n
          FROM alternate_airport aa JOIN airport ap ON ap.iata = aa.alt_iata
          LEFT JOIN LATERAL (SELECT * FROM airport_status_event x
                              WHERE x.scenario_id = p_scenario_id AND x.iata = aa.alt_iata
                                AND x.effective_from_utc <= i.now_utc
                              ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1) st ON TRUE
          LEFT JOIN alternate_history_stats hs ON hs.alt_iata = aa.alt_iata
          LEFT JOIN block_time_reference b ON b.from_iata = aa.alt_iata AND b.to_iata = i.hub_iata
          LEFT JOIN leg_time_reference l ON l.from_iata = i.hub_iata AND l.to_iata = aa.alt_iata
          LEFT JOIN airport_pair_travel pt ON pt.from_iata = i.hub_iata AND pt.to_iata = aa.alt_iata
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
               coalesce(a.parking_available, a.max_parking_stands,
                        CASE WHEN a.h_evidence IN ('STRONG', 'PROVEN') THEN a.h_peak END) - a.occupied AS stands,
               CASE WHEN a.parking_available IS NOT NULL THEN 'LIVE' WHEN a.max_parking_stands IS NOT NULL THEN 'CONFIG'
                    WHEN a.h_evidence IN ('STRONG', 'PROVEN') THEN 'HISTORY' END AS stand_src
          FROM alt a
    ), t AS (
        SELECT m.*,
               i.anchor_utc + make_interval(mins => m.fl_min) AS arr_utc,
               -- fuel margin = minutes of fuel left on arrival above the final reserve
               CASE WHEN v_fuel_min IS NOT NULL AND m.trip_p90 IS NOT NULL AND v_burn > 0
                         THEN floor(v_fuel_min - m.trip_p90 * 60.0 / v_burn - v_reserve)::int
                    WHEN v_fuel_min IS NOT NULL THEN floor(v_fuel_min - m.fl90 - v_reserve)::int
                    WHEN i.endurance_left_min IS NOT NULL THEN i.endurance_left_min - m.fl90
               END AS fuel_margin,
               CASE WHEN v_fuel_min IS NOT NULL AND m.trip_p90 IS NOT NULL AND v_burn > 0
                         THEN format('Fuel on board now about %s kg; the trip to %s needs about %s kg (P90, %s, %s flights) plus %s kg final reserve (%s min at %s kg/h hold burn)', round(v_fuel_min * v_burn / 60), m.alt_iata, m.trip_p90, m.trip_basis, m.trip_n, round(v_reserve * v_burn / 60), v_reserve, v_burn)
                    WHEN v_fuel_min IS NOT NULL
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
                  (CASE WHEN NOT t.has_live AND coalesce(t.h_evidence, 'NONE') = 'NONE' THEN jsonb_build_object('code','ALTERNATE_STATUS_UNKNOWN','verify',true) END),
                  (CASE WHEN NOT t.has_live AND t.h_evidence = 'LIMITED' THEN jsonb_build_object('code','ALTERNATE_HISTORY_LIMITED','verify',true,'fog_days_with_landing',t.h_days) END),
                  (CASE WHEN t.has_live AND t.op_status <> 'OPEN' THEN jsonb_build_object('code','ALTERNATE_NOT_OPEN','value',t.op_status) END),
                  (CASE WHEN t.has_live AND t.weather_above_minima IS NULL THEN jsonb_build_object('code','WEATHER_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.hist_ok AND t.h_wx > coalesce((SELECT value FROM divert_policy WHERE key = 'hist_weather_block_rate'), 0.05)
                        THEN jsonb_build_object('code','WEATHER_HISTORY_RISK','verify',true,'rate',t.h_wx) END),
                  (CASE WHEN t.weather_above_minima IS FALSE THEN jsonb_build_object('code','WEATHER_BELOW_MINIMA') END),
                  (CASE WHEN t.has_live AND t.stands IS NULL THEN jsonb_build_object('code','PARKING_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.stands <= 0 AND t.stand_src IN ('LIVE','CONFIG') THEN jsonb_build_object('code','NO_PARKING','occupied',t.occupied) END),
                  (CASE WHEN t.stands <= 0 AND t.stand_src = 'HISTORY'
                        THEN jsonb_build_object('code','PARKING_BEYOND_HISTORY','verify',true,'occupied',t.occupied,'demonstrated_peak',t.h_peak) END),
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
               least(1, o.historical_diversions / 30.0) AS s_hist,
               coalesce(cr.weight, 0) AS ret_w, cr.s_return AS ret_s, cr.n_need AS ret_need, cr.n_crew AS ret_crew
          FROM o
          LEFT JOIN LATERAL crew_return_factor(p_scenario_id, p_flight_id, o.alt_iata, o.arr_utc) cr ON TRUE
    ), fin AS (
        SELECT sc.*, round((1 - sc.ret_w) * (0.30*s_fuel + 0.30*s_crew + 0.15*s_rec + 0.10*s_stand + 0.15*s_hist)
                           + sc.ret_w * coalesce(sc.ret_s, 0), 3) AS total
          FROM sc
    )
    SELECT (row_number() OVER (ORDER BY jsonb_array_length(fin.blocking) = 0 DESC, fin.total DESC))::int,
           fin.alt_iata, fin.alt_name, jsonb_array_length(fin.blocking) = 0, fin.total,
           coalesce(fin.op_status, CASE WHEN fin.hist_ok THEN 'OPEN (history)' END), fin.lvp_in_force, fin.weather_above_minima, fin.stands, fin.fuel_ok, fin.handling_ok,
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
               CASE WHEN fin.fuel_basis LIKE 'Fuel on board now%' THEN fin.fuel_basis END,
               crew_return_summary(p_scenario_id, p_flight_id, fin.alt_iata, fin.arr_utc),
               CASE fin.outcome
                    WHEN 'CREW_CAN_RETURN' THEN format('Crew can fly %s-%s legally (%s min spare)', fin.alt_iata, i.hub_iata, fin.crew_margin)
                    WHEN 'NEEDS_COMMANDER_DISCRETION' THEN format('Return needs commander discretion: about %s min beyond the legal duty (the captain decides)', greatest(0, -fin.crew_margin))
                    WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN format('Replacement crew needed: %s min by road from %s', fin.road_positioning_min, i.hub_iata)
                    WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN 'Replacement crew needed: deadhead flight'
                    ELSE 'Crew legality unverified' END,
               CASE WHEN fin.has_live THEN format('%s status is live: %s (entered by %s)', fin.alt_iata, lower(fin.op_status), coalesce(fin.live_by, 'a user'))
                    WHEN fin.hist_ok THEN format('%s availability from history: landed aircraft on %s of %s SHJ fog days, took %s diverted aircraft, peak %s on the ground at once (%s); no live status, confirm with the station if possible',
                                                 fin.alt_iata, fin.h_days, fin.h_fog, fin.h_div, fin.h_peak, to_char(fin.h_peak_day, 'DD Mon YYYY'))
                    WHEN fin.h_evidence = 'LIMITED' THEN format('%s has only %s fog day(s) of history: a station must confirm it', fin.alt_iata, fin.h_days) END,
               CASE WHEN fin.stands IS NOT NULL THEN format('%s stand(s) left (%s)', fin.stands,
                         CASE fin.stand_src WHEN 'LIVE' THEN 'live' WHEN 'CONFIG' THEN 'configured' ELSE 'demonstrated peak of ' || fin.h_peak || ' in history' END) END,
               CASE WHEN fin.hist_ok AND fin.h_wx IS NOT NULL THEN format('Weather: %s%% of historical arrivals had a weather delay code', round(fin.h_wx * 100, 1)) END,
               format('%s-%s block %s min (%s)', fin.alt_iata, i.hub_iata, fin.ret_blk, fin.ret_basis),
               format('Back at %s about %s UTC (ground %s min + block %s min)', i.hub_iata,
                      to_char((fin.earliest_dep + make_interval(mins => fin.ret_med)) AT TIME ZONE 'UTC', 'HH24:MI'),
                      fin.min_ground_time_min, fin.ret_med),
               CASE WHEN fin.historical_diversions > 0 THEN format('Used for %s SHJ diversions in 2026', fin.historical_diversions) END],
               NULL),
           jsonb_build_object('fuel', round(fin.s_fuel,3), 'crew', round(fin.s_crew,3), 'recovery', round(fin.s_rec,3),
                              'stands', round(fin.s_stand,3), 'history', round(fin.s_hist,3),
                              'station_basis', CASE WHEN fin.has_live THEN 'LIVE' WHEN fin.hist_ok THEN 'HISTORICAL' ELSE 'NONE' END,
                              'station_evidence', fin.h_evidence, 'stand_source', fin.stand_src,
                              'crew_return', jsonb_build_object('weight', fin.ret_w, 'score', fin.ret_s, 'crew_needing_return', fin.ret_need, 'crew', fin.ret_crew),
                              'weights', '{"fuel":0.30,"crew":0.30,"recovery":0.15,"stands":0.10,"history":0.15}'::jsonb),
           fin.fl90, fin.fl_basis, v_reserve, fin.fuel_basis,
           CASE WHEN fin.fuel_margin IS NULL THEN NULL ELSE i.now_utc + make_interval(mins => fin.fuel_margin) END,
           fin.earliest_dep + make_interval(mins => fin.ret_med)
      FROM fin
     ORDER BY 1;
END $function$;


DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'fogops' AND p.proname IN ('crew_return_options', 'crew_return_factor', 'crew_return_summary', 'rank_alternates') LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;

-- Re-run the recommendations of the live scenarios with crew return in the ranking.
SELECT enqueue_reassessment(scenario_id, 'migration 017: crew return in the ranking', 'airport', 'SHJ') FROM scenario WHERE kind = 'LIVE' AND is_active;
