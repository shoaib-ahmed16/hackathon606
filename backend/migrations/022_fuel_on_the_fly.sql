-- 022: fuel worked out on the fly, so recommendations can follow it.
--
--   fuel now = fuel at take-off - burn per minute x minutes since take-off      (cruise rate, then the hold rate once holding)
--
-- It is calculated when it is read, from the stored take-off fuel, the burn model and the scenario clock; nothing is rewritten every minute.
--  * fuel at take-off: a person's entry (MEASURED / MANUAL) always wins; otherwise the CAUTIOUS history figure, the 25th percentile of the
--    departure fuel on that route (fuel_departure_stats, scaled by the aircraft's own factor), less taxi-out fuel and the climb share of the fixed burn. Live data has no fuel
--    at take-off: only the history does.
--  * burn per minute: fitted by least squares from 60,060 historical flights (scripts/fit_fuel_burn.py):
--        trip fuel = 924 kg + 38.78 kg x airborne min + 17.5 kg x taxi-out min + 11.3 kg x taxi-in min   (R2 0.917)
--    scaled by each aircraft's own factor (69 aircraft, 0.82 to 1.18). With the take-off fuel known the model is off by a median of 437 kg
--    and by 1,021 kg at the 90th percentile (about 26 min of holding). The HOLDING burn is not in the history: 2,400 kg/h is ASSUMED
--    (the fitted marginal burn, 2,327 kg/h, supports it).
--  * flight_decision_inputs() (deadlines, engine) and rank_alternates() read fuel_now(); GET /fuel returns it.
--  * the scenario clock is the team's (migration 019_scenario_clock: paused by default, or running); fuel_now() simply reads scenario_now().

SET search_path = fogops, hist, public;

INSERT INTO divert_policy (key, value, unit, basis) VALUES
  ('hold_burn_kg_per_hr',    2400, 'kg/h',  'ASSUMED: fuel burn while holding. Not in the history; the fitted marginal burn per airborne hour is 2327 kg/h.'),
  ('fuel_takeoff_percentile', 0.25, 'ratio', 'Which percentile of the route''s historical departure fuel is assumed when no fuel at take-off was entered: 0.25 (cautious), 0.5 or 0.75.'),
  ('fuel_min_samples',        10,   'flights','Historical flights needed on a route (then its destination) before its departure fuel is used; otherwise the next wider group.')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, basis = EXCLUDED.basis, updated_at = now();

CREATE TABLE IF NOT EXISTS fuel_burn_model (
    model_id              TEXT PRIMARY KEY,
    a_fixed_kg            NUMERIC NOT NULL,   -- burn that does not scale with airborne time (climb, approach)
    b_kg_per_min          NUMERIC NOT NULL,   -- burn per airborne minute (fleet)
    taxi_out_kg_per_min   NUMERIC NOT NULL,
    taxi_in_kg_per_min    NUMERIC NOT NULL,
    climb_share           NUMERIC NOT NULL,   -- ASSUMED: share of the fixed burn spent before the cruise (the rest is approach)
    taxi_out_median_min   NUMERIC NOT NULL,
    taxi_in_median_min    NUMERIC NOT NULL,
    n_flights             INT NOT NULL,
    r2                    NUMERIC,
    basis                 TEXT NOT NULL,
    fitted_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
TRUNCATE fuel_burn_model;
INSERT INTO fuel_burn_model (model_id, a_fixed_kg, b_kg_per_min, taxi_out_kg_per_min, taxi_in_kg_per_min, climb_share,
                             taxi_out_median_min, taxi_in_median_min, n_flights, r2, basis)
VALUES ('FLEET', 924.2, 38.776, 17.5, 11.3, 0.5, 14, 6, 60060, 0.917,
        'Least squares on historical flights (hist.fuel joined to hist.flight, airborne 15-600 min, not diverted); scripts/fit_fuel_burn.py. climb_share is ASSUMED.');

CREATE TABLE IF NOT EXISTS aircraft_burn_factor (
    registration TEXT PRIMARY KEY,
    factor       NUMERIC NOT NULL        -- this aircraft's airborne burn relative to the fleet (aircraft with 50+ flights only)
);
TRUNCATE aircraft_burn_factor;
INSERT INTO aircraft_burn_factor (registration, factor) VALUES
  ('9H-MLY', 1.051),
  ('9H-SWJ', 1.068),
  ('A6-ABM', 1.039),
  ('A6-ANA', 1.042),
  ('A6-ANB', 1.036),
  ('A6-ANE', 1.027),
  ('A6-ANL', 1.066),
  ('A6-ANM', 1.019),
  ('A6-ANO', 1.038),
  ('A6-ANP', 1.021),
  ('A6-ANQ', 1.009),
  ('A6-ANR', 1.015),
  ('A6-ANS', 1.018),
  ('A6-ANT', 1.023),
  ('A6-ANY', 1.025),
  ('A6-AOA', 1.013),
  ('A6-AOB', 1.02),
  ('A6-AOC', 1.022),
  ('A6-AOE', 1.03),
  ('A6-AOH', 1.015),
  ('A6-AOI', 1.02),
  ('A6-AOJ', 1.035),
  ('A6-AOK', 1.025),
  ('A6-AOM', 1.038),
  ('A6-AON', 1.026),
  ('A6-AOO', 1.034),
  ('A6-AOP', 1.035),
  ('A6-AOQ', 1.031),
  ('A6-AOR', 1.014),
  ('A6-AOS', 1.012),
  ('A6-AOT', 1.036),
  ('A6-AOU', 1.024),
  ('A6-AOV', 1.034),
  ('A6-AOW', 1.03),
  ('A6-AOX', 1.03),
  ('A6-AQF', 1.016),
  ('A6-AQG', 1.039),
  ('A6-AQH', 1.031),
  ('A6-AQJ', 0.999),
  ('A6-AQL', 1.02),
  ('A6-AQM', 0.989),
  ('A6-AQN', 1.009),
  ('A6-AQP', 0.999),
  ('A6-AQQ', 0.987),
  ('A6-AQT', 0.973),
  ('A6-AQU', 0.976),
  ('A6-ARA', 0.843),
  ('A6-ARB', 0.833),
  ('A6-ARC', 0.833),
  ('A6-ARD', 0.831),
  ('A6-ARE', 0.835),
  ('A6-ARF', 0.834),
  ('A6-ARG', 0.828),
  ('A6-ARH', 0.828),
  ('A6-ARI', 0.841),
  ('A6-ARJ', 0.835),
  ('A6-ARL', 0.836),
  ('A6-ARM', 0.829),
  ('A6-ARN', 0.823),
  ('A6-ARO', 0.835),
  ('A6-ATA', 1.058),
  ('A6-ATB', 1.059),
  ('A6-ATC', 1.065),
  ('A6-ATD', 1.049),
  ('A6-ATE', 1.048),
  ('A6-ATF', 1.043),
  ('A6-ATG', 1.18),
  ('A6-ATH', 1.182),
  ('A6-ATI', 1.156);

CREATE TABLE IF NOT EXISTS fuel_departure_stats (
    scope       TEXT NOT NULL CHECK (scope IN ('ROUTE', 'DEST', 'ALL')),
    origin_iata TEXT,
    dest_iata   TEXT,
    n           INT NOT NULL,
    p25         INT NOT NULL,
    p50         INT NOT NULL,
    p75         INT NOT NULL,
    built_from  TEXT NOT NULL DEFAULT 'Historical_fuel_data.xlsx (hist.fuel, plausible rows), fleet-equivalent kg',
    built_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_fuel_departure_stats ON fuel_departure_stats (scope, coalesce(origin_iata, ''), coalesce(dest_iata, ''));
TRUNCATE fuel_departure_stats;
-- departure fuel in FLEET-EQUIVALENT kg: each flight's departure fuel divided by its aircraft's factor, because a lighter aircraft
-- carries proportionally less fuel as well as burning less. The estimate multiplies it back by the aircraft's own factor.
CREATE TEMP TABLE _dep ON COMMIT DROP AS
SELECT trim(fu.origin_iata) AS o, trim(fu.destination_iata) AS d, fu.fuel_onboard_departure / coalesce(a.factor, 1) AS fob
  FROM hist.fuel fu LEFT JOIN aircraft_burn_factor a ON a.registration = fu.registration
 WHERE fu.is_plausible AND fu.fuel_onboard_departure BETWEEN 1000 AND 30000;
INSERT INTO fuel_departure_stats (scope, origin_iata, dest_iata, n, p25, p50, p75)
SELECT 'ROUTE', o, d, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY fob)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fob)),
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY fob)) FROM _dep GROUP BY o, d
UNION ALL
SELECT 'DEST', NULL, d, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY fob)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fob)),
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY fob)) FROM _dep GROUP BY d
UNION ALL
SELECT 'ALL', NULL, NULL, count(*), round(percentile_cont(0.25) WITHIN GROUP (ORDER BY fob)), round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fob)),
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY fob)) FROM _dep;

-- ---------------------------------------------------------------------------------------------------------------------
-- fuel_now(): the fuel of a flight in the air at a given moment, worked out from the take-off fuel and the burn per minute.
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fuel_now(p_scenario_id INT, p_flight_id BIGINT, p_at TIMESTAMPTZ)
RETURNS TABLE (at_utc TIMESTAMPTZ, fuel_kg INT, endurance_min INT, endurance_until TIMESTAMPTZ, hold_burn_kg_hr INT,
               quality TEXT, anchor_kind TEXT, anchor_utc TIMESTAMPTZ, phase TEXT, basis JSONB)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    s flight_state%ROWTYPE; f flight%ROWTYPE; e flight_fuel_estimate%ROWTYPE; m fuel_burn_model%ROWTYPE;
    v_hold NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'hold_burn_kg_per_hr'), 2400) / 60.0;   -- kg per minute
    v_res_min NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'final_reserve_min'), 30);
    v_fac NUMERIC; v_cruise NUMERIC; v_hs TIMESTAMPTZ; v_cmin NUMERIC; v_hmin NUMERIC; v_fuel NUMERIC; v_eta TIMESTAMPTZ;
    v_mtg NUMERIC; v_after NUMERIC; v_land NUMERIC; v_mins NUMERIC; v_until TIMESTAMPTZ; v_phase TEXT;
BEGIN
    SELECT * INTO s FROM flight_state x WHERE x.scenario_id = p_scenario_id AND x.flight_id = p_flight_id;
    IF s.flight_id IS NULL OR s.status::text NOT IN ('AIRBORNE', 'HOLDING', 'DIVERTING') THEN RETURN; END IF;   -- no figure on the ground
    SELECT * INTO f FROM flight x WHERE x.flight_id = p_flight_id;
    -- a person's entry first, then the take-off based estimate, then older estimates; the latest of each kind
    SELECT * INTO e FROM flight_fuel_estimate x
     WHERE x.scenario_id = p_scenario_id AND x.flight_id = p_flight_id AND x.as_of_utc <= p_at
     ORDER BY CASE WHEN x.quality IN ('MEASURED', 'MANUAL', 'FORECAST') THEN 0 WHEN x.basis->>'anchor' = 'TAKEOFF' THEN 1 ELSE 2 END,
              x.as_of_utc DESC, x.estimate_id DESC LIMIT 1;
    IF e.estimate_id IS NULL THEN RETURN; END IF;
    v_phase := CASE s.status::text WHEN 'HOLDING' THEN 'HOLDING' WHEN 'DIVERTING' THEN 'DIVERTING' ELSE 'CRUISE' END;
    at_utc := p_at; phase := v_phase; quality := e.quality::text; anchor_utc := e.as_of_utc; hold_burn_kg_hr := round(v_hold * 60)::int;

    IF e.fuel_on_board_kg IS NULL THEN   -- a reported endurance only: the fuel runs down to reserve at the moment it was reported to last
        v_until := e.as_of_utc + make_interval(mins => e.est_holding_endurance_min);
        fuel_kg := NULL; endurance_until := v_until; anchor_kind := 'ENDURANCE_ONLY';
        endurance_min := greatest(0, floor(extract(epoch FROM v_until - p_at) / 60))::int;
        basis := e.basis || jsonb_build_object('text', format('Holding endurance %s min reported at %s UTC', e.est_holding_endurance_min, to_char(e.as_of_utc AT TIME ZONE 'UTC', 'DD HH24:MI')));
        RETURN NEXT; RETURN;
    END IF;

    SELECT * INTO m FROM fuel_burn_model x WHERE x.model_id = 'FLEET';
    v_fac := coalesce((SELECT a.factor FROM aircraft_burn_factor a WHERE a.registration = coalesce(s.registration, f.registration_planned)), 1);
    v_cruise := coalesce(m.b_kg_per_min, 38.8) * v_fac;
    v_hs := CASE WHEN s.status::text = 'HOLDING' OR s.is_holding THEN s.holding_since_utc END;
    v_cmin := greatest(0, extract(epoch FROM (least(p_at, coalesce(v_hs, p_at)) - e.as_of_utc)) / 60);
    v_hmin := CASE WHEN v_hs IS NOT NULL AND p_at > v_hs THEN extract(epoch FROM (p_at - greatest(v_hs, e.as_of_utc))) / 60 ELSE 0 END;
    v_fuel := e.fuel_on_board_kg - v_cruise * v_cmin - v_hold * v_hmin;

    -- how long the fuel lasts: to the hub (cruise), approach and landing, then holding down to the final reserve
    v_eta := coalesce(s.eta_utc, f.sta_utc);
    v_mtg := CASE WHEN v_phase = 'HOLDING' THEN 0 ELSE greatest(0, extract(epoch FROM (v_eta - p_at)) / 60) END;
    v_after := coalesce(m.a_fixed_kg * (1 - m.climb_share) + m.taxi_in_kg_per_min * m.taxi_in_median_min, 0);
    v_land := v_fuel - v_cruise * v_mtg - v_after;
    v_mins := v_mtg + (v_land - v_res_min * v_hold) / v_hold;
    v_until := p_at + make_interval(secs => (greatest(0, v_mins) * 60)::double precision);

    fuel_kg := round(v_fuel)::int; endurance_until := v_until; endurance_min := greatest(0, floor(v_mins))::int;
    anchor_kind := CASE WHEN e.quality IN ('MEASURED', 'MANUAL', 'FORECAST') THEN 'ENTERED' WHEN e.basis->>'anchor' = 'TAKEOFF' THEN 'TAKEOFF' ELSE 'LEGACY' END;
    basis := e.basis || jsonb_build_object(
        'cruise_kg_per_min', round(v_cruise, 1), 'aircraft_factor', v_fac, 'hold_kg_per_min', round(v_hold, 1),
        'cruise_min', round(v_cmin), 'hold_min', round(v_hmin), 'kg_after_arrival_fixed', round(v_after), 'minutes_to_hub', round(v_mtg),
        'text', format('%s kg %s at %s UTC; minus %s min x %s kg/min%s = %s kg now',
                       e.fuel_on_board_kg, CASE WHEN e.basis->>'anchor' = 'TAKEOFF' THEN 'at take-off' ELSE 'as entered' END,
                       to_char(e.as_of_utc AT TIME ZONE 'UTC', 'DD HH24:MI'), round(v_cmin), round(v_cruise, 1),
                       CASE WHEN v_hmin > 0 THEN format(' and %s min holding x %s kg/min', round(v_hmin), round(v_hold, 1)) ELSE '' END, round(v_fuel)));
    RETURN NEXT;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- The estimator: ONE row per flight in the air, the fuel at take-off (cautious history figure). Everything after it is derived.
-- ---------------------------------------------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS estimate_airborne_fuel(integer, integer, integer, integer);
CREATE OR REPLACE FUNCTION estimate_airborne_fuel(p_scenario_id INT) RETURNS INT LANGUAGE plpgsql SET search_path = fogops, public AS $$
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    m fuel_burn_model%ROWTYPE; r RECORD; st RECORD;
    v_pct NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'fuel_takeoff_percentile'), 0.25);
    v_min INT := coalesce((SELECT value FROM divert_policy WHERE key = 'fuel_min_samples'), 10)::int;
    v_hold NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'hold_burn_kg_per_hr'), 2400);
    v_res NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'final_reserve_min'), 30);
    v_dep INT; v_fleet INT; v_fac NUMERIC; v_tout NUMERIC; v_anchor INT; v_done INT := 0;
BEGIN
    SELECT * INTO m FROM fuel_burn_model x WHERE x.model_id = 'FLEET';
    IF m.model_id IS NULL THEN RETURN 0; END IF;
    FOR r IN
        SELECT f.flight_id, trim(f.dep_iata) AS o, trim(f.arr_iata) AS d, s.toff_utc, s.atd_utc, coalesce(s.registration, f.registration_planned) AS reg
          FROM flight_state s JOIN flight f ON f.flight_id = s.flight_id
         WHERE s.scenario_id = p_scenario_id AND s.status IN ('AIRBORNE', 'HOLDING', 'DIVERTING')
           AND s.toff_utc IS NOT NULL AND s.toff_utc <= v_now
           AND NOT EXISTS (SELECT 1 FROM flight_fuel_estimate e WHERE e.scenario_id = p_scenario_id AND e.flight_id = f.flight_id
                              AND (e.quality IN ('MEASURED', 'MANUAL', 'FORECAST') OR e.basis->>'anchor' = 'TAKEOFF'))
    LOOP
        SELECT * INTO st FROM (
            SELECT 1 AS pri, * FROM fuel_departure_stats WHERE scope = 'ROUTE' AND origin_iata = r.o AND dest_iata = r.d AND n >= v_min
            UNION ALL SELECT 2, * FROM fuel_departure_stats WHERE scope = 'DEST' AND dest_iata = r.d AND n >= v_min
            UNION ALL SELECT 3, * FROM fuel_departure_stats WHERE scope = 'ALL') x ORDER BY pri LIMIT 1;
        CONTINUE WHEN st.scope IS NULL;
        v_fleet := CASE WHEN v_pct >= 0.7 THEN st.p75 WHEN v_pct >= 0.4 THEN st.p50 ELSE st.p25 END;
        v_fac := coalesce((SELECT a.factor FROM aircraft_burn_factor a WHERE a.registration = r.reg), 1);
        v_dep := round(v_fleet * v_fac);   -- this aircraft carries, like it burns, in proportion to its factor
        v_tout := CASE WHEN r.atd_utc IS NOT NULL AND r.toff_utc > r.atd_utc THEN least(60, extract(epoch FROM (r.toff_utc - r.atd_utc)) / 60) ELSE m.taxi_out_median_min END;
        v_anchor := round(v_dep - m.taxi_out_kg_per_min * v_tout - m.a_fixed_kg * m.climb_share);
        INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg, burn_rate_hold_kg_per_hr,
                                          est_holding_endurance_min, quality, basis)
        VALUES (p_scenario_id, r.flight_id, r.toff_utc, v_anchor, round(v_res * v_hold / 60), v_hold, NULL, 'ESTIMATED',
                jsonb_build_object('anchor', 'TAKEOFF', 'method', 'fuel at take-off from route history, then burn per minute since take-off',
                                   'source', 'Historical_fuel_data.xlsx', 'percentile', CASE WHEN v_pct >= 0.7 THEN 0.75 WHEN v_pct >= 0.4 THEN 0.5 ELSE 0.25 END,
                                   'stats_scope', st.scope, 'route', r.o || '-' || r.d, 'samples', st.n, 'fleet_departure_fuel_kg', v_fleet, 'aircraft_factor', v_fac, 'departure_fuel_kg', v_dep,
                                   'taxi_out_min', round(v_tout, 1), 'taxi_out_kg', round(m.taxi_out_kg_per_min * v_tout),
                                   'climb_kg', round(m.a_fixed_kg * m.climb_share)));
        PERFORM enqueue_reassessment(p_scenario_id, 'fuel estimated', 'flight', r.flight_id::text);
        v_done := v_done + 1;
    END LOOP;
    RETURN v_done;
END $$;

CREATE OR REPLACE FUNCTION fogops.flight_decision_inputs(p_scenario_id integer, p_flight_id bigint)
 RETURNS TABLE(hub_iata character, now_utc timestamp with time zone, endurance_left_min integer, fuel_quality text, hub_status text, hub_lvp boolean, reopen_utc timestamp with time zone, reopen_quality text, cockpit_all_lvp boolean, crew_known boolean, legal_end_now timestamp with time zone, disc_end_now timestamp with time zone, legal_end_if_diverted timestamp with time zone, disc_end_if_diverted timestamp with time zone, flight_phase text, anchor_utc timestamp with time zone, endurance_until timestamp with time zone, earliest_sign_in timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fogops', 'public'
AS $function$
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
    -- fuel now is worked out from the fuel at take-off and the burn per minute (fuel_now), at the scenario clock
    SELECT fn.endurance_until AS until, fn.quality AS q
      INTO e FROM fuel_now(p_scenario_id, p_flight_id, v_now) fn;
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
END $function$;

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

    -- fuel on board NOW (take-off fuel minus the burn since), and the same expressed as minutes of holding
    SELECT fn.fuel_kg, fn.hold_burn_kg_hr, (fn.fuel_kg::numeric / nullif(fn.hold_burn_kg_hr, 0) * 60)
      INTO v_fob, v_burn, v_fuel_min
      FROM fuel_now(p_scenario_id, p_flight_id, i.now_utc) fn
     WHERE fn.fuel_kg IS NOT NULL;

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
                  LEFT JOIN decision dd ON dd.decision_id = dv.decision_id
                 WHERE dv.scenario_id = p_scenario_id AND dv.alternate_iata = aa.alt_iata
                   AND dv.original_flight_id <> p_flight_id
                   AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED')
                   -- a live stand count already includes aircraft that landed before it was entered
                   AND (st.parking_available IS NULL
                        OR coalesce(dd.executed_at, dv.landed_alt_utc, dv.updated_at) >= st.effective_from_utc))::int AS occupied,
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


-- Give every flight in the air its take-off fuel row now (live and replay scenarios), and recompute what depended on the old figure.
SELECT estimate_airborne_fuel(scenario_id) FROM scenario WHERE is_active;
SELECT enqueue_reassessment(scenario_id, 'migration 022: fuel on the fly', 'airport', 'SHJ') FROM scenario WHERE is_active;
