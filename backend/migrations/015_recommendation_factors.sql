-- 015: the recommendation looks at all five factors, and station availability comes from the supplied history.
--
--  1. STATION AVAILABILITY from history. No live status exists for the alternates, so every alternate used to be blocked
--     (ALTERNATE_STATUS_UNKNOWN / PARKING_UNCONFIRMED / WEATHER_UNCONFIRMED) and "Alternates: none ranked yet".
--     alternate_history_stats is built from hist.flight (SHJ fog days = days SHJ-planned flights diverted):
--       demonstrated stands = most aircraft of ours seen on the ground at once after diverting there
--       proven usability    = fog days on which it landed aircraft (diverted or scheduled)
--       weather             = share of arrivals with weather delay codes (IATA 71-77)
--     Evidence tier: STRONG (landings on >= hist_strong_min_days fog days), PROVEN (>= hist_proven_min_days), LIMITED (1-2), NONE.
--     A live airport_status_event always overrides history, field by field (status, stands, weather, fuel, handling).
--  2. PASSENGER CONNECTIONS now score every option (connection_impact) and are listed in its reasons.
--  3. CREW EXTENSION (commander discretion) is flagged on hold and divert options with the minutes needed, and ranks them lower.
--  4. DELAY_DEPARTURE checks crew time: past the legal end it warns and offers CREW_REPLACE (re-time or replace the crew).
-- A manual station change already queues a reassessment (trigger reassess_airport -> worker); the new logic reads the live row first.

SET search_path = fogops, hist, public;

INSERT INTO divert_policy (key, value, unit, basis) VALUES
  ('min_connection_min',      40,   'min',   'Minimum connection time: a connection with less than this is at risk (same threshold as v_connection_risk).'),
  ('pax_penalty_max',         0.25, 'score', 'Largest score penalty an option can get for connecting passengers who miss or nearly miss their onward flight. ASSUMED, to be agreed with OCC.'),
  ('pax_penalty_ref_pax',     300,  'pax',   'Missed-passenger equivalents (missed + 0.5 x tight) at which the connection penalty reaches its maximum. ASSUMED.'),
  ('discretion_score_factor', 0.85, 'x',     'Score multiplier for an option that only works if the crew extends duty (commander discretion). ASSUMED.'),
  ('hist_strong_min_days',    10,   'days',  'Fog days with a landing at the alternate for its history to count as STRONG evidence of availability.'),
  ('hist_proven_min_days',    3,    'days',  'Fog days with a landing (diverted aircraft) for its history to count as PROVEN. Below this it stays LIMITED and needs a station to confirm.'),
  ('hist_weather_block_rate', 0.05, 'ratio', 'Share of historical arrivals with weather delay codes above which an alternate without live weather is held for verification.')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS alternate_history_stats (
    alt_iata                 CHAR(3) PRIMARY KEY,
    fog_days                 INT  NOT NULL,   -- days on which SHJ-planned flights diverted
    fog_days_with_landing    INT  NOT NULL,   -- of those, days with any landing at this alternate
    normal_landings_fog_days INT  NOT NULL,
    diverted_in              INT  NOT NULL,
    peak_concurrent          INT  NOT NULL,   -- most diverted aircraft on the ground here at once
    peak_day                 DATE,
    median_ground_min        INT,
    arrivals                 INT  NOT NULL,
    weather_delay_rate       NUMERIC(6,4) NOT NULL,
    evidence                 TEXT NOT NULL CHECK (evidence IN ('STRONG', 'PROVEN', 'LIMITED', 'NONE')),
    built_from               TEXT NOT NULL DEFAULT 'Historical_Flight_Data_Jan-Nov_2026 (hist.flight)',
    built_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

TRUNCATE alternate_history_stats;
WITH fog AS (SELECT DISTINCT date(std_utc) AS d FROM hist.flight WHERE is_diversion AND planned_dest_icao = 'OMSJ'),
alts AS (SELECT alt_iata AS a FROM alternate_airport WHERE hub_iata = 'SHJ'),
dv AS (
    SELECT h.registration, trim(h.arr_iata) AS alt, coalesce(h.ata_utc, h.tdown_utc) AS arr_ts
      FROM hist.flight h WHERE h.is_diversion AND h.planned_dest_icao = 'OMSJ' AND coalesce(h.ata_utc, h.tdown_utc) IS NOT NULL
), g AS (
    SELECT dv.*, (SELECT min(n.atd_utc) FROM hist.flight n WHERE n.registration = dv.registration AND trim(n.dep_iata) = dv.alt
                     AND n.atd_utc > dv.arr_ts AND n.atd_utc < dv.arr_ts + interval '48 hours') AS dep_ts
      FROM dv
), c AS (
    SELECT a.alt, a.arr_ts, a.dep_ts,
           (SELECT count(*) FROM g b WHERE b.alt = a.alt AND b.arr_ts <= a.arr_ts
               AND coalesce(b.dep_ts, b.arr_ts + interval '3 hours') > a.arr_ts) AS conc
      FROM g a
), pk AS (
    SELECT DISTINCT ON (alt) alt, conc, date(arr_ts) AS d FROM c ORDER BY alt, conc DESC, arr_ts
), st AS (
    SELECT a.a AS alt_iata,
           (SELECT count(*) FROM fog) AS fog_days,
           (SELECT count(DISTINCT date(coalesce(h.ata_utc, h.tdown_utc))) FROM hist.flight h JOIN fog f ON f.d = date(coalesce(h.ata_utc, h.tdown_utc))
             WHERE trim(h.arr_iata) = a.a AND h.ata_utc IS NOT NULL) AS landing_days,
           (SELECT count(*) FROM hist.flight h JOIN fog f ON f.d = date(coalesce(h.ata_utc, h.tdown_utc))
             WHERE trim(h.arr_iata) = a.a AND NOT h.is_diversion AND h.ata_utc IS NOT NULL) AS normal_landings,
           (SELECT count(*) FROM g WHERE g.alt = a.a) AS diverted_in,
           coalesce((SELECT conc FROM pk WHERE pk.alt = a.a), 0) AS peak,
           (SELECT d FROM pk WHERE pk.alt = a.a) AS peak_day,
           (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (dep_ts - arr_ts)) / 60)) FROM g WHERE g.alt = a.a AND dep_ts IS NOT NULL)::int AS med_ground,
           (SELECT count(*) FROM hist.flight h WHERE trim(h.arr_iata) = a.a) AS arrivals,
           (SELECT count(*) FROM hist.flight h WHERE trim(h.arr_iata) = a.a AND h.arr_delay_codes ~ '(^|,)[0-9]+min-7[1-7]') AS wx
      FROM alts a
)
INSERT INTO alternate_history_stats (alt_iata, fog_days, fog_days_with_landing, normal_landings_fog_days, diverted_in, peak_concurrent,
                                     peak_day, median_ground_min, arrivals, weather_delay_rate, evidence)
SELECT alt_iata, fog_days, landing_days, normal_landings, diverted_in, peak, peak_day, med_ground, arrivals,
       round(wx::numeric / greatest(arrivals, 1), 4),
       CASE WHEN landing_days >= (SELECT value FROM divert_policy WHERE key = 'hist_strong_min_days') THEN 'STRONG'
            WHEN landing_days >= (SELECT value FROM divert_policy WHERE key = 'hist_proven_min_days') THEN 'PROVEN'
            WHEN landing_days >= 1 THEN 'LIMITED' ELSE 'NONE' END
  FROM st;


-- Connecting passengers on the onward flights of an inbound flight, for a given arrival time at the hub.
CREATE OR REPLACE FUNCTION connection_impact(p_scenario_id INT, p_flight_id BIGINT, p_arrival TIMESTAMPTZ,
                                             OUT pax_missed INT, OUT pax_tight INT, OUT connections INT, OUT pax_total INT, OUT penalty NUMERIC)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_min INT     := coalesce((SELECT value FROM divert_policy WHERE key = 'min_connection_min'), 40)::int;
    v_max NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'pax_penalty_max'), 0.25);
    v_ref NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'pax_penalty_ref_pax'), 300);
BEGIN
    pax_missed := 0; pax_tight := 0; connections := 0; pax_total := 0; penalty := 0;
    IF p_arrival IS NULL THEN RETURN; END IF;
    SELECT coalesce(sum(pc.pax_count) FILTER (WHERE x.dep < p_arrival), 0)::int,
           coalesce(sum(pc.pax_count) FILTER (WHERE x.dep >= p_arrival AND x.dep < p_arrival + make_interval(mins => v_min)), 0)::int,
           count(*)::int, coalesce(sum(pc.pax_count), 0)::int
      INTO pax_missed, pax_tight, connections, pax_total
      FROM pax_connection pc
      JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
      LEFT JOIN flight_state so ON so.flight_id = pc.outbound_flight_id AND so.scenario_id = p_scenario_id
      CROSS JOIN LATERAL (SELECT coalesce(so.atd_utc, so.etd_utc, fo.std_utc) AS dep) x
     WHERE pc.inbound_flight_id = p_flight_id
       AND coalesce(so.is_cancelled, FALSE) = FALSE AND coalesce(so.status::text, '') <> 'CANCELLED';
    penalty := round(v_max * least(1, (pax_missed + 0.5 * pax_tight) / v_ref), 3);
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
               l.airborne_p50_min AS l50, l.airborne_p90_min AS l90, l.sample_n AS l_n, l.source AS l_src
          FROM alternate_airport aa JOIN airport ap ON ap.iata = aa.alt_iata
          LEFT JOIN LATERAL (SELECT * FROM airport_status_event x
                              WHERE x.scenario_id = p_scenario_id AND x.iata = aa.alt_iata
                                AND x.effective_from_utc <= i.now_utc
                              ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1) st ON TRUE
          LEFT JOIN alternate_history_stats hs ON hs.alt_iata = aa.alt_iata
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
               coalesce(a.parking_available, a.max_parking_stands,
                        CASE WHEN a.h_evidence IN ('STRONG', 'PROVEN') THEN a.h_peak END) - a.occupied AS stands,
               CASE WHEN a.parking_available IS NOT NULL THEN 'LIVE' WHEN a.max_parking_stands IS NOT NULL THEN 'CONFIG'
                    WHEN a.h_evidence IN ('STRONG', 'PROVEN') THEN 'HISTORY' END AS stand_src
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
               least(1, o.historical_diversions / 30.0) AS s_hist
          FROM o
    ), fin AS (
        SELECT sc.*, round(0.30*s_fuel + 0.30*s_crew + 0.15*s_rec + 0.10*s_stand + 0.15*s_hist, 3) AS total
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
                              'weights', '{"fuel":0.30,"crew":0.30,"recovery":0.15,"stands":0.10,"history":0.15}'::jsonb),
           fin.fl90, fin.fl_basis, v_reserve, fin.fuel_basis,
           CASE WHEN fin.fuel_margin IS NULL THEN NULL ELSE i.now_utc + make_interval(mins => fin.fuel_margin) END,
           fin.earliest_dep + make_interval(mins => fin.ret_med)
      FROM fin
     ORDER BY 1;
END $function$;

CREATE OR REPLACE FUNCTION fogops.propose_hold_or_divert(p_scenario_id integer, p_case_id integer, p_flight_id bigint, p_generated_by text DEFAULT 'rules-engine v1'::text, p_approach_min integer DEFAULT 10, p_min_hold_spare_min integer DEFAULT 15)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'fogops', 'public'
AS $function$
DECLARE
    i RECORD; v_rec BIGINT; v_hold_block JSONB := '[]'; v_hold_ok BOOLEAN; v_hold_score NUMERIC := 0;
    v_land TIMESTAMPTZ; v_spare INT; v_hold_crew INT; v_best RECORD; v_conf NUMERIC; v_type rec_type;
    v_rationale TEXT; v_hold_reasons TEXT[] := '{}'; v_ci RECORD; v_ext INT; v_hist_used BOOLEAN := FALSE;
    v_disc_f NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'discretion_score_factor'), 0.85);
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
    -- Connecting passengers lower the score; a hold with the fuel buffer never drops below 1.0 for them (policy above).
    -- If the crew can only do it with commander discretion the hold is flagged, stays executable and is ranked lower.
    SELECT * INTO v_ci FROM connection_impact(p_scenario_id, p_flight_id, v_land);
    v_ext := CASE WHEN v_hold_crew < 0 AND v_land <= i.disc_end_now THEN -v_hold_crew END;
    IF v_hold_ok THEN
        v_hold_score := CASE WHEN v_spare >= p_min_hold_spare_min THEN round(1.0 + least(1, v_spare / 60.0), 3)
                             ELSE 0.2 END;
        v_hold_score := CASE WHEN v_spare >= p_min_hold_spare_min THEN greatest(1.0, v_hold_score - v_ci.penalty)
                             ELSE greatest(0, v_hold_score - v_ci.penalty) END;
        IF v_ext IS NOT NULL THEN v_hold_score := round(v_hold_score * v_disc_f, 3); END IF;
    END IF;
    v_hold_reasons := array_remove(ARRAY[
        CASE WHEN v_land IS NOT NULL THEN format('Landing at %s after forecast reopening (%s)', to_char(v_land AT TIME ZONE 'UTC','HH24:MI"Z"'), i.reopen_quality) END,
        CASE WHEN v_spare IS NOT NULL THEN format('Fuel spare at landing %s min (%s)', v_spare, i.fuel_quality) END,
        CASE WHEN v_hold_crew IS NOT NULL THEN format('Crew margin at landing %s min', v_hold_crew) END,
        CASE WHEN v_ext IS NOT NULL THEN format('Needs commander discretion: about %s min beyond the legal duty (the captain decides)', v_ext) END,
        CASE WHEN v_ci.connections > 0 THEN format('Connections at landing: %s pax miss, %s tight (of %s connecting pax)', v_ci.pax_missed, v_ci.pax_tight, v_ci.pax_total) END,
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
        SELECT 'DIVERT', r.alt_iata, NULL, r.est_arrival_utc, r.fuel_margin_min, r.crew_return_margin_min,
               greatest(0, r.score - ci.penalty),
               r.is_executable, r.blocking_constraints,
               array_remove(r.reasons || ARRAY[CASE WHEN ci.connections > 0
                    THEN format('Connections on return to %s: %s pax miss, %s tight (of %s connecting pax)', i.hub_iata, ci.pax_missed, ci.pax_tight, ci.pax_total) END], NULL)
          FROM rank_alternates(p_scenario_id, p_flight_id) r
          CROSS JOIN LATERAL connection_impact(p_scenario_id, p_flight_id, r.return_arrival_hub_utc) ci
      ) x;

    SELECT * INTO v_best FROM recommendation_option WHERE rec_id = v_rec AND rank = 1;
    -- an option that rests on the station history (no live status) is less certain
    v_hist_used := v_best.action = 'DIVERT' AND EXISTS (SELECT 1 FROM rank_alternates(p_scenario_id, p_flight_id) r
                                                          WHERE r.alt_iata = v_best.alternate_iata AND r.op_status = 'OPEN (history)');
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
        confidence = greatest(0.3, confidence - CASE WHEN v_hist_used THEN 0.10 ELSE 0 END),
        assumptions = jsonb_build_array(
            format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
            format('Hub reopening quality: %s', coalesce(i.reopen_quality, 'none')),
            'Distance to alternates measured from the hub (aircraft assumed in the hub terminal area)',
            'Diversion counts as one extra sector for every operating crew member',
            CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                 THEN format('Flight not yet departed: pre-departure assessment, all times anchored at projected arrival %s (not at the current clock)',
                             to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'))
                 ELSE format('Decision moment %s (%s)', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'), lower(i.flight_phase)) END,
            CASE WHEN v_hist_used THEN 'Alternate availability and stands come from the supplied flight history (no live status); a station entry overrides them'
                 ELSE 'Alternate status/parking taken from the latest airport_status_event, else from the supplied history' END,
            format('Hold preferred when feasible with >= %s min fuel spare at landing', p_min_hold_spare_min)),
        uncertainty = jsonb_build_object('reopening_utc', i.reopen_utc, 'reopening_quality', i.reopen_quality,
                                         'endurance_left_min', i.endurance_left_min)
     WHERE rec_id = v_rec;
    RETURN v_rec;
END $function$;

CREATE OR REPLACE FUNCTION fogops.recommend_for_flight(p_scenario_id integer, p_case_id integer, p_flight_id bigint, p_generated_by text DEFAULT 'rules-engine v2'::text, p_decision_window_min integer DEFAULT 90, p_approach_min integer DEFAULT 10)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'fogops', 'public'
AS $function$
DECLARE
    i RECORD; f flight%ROWTYPE; s flight_state%ROWTYPE; dv RECORD; ld RECORD;
    v_now TIMESTAMPTZ; v_eta TIMESTAMPTZ; v_hub TEXT; v_restricted BOOLEAN; v_crew_margin INT; v_endur INT;
    v_block INT; v_land TIMESTAMPTZ; v_new_etd TIMESTAMPTZ; v_delay INT; v_mins INT; v_watch TEXT[] := '{}';
    v_snap JSONB; v_ass JSONB; v_why TEXT; v_ci RECORD; v_over INT; v_crewtxt TEXT; v_dscore NUMERIC; v_opts JSONB;
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
            -- crew time at the delayed arrival, and whether commander discretion could cover it
            SELECT * INTO v_ci FROM connection_impact(p_scenario_id, p_flight_id, v_land);
            v_over := CASE WHEN i.crew_known THEN ceil(extract(epoch FROM v_land - i.legal_end_now) / 60)::int END;
            v_crewtxt := CASE
                WHEN NOT i.crew_known THEN 'Crew legality is unverified: check the duty before agreeing the delay.'
                WHEN v_over <= 0 THEN format('Crew is legal at the delayed arrival (%s h %s min spare).', (-v_over) / 60, (-v_over) % 60)
                WHEN v_land <= i.disc_end_now THEN format('The delayed arrival is %s h %s min past the crew''s legal end of duty (within commander discretion): re-time the sign-in or replace the crew.', v_over / 60, v_over % 60)
                ELSE format('The delayed arrival is %s h %s min past the crew''s legal end of duty, beyond commander discretion: re-time the sign-in or replace the crew.', v_over / 60, v_over % 60) END;
            v_dscore := CASE WHEN NOT i.crew_known THEN 0.8 WHEN v_over <= 0 THEN 1.0 WHEN v_land <= i.disc_end_now THEN 0.85 ELSE 0.6 END;
            v_dscore := greatest(0.1, v_dscore - v_ci.penalty);
            v_opts := jsonb_build_array(jsonb_build_object('action', 'DELAY_DEPARTURE', 'score', v_dscore,
                    'reasons', jsonb_build_array(format('New departure about %s', to_char(v_new_etd AT TIME ZONE 'UTC', 'HH24:MI"Z"')),
                                                 format('Avoids about %s min of airborne holding', v_delay),
                                                 format('%s forecast to reopen %s (%s)', v_hub, to_char(i.reopen_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), coalesce(i.reopen_quality, 'none')),
                                                 v_crewtxt,
                                                 CASE WHEN v_ci.connections > 0 THEN format('Connections at the delayed arrival: %s pax miss, %s tight (of %s connecting pax)', v_ci.pax_missed, v_ci.pax_tight, v_ci.pax_total)
                                                      ELSE 'No connecting passengers on record for this flight' END)));
            IF v_over > 0 THEN
                v_opts := v_opts || jsonb_build_array(jsonb_build_object('action', 'CREW_REPLACE', 'score', 0.8,
                    'reasons', jsonb_build_array(v_crewtxt, 'Use the replacement finder: legal, LVP-qualified and roster-safe standby crew')));
            END IF;
            RETURN _insert_recommendation(p_scenario_id, p_case_id, p_flight_id, 'DELAY_DEPARTURE',
                CASE WHEN NOT i.crew_known OR v_over > 0 THEN 0.6 ELSE 0.75 END,
                format('DELAY DEPARTURE by about %s min to %s so it lands after %s reopens (%s) instead of holding in the air. %s', v_delay,
                       to_char(v_new_etd AT TIME ZONE 'UTC', 'HH24:MI"Z"'), v_hub, to_char(v_land AT TIME ZONE 'UTC', 'HH24:MI"Z"'), v_crewtxt),
                v_ass, v_snap, p_generated_by, v_opts);
        END IF;
    END IF;
    -- Nothing to recommend now (landed, or the destination is no longer restricted): a proposal made under an earlier situation,
    -- such as DELAY_DEPARTURE written while the hub was closed, must not stay on the board as if it still held.
    UPDATE recommendation SET status = 'EXPIRED'
     WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id AND status = 'PROPOSED';
    RETURN NULL;
END $function$;


-- Re-run the recommendations of the live scenarios with the new factors.
SELECT enqueue_reassessment(scenario_id, 'migration 015: recommendation factors', 'airport', 'SHJ') FROM scenario WHERE kind = 'LIVE' AND is_active;
