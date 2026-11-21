-- 024: fuel_now() learns each route's own burn.
-- The fleet-wide model over- or under-states the trip fuel of a given route (median 296 kg, up to 1,374 kg). For routes with 30+ historical
-- flights (184 routes, 99% of the flights) the average error is stored and taken back as a fixed amount that builds up over the route's usual airborne minutes and stops there.
-- Tested on history the model was not fitted on: median error 436 kg -> 274 kg, 90th percentile 1,021 kg -> 836 kg.
-- Routes with fewer flights keep the fleet model. Values come from scripts/fit_fuel_burn.py.
SET search_path = fogops, hist, public;

CREATE TABLE IF NOT EXISTS fuel_route_adjust (
    origin_iata TEXT NOT NULL,
    dest_iata   TEXT NOT NULL,
    n           INT  NOT NULL,
    bias_kg     NUMERIC NOT NULL,      -- mean (model trip fuel - actual trip fuel) on this route: positive = the model burns too much
    air_min     NUMERIC NOT NULL,      -- median airborne minutes of those flights
    PRIMARY KEY (origin_iata, dest_iata)
);
TRUNCATE fuel_route_adjust;
INSERT INTO fuel_route_adjust (origin_iata, dest_iata, n, bias_kg, air_min) VALUES
  ('ADD', 'SHJ', 291, 162, 232),
  ('AHB', 'SHJ', 164, 441, 140),
  ('AJF', 'SHJ', 98, 337, 130),
  ('ALA', 'SHJ', 282, 282, 262),
  ('ALP', 'SHJ', 123, 459, 180),
  ('ALY', 'SHJ', 144, -110, 200),
  ('AMD', 'SHJ', 311, -140, 146),
  ('AMM', 'SHJ', 706, 505, 163),
  ('ATH', 'SHJ', 311, 411, 256),
  ('ATZ', 'SHJ', 37, 327, 176),
  ('BAH', 'SHJ', 677, 470, 54),
  ('BEY', 'SHJ', 327, 461, 179),
  ('BGW', 'SHJ', 384, 280, 154),
  ('BGY', 'SHJ', 238, -113, 342),
  ('BKK', 'SHJ', 733, -937, 370),
  ('BLR', 'SHJ', 295, -404, 210),
  ('BOM', 'SHJ', 618, -89, 154),
  ('BSR', 'SHJ', 101, 374, 169),
  ('BSZ', 'SHJ', 128, 38, 248),
  ('CAI', 'RKT', 212, 465, 192),
  ('CAI', 'SHJ', 1152, 184, 187),
  ('CCJ', 'RKT', 122, -587, 216),
  ('CCJ', 'SHJ', 311, -656, 208),
  ('CGP', 'SHJ', 566, -696, 289),
  ('CJB', 'SHJ', 225, -532, 218),
  ('CMB', 'SHJ', 699, -276, 249),
  ('COK', 'SHJ', 626, -647, 215),
  ('DAC', 'SHJ', 1284, -570, 282),
  ('DAM', 'SHJ', 556, 483, 166),
  ('DEL', 'SHJ', 614, -184, 189),
  ('DME', 'SHJ', 253, 7, 308),
  ('DMM', 'SHJ', 738, 390, 61),
  ('DOH', 'SHJ', 989, 557, 46),
  ('EBB', 'SHJ', 110, -589, 306),
  ('EBL', 'SHJ', 238, 475, 173),
  ('ELQ', 'SHJ', 312, 354, 102),
  ('EVN', 'SHJ', 315, 484, 211),
  ('FCO', 'SHJ', 110, 51, 324),
  ('GIZ', 'SHJ', 56, 300, 147),
  ('GOX', 'SHJ', 224, 78, 173),
  ('GYD', 'SHJ', 309, 310, 215),
  ('HAS', 'SHJ', 107, 443, 117),
  ('HBE', 'SHJ', 280, 535, 208),
  ('HKT', 'SHJ', 621, -377, 367),
  ('HMB', 'SHJ', 174, 273, 187),
  ('HYD', 'SHJ', 308, -397, 202),
  ('IKA', 'SHJ', 42, 830, 103),
  ('ISB', 'RKT', 81, 57, 171),
  ('IST', 'SHJ', 397, 65, 245),
  ('JAI', 'SHJ', 308, -414, 181),
  ('JED', 'SHJ', 750, 221, 146),
  ('KBV', 'SHJ', 57, -63, 395),
  ('KHI', 'SHJ', 787, 314, 104),
  ('KRK', 'SHJ', 233, 26, 318),
  ('KTM', 'SHJ', 817, 55, 252),
  ('KUL', 'SHJ', 194, -1019, 400),
  ('KWI', 'SHJ', 226, 448, 77),
  ('KZN', 'SHJ', 74, 286, 271),
  ('LGW', 'SHJ', 243, -6, 402),
  ('LHE', 'RKT', 118, 46, 178),
  ('LYP', 'SHJ', 279, 122, 168),
  ('MAA', 'SHJ', 309, -682, 226),
  ('MCT', 'SHJ', 397, 586, 39),
  ('MED', 'SHJ', 432, 349, 132),
  ('MHD', 'SHJ', 45, 488, 117),
  ('MLE', 'SHJ', 372, 507, 240),
  ('MUC', 'SHJ', 191, 229, 340),
  ('MUX', 'SHJ', 311, 1, 152),
  ('NAG', 'SHJ', 86, -100, 197),
  ('NBO', 'SHJ', 341, -516, 286),
  ('NJF', 'SHJ', 87, 563, 128),
  ('PEW', 'RKT', 119, 3, 169),
  ('PEW', 'SHJ', 288, -196, 167),
  ('PRG', 'SHJ', 163, 38, 335),
  ('RKT', 'CAI', 208, -183, 211),
  ('RKT', 'CCJ', 123, 203, 202),
  ('RKT', 'ISB', 85, -47, 160),
  ('RKT', 'LHE', 125, 231, 160),
  ('RKT', 'PEW', 129, -7, 157),
  ('RKT', 'RKT', 31, 999, 94),
  ('RUH', 'SHJ', 510, 495, 92),
  ('SAW', 'SHJ', 294, 60, 239),
  ('SHJ', 'ADD', 294, -300, 230),
  ('SHJ', 'AHB', 176, 17, 144),
  ('SHJ', 'AJF', 130, 145, 142),
  ('SHJ', 'ALA', 298, -299, 242),
  ('SHJ', 'ALP', 129, -268, 184),
  ('SHJ', 'ALY', 149, 38, 207),
  ('SHJ', 'AMD', 308, 151, 138),
  ('SHJ', 'AMM', 767, -219, 177),
  ('SHJ', 'ATH', 316, -100, 291),
  ('SHJ', 'ATZ', 37, -991, 227),
  ('SHJ', 'BAH', 836, 467, 54),
  ('SHJ', 'BEY', 347, -278, 185),
  ('SHJ', 'BGW', 414, -36, 135),
  ('SHJ', 'BGY', 236, -5, 384),
  ('SHJ', 'BKK', 703, -211, 360),
  ('SHJ', 'BLR', 290, -256, 205),
  ('SHJ', 'BOM', 620, 198, 163),
  ('SHJ', 'BSR', 117, 164, 136),
  ('SHJ', 'BSZ', 130, -285, 227),
  ('SHJ', 'CAI', 1165, -542, 211),
  ('SHJ', 'CCJ', 313, -428, 204),
  ('SHJ', 'CGP', 564, -307, 274),
  ('SHJ', 'CJB', 222, -149, 214),
  ('SHJ', 'CMB', 699, -252, 250),
  ('SHJ', 'COK', 629, -308, 214),
  ('SHJ', 'DAC', 1275, -241, 258),
  ('SHJ', 'DAM', 630, -232, 176),
  ('SHJ', 'DEL', 623, -9, 174),
  ('SHJ', 'DME', 280, -432, 318),
  ('SHJ', 'DMM', 845, 434, 64),
  ('SHJ', 'DOH', 1294, 571, 45),
  ('SHJ', 'EBB', 112, -682, 307),
  ('SHJ', 'EBL', 269, -111, 159),
  ('SHJ', 'ELQ', 380, 312, 106),
  ('SHJ', 'EVN', 314, -241, 197),
  ('SHJ', 'FCO', 109, 506, 358),
  ('SHJ', 'GIZ', 56, 34, 160),
  ('SHJ', 'GOX', 217, 83, 173),
  ('SHJ', 'GYD', 313, -146, 221),
  ('SHJ', 'HAS', 137, 253, 123),
  ('SHJ', 'HBE', 288, -611, 224),
  ('SHJ', 'HKT', 614, -318, 374),
  ('SHJ', 'HMB', 170, -298, 195),
  ('SHJ', 'HYD', 307, -314, 191),
  ('SHJ', 'IKA', 43, 562, 110),
  ('SHJ', 'IST', 409, -283, 273),
  ('SHJ', 'JAI', 309, -196, 164),
  ('SHJ', 'JED', 755, 193, 157),
  ('SHJ', 'KBV', 58, 319, 358),
  ('SHJ', 'KHI', 856, 430, 100),
  ('SHJ', 'KRK', 230, -152, 346),
  ('SHJ', 'KTM', 826, -367, 230),
  ('SHJ', 'KUL', 179, -1051, 405),
  ('SHJ', 'KWI', 265, 473, 83),
  ('SHJ', 'KZN', 80, -397, 276),
  ('SHJ', 'LGW', 179, 1374, 441),
  ('SHJ', 'LYP', 283, -1, 151),
  ('SHJ', 'MAA', 308, -418, 219),
  ('SHJ', 'MCT', 495, 630, 41),
  ('SHJ', 'MED', 446, 252, 142),
  ('SHJ', 'MHD', 47, 740, 109),
  ('SHJ', 'MLE', 373, -114, 244),
  ('SHJ', 'MUC', 190, 56, 374),
  ('SHJ', 'MUX', 309, 48, 137),
  ('SHJ', 'NAG', 85, 53, 187),
  ('SHJ', 'NBO', 341, -38, 287),
  ('SHJ', 'NJF', 118, 412, 124),
  ('SHJ', 'PEW', 293, -93, 155),
  ('SHJ', 'PRG', 168, -30, 371),
  ('SHJ', 'RKT', 30, 985, 16),
  ('SHJ', 'RUH', 527, 320, 103),
  ('SHJ', 'SAW', 298, -168, 265),
  ('SHJ', 'SKT', 296, -221, 163),
  ('SHJ', 'SLL', 332, 406, 87),
  ('SHJ', 'SVX', 91, -399, 275),
  ('SHJ', 'SYZ', 41, 724, 59),
  ('SHJ', 'TAS', 320, -164, 220),
  ('SHJ', 'TBS', 423, -226, 205),
  ('SHJ', 'TIF', 155, -50, 142),
  ('SHJ', 'TRV', 627, -462, 228),
  ('SHJ', 'TUU', 175, 113, 163),
  ('SHJ', 'TZX', 110, 350, 210),
  ('SHJ', 'UET', 114, 335, 116),
  ('SHJ', 'UFA', 41, -510, 264),
  ('SHJ', 'VIE', 188, -25, 353),
  ('SHJ', 'WAW', 221, -5, 358),
  ('SHJ', 'WMI', 57, -299, 374),
  ('SKT', 'SHJ', 292, -293, 180),
  ('SLL', 'SHJ', 230, 276, 90),
  ('SVX', 'SHJ', 90, 519, 287),
  ('SYZ', 'SHJ', 37, 641, 58),
  ('TAS', 'SHJ', 324, 442, 230),
  ('TBS', 'SHJ', 412, 372, 219),
  ('TIF', 'SHJ', 127, 543, 142),
  ('TRV', 'SHJ', 628, -729, 225),
  ('TUU', 'SHJ', 139, 241, 150),
  ('TZX', 'SHJ', 106, 223, 214),
  ('UET', 'SHJ', 90, 629, 125),
  ('UFA', 'SHJ', 40, 47, 262),
  ('VIE', 'SHJ', 192, 136, 320),
  ('WAW', 'SHJ', 220, -233, 333),
  ('WMI', 'SHJ', 57, 46, 322);

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
    v_mtg NUMERIC; v_after NUMERIC; v_land NUMERIC; v_mins NUMERIC; v_until TIMESTAMPTZ; v_phase TEXT; v_bias NUMERIC; v_airm NUMERIC; v_cn NUMERIC;
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
    -- this route's own tendency: the fleet model over- or under-states the route's trip fuel by bias_kg on average. That is taken back as a fixed
    -- amount that builds up over the route's usual airborne minutes and stops there (a long hold does not keep earning it).
    SELECT x.bias_kg, x.air_min INTO v_bias, v_airm FROM fuel_route_adjust x WHERE x.origin_iata = trim(f.dep_iata) AND x.dest_iata = trim(f.arr_iata);
    v_cn := coalesce(v_bias, 0) * coalesce(least(1, v_cmin / nullif(v_airm, 0)), 0);
    v_fuel := e.fuel_on_board_kg - v_cruise * v_cmin - v_hold * v_hmin + v_cn;

    -- how long the fuel lasts: to the hub (cruise), approach and landing, then holding down to the final reserve
    v_eta := coalesce(s.eta_utc, f.sta_utc);
    v_mtg := CASE WHEN v_phase = 'HOLDING' THEN 0 ELSE greatest(0, extract(epoch FROM (v_eta - p_at)) / 60) END;
    v_after := coalesce(m.a_fixed_kg * (1 - m.climb_share) + m.taxi_in_kg_per_min * m.taxi_in_median_min, 0);
    v_land := v_fuel - v_cruise * v_mtg - v_after + (coalesce(v_bias, 0) * coalesce(least(1, (v_cmin + v_mtg) / nullif(v_airm, 0)), 0) - v_cn);
    v_mins := v_mtg + (v_land - v_res_min * v_hold) / v_hold;
    v_until := p_at + make_interval(secs => (greatest(0, v_mins) * 60)::double precision);

    -- a flight cannot have less than nothing: 0 means the estimate says the fuel is gone
    fuel_kg := greatest(0, round(v_fuel))::int; endurance_until := v_until; endurance_min := greatest(0, floor(v_mins))::int;
    anchor_kind := CASE WHEN e.quality IN ('MEASURED', 'MANUAL', 'FORECAST') THEN 'ENTERED' WHEN e.basis->>'anchor' = 'TAKEOFF' THEN 'TAKEOFF' ELSE 'LEGACY' END;
    basis := e.basis || jsonb_build_object(
        'cruise_kg_per_min', round(v_cruise, 1), 'aircraft_factor', v_fac, 'route_correction_kg', round(v_cn), 'hold_kg_per_min', round(v_hold, 1),
        'cruise_min', round(v_cmin), 'hold_min', round(v_hmin), 'kg_after_arrival_fixed', round(v_after), 'minutes_to_hub', round(v_mtg),
        'text', format('%s kg %s at %s UTC; minus %s min x %s kg/min%s = %s kg now',
                       e.fuel_on_board_kg, CASE WHEN e.basis->>'anchor' = 'TAKEOFF' THEN 'at take-off' ELSE 'as entered' END,
                       to_char(e.as_of_utc AT TIME ZONE 'UTC', 'DD HH24:MI'), round(v_cmin), round(v_cruise, 1),
                       CASE WHEN v_hmin > 0 THEN format(' and %s min holding x %s kg/min', round(v_hmin), round(v_hold, 1)) ELSE '' END, greatest(0, round(v_fuel))));
    RETURN NEXT;
END $$;

SELECT enqueue_reassessment(scenario_id, 'migration 024: route fuel correction', 'airport', 'SHJ') FROM scenario WHERE is_active;
