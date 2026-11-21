-- 018: passenger connection rules - minimum connection time 30 min, maximum 24 hours.
--
--   * A connection only exists if the gap between arrival and the onward departure is between 30 min and 24 h. Rows of
--     pax_connection whose SCHEDULED gap is outside that window are not connections (2 rows / 3 passengers were over 24 h) and no
--     longer count anywhere: pax_connection_valid is the single source for every count (severity score, downstream impact,
--     recovery planner, connection risk, the engine's connection penalty, the board tile).
--   * With the projected times (delay, hold, diversion):
--       gap < 30 min (or the onward flight already left)  MISSED
--       gap > 24 h                                        TOO_LONG  (no longer a connection: rebook; counts as affected)
--       30 to 45 min                                      AT_RISK   (tight: 15 min above the minimum; margin is ASSUMED)
--       otherwise                                         OK
--     (Before: missed only when the onward flight had left, at risk under 40 min.)

SET search_path = fogops, hist, public;

INSERT INTO divert_policy (key, value, unit, basis) VALUES
  ('min_connection_min',         30,   'min', 'Minimum connection time: with a smaller gap between arrival and the onward departure the passenger misses the connection.'),
  ('max_connection_min',         1440, 'min', 'Maximum connection time (24 h): a longer gap is not a connection (scheduled), or a delay stretching it past this makes it TOO_LONG (rebook).'),
  ('connection_tight_margin_min', 15,  'min', 'ASSUMED: a connection within this many minutes above the minimum is tight (AT_RISK).')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, basis = EXCLUDED.basis, updated_at = now();

CREATE OR REPLACE VIEW pax_connection_valid AS
SELECT pc.*
  FROM pax_connection pc
 WHERE pc.sched_connection_min IS NULL
    OR pc.sched_connection_min BETWEEN (SELECT value FROM divert_policy WHERE key = 'min_connection_min')
                                   AND (SELECT value FROM divert_policy WHERE key = 'max_connection_min');

CREATE OR REPLACE VIEW v_connection_risk AS
WITH c AS (
         SELECT si.scenario_id,
            pc.inbound_flight_id,
            pc.outbound_flight_id,
            pc.connection_iata,
            pc.pax_count,
            pc.pax_inbound_view,
            pc.pax_outbound_view,
            pc.source_view,
            pc.sched_connection_min,
            fi.flight_no AS inbound_flight,
            fi.dep_iata AS inbound_from,
            fo.flight_no AS outbound_flight,
            fo.arr_iata AS outbound_to,
            COALESCE(si.ata_utc, si.eta_utc, fi.sta_utc) AS inbound_arrival_utc,
            COALESCE(so.atd_utc, so.etd_utc, fo.std_utc) AS outbound_departure_utc,
            si.status AS inbound_status,
            si.actual_arr_iata,
            so.status AS outbound_status,
            so.atd_utc AS outbound_atd
           FROM pax_connection_valid pc
             JOIN flight fi ON fi.flight_id = pc.inbound_flight_id
             JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
             JOIN flight_state si ON si.flight_id = pc.inbound_flight_id
             LEFT JOIN flight_state so ON so.flight_id = pc.outbound_flight_id AND so.scenario_id = si.scenario_id
        )
 SELECT scenario_id,
    inbound_flight_id,
    inbound_flight,
    inbound_from,
    outbound_flight_id,
    outbound_flight,
    outbound_to,
    connection_iata,
    pax_count,
    source_view,
    sched_connection_min,
    inbound_arrival_utc,
    outbound_departure_utc,
    floor(EXTRACT(epoch FROM outbound_departure_utc - inbound_arrival_utc) / 60::numeric)::integer AS projected_connection_min,
        CASE
            WHEN actual_arr_iata IS NOT NULL AND actual_arr_iata <> connection_iata THEN 'INBOUND_DIVERTED'::text
            WHEN inbound_status = 'CANCELLED'::flight_status OR outbound_status = 'CANCELLED'::flight_status THEN 'CANCELLED'::text
            WHEN outbound_atd IS NOT NULL AND outbound_atd < inbound_arrival_utc THEN 'MISSED'::text
            WHEN (outbound_departure_utc - inbound_arrival_utc) < make_interval(mins => (SELECT value FROM divert_policy WHERE key = 'min_connection_min')::int) THEN 'MISSED'::text
            WHEN (outbound_departure_utc - inbound_arrival_utc) > make_interval(mins => (SELECT value FROM divert_policy WHERE key = 'max_connection_min')::int) THEN 'TOO_LONG'::text
            WHEN (outbound_departure_utc - inbound_arrival_utc) < make_interval(mins => (SELECT value FROM divert_policy WHERE key = 'min_connection_min')::int
                                                                                      + (SELECT value FROM divert_policy WHERE key = 'connection_tight_margin_min')::int) THEN 'AT_RISK'::text
            ELSE 'OK'::text
        END AS connection_status
   FROM c;

CREATE OR REPLACE VIEW v_flight_severity AS
SELECT case_id,
    scenario_id,
    flight_id,
    flight_no,
    COALESCE(( SELECT sum(pc.pax_count) AS sum
           FROM pax_connection_valid pc
          WHERE pc.inbound_flight_id = w.flight_id), 0::bigint) AS connecting_pax,
    LEAST(100::numeric, round(40::numeric *
        CASE
            WHEN minutes_to_latest_legal_departure IS NOT NULL THEN GREATEST(0::numeric, 1::numeric - minutes_to_latest_legal_departure::numeric / 120.0)
            ELSE 0.3
        END + 20::numeric *
        CASE crew_status
            WHEN 'EXCEEDED'::legality_status THEN 1::numeric
            WHEN 'DISCRETION_REQUIRED'::legality_status THEN 0.8
            WHEN 'AT_RISK'::legality_status THEN 0.6
            WHEN 'VERIFICATION_REQUIRED'::legality_status THEN 0.5
            ELSE 0::numeric
        END + (15 *
        CASE
            WHEN lvp_required AND lvp_crew_ok IS NOT TRUE THEN 1
            ELSE 0
        END)::numeric + 15::numeric * LEAST(1::numeric, COALESCE(( SELECT sum(pc.pax_count) AS sum
           FROM pax_connection_valid pc
          WHERE pc.inbound_flight_id = w.flight_id), 0::bigint)::numeric / 200.0) + (10 *
        CASE
            WHEN open_exceptions > 0 THEN 1
            ELSE 0
        END)::numeric))::integer AS severity_score
   FROM v_flight_watch w;

CREATE OR REPLACE FUNCTION fogops.downstream_impact(p_scenario_id integer, p_flight_id bigint, p_ready_at_hub_utc timestamp with time zone DEFAULT NULL::timestamp with time zone, p_horizon_hours integer DEFAULT 24)
 RETURNS TABLE(kind text, seq integer, ref text, route text, planned_utc timestamp with time zone, projected_utc timestamp with time zone, delay_min integer, connecting_pax integer, impact text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fogops', 'public'
AS $function$
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
        connecting_pax := coalesce((SELECT sum(pax_count) FROM pax_connection_valid pc WHERE pc.inbound_flight_id = nx.flight_id), 0)::int;
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
END $function$;

CREATE OR REPLACE FUNCTION fogops.build_recovery_plan(p_scenario_id integer, p_case_id integer, p_window_min integer DEFAULT 60, p_weights jsonb DEFAULT '{"pax": 0.15, "crew": 0.30, "fuel": 0.40, "rotation": 0.15}'::jsonb, p_generated_by text DEFAULT 'agent'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'fogops', 'public'
AS $function$
DECLARE
    c disruption_case%ROWTYPE; v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_hub airport_status_event%ROWTYPE; v_reopen TIMESTAMPTZ; v_cap INT; v_interval INT;
    v_plan BIGINT; r RECORD; v_used INT[] := '{}'; k INT; v_slot TIMESTAMPTZ; v_rank INT := 0; v_in INT := 0;
    v_wend TIMESTAMPTZ; v_tmp INT := 0;
BEGIN
    SELECT * INTO c FROM disruption_case WHERE case_id = p_case_id;
    SELECT * INTO v_hub FROM airport_status_event
     WHERE scenario_id = p_scenario_id AND iata = c.hub_iata AND effective_from_utc <= v_now
     ORDER BY effective_from_utc DESC, status_event_id DESC LIMIT 1;
    v_reopen := CASE WHEN v_hub.op_status = 'OPEN' THEN greatest(v_hub.effective_from_utc, v_now)
                     ELSE coalesce(v_hub.expected_reopen_utc, v_now) END;
    -- capacity after reopening: latest announced arrival rate, else scenario override, else 20/hr
    v_cap := coalesce((SELECT (overrides->>'recovery_capacity_per_hr')::int FROM scenario WHERE scenario_id = p_scenario_id),
                      nullif(v_hub.arrival_capacity_per_hr, 0), 20);
    v_interval := greatest(1, 60 / v_cap);
    v_wend := v_reopen + make_interval(mins => p_window_min);

    UPDATE recovery_plan SET status = 'SUPERSEDED'
     WHERE scenario_id = p_scenario_id AND case_id = p_case_id AND status = 'PROPOSED';
    INSERT INTO recovery_plan (scenario_id, case_id, hub_iata, reopening_utc, window_start_utc, window_end_utc,
                               capacity_per_hr, weights, inputs, generated_by)
    VALUES (p_scenario_id, p_case_id, c.hub_iata, v_reopen, v_reopen, v_wend, v_cap, p_weights,
            jsonb_build_object('hub_status_event_id', v_hub.status_event_id, 'evaluated_at', v_now,
                               'slot_interval_min', v_interval), p_generated_by)
    RETURNING plan_id INTO v_plan;

    FOR r IN
        WITH cand AS (
            -- (a) inbound, not diverted, not yet on blocks at the hub
            SELECT f.flight_id, f.flight_no, s.status::text AS st,
                   CASE WHEN s.status = 'HOLDING' THEN 'AIRBORNE_HOLDING'
                        WHEN s.status = 'AIRBORNE' THEN 'AIRBORNE'
                        ELSE 'NOT_DEPARTED_' || f.dep_iata END AS loc,
                   greatest(v_reopen, coalesce(s.eta_utc, f.sta_utc)) AS earliest,
                   s.registration, coalesce(s.pax, f.pax_planned, 0) AS pax,
                   -- remaining endurance in minutes at "now", from the latest estimate
                   (SELECT floor(extract(epoch FROM fe.as_of_utc + make_interval(mins => fe.est_holding_endurance_min)
                                                    - v_now) / 60)::int
                      FROM flight_fuel_estimate fe
                     WHERE fe.scenario_id = p_scenario_id AND fe.flight_id = f.flight_id
                     ORDER BY as_of_utc DESC LIMIT 1) AS endurance,
                   NULL::timestamptz AS latest_dep, f.std_utc AS dep_std, f.flight_id AS crew_flight
              FROM case_flight cf JOIN flight f ON f.flight_id = cf.flight_id
              JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
             WHERE cf.case_id = p_case_id AND f.arr_iata = c.hub_iata
               AND s.status NOT IN ('ON_BLOCKS','LANDED','CANCELLED','DIVERTING')
               AND (s.actual_arr_iata IS NULL OR s.actual_arr_iata = c.hub_iata)
            UNION ALL
            -- (b) diverted aircraft: the candidate is the recovery leg ALT -> hub
            SELECT rf.flight_id, rf.flight_no, 'DIVERTED',
                   'ON_GROUND_' || dv.alternate_iata,
                   greatest(v_reopen,
                            greatest(v_now, coalesce(dv.on_blocks_alt_utc, s0.eta_utc, v_now)
                                            + make_interval(mins => coalesce(dv.turnaround_min_assumed, 40)))
                            + (rf.sta_utc - rf.std_utc)),
                   rs.registration, coalesce(rs.pax, rf.pax_planned, 0), NULL,
                   (SELECT latest_legal_offblocks_utc FROM latest_departure_calc ld
                     WHERE ld.scenario_id = p_scenario_id AND ld.flight_id = rf.flight_id AND ld.is_current),
                   rf.std_utc, rf.flight_id
              FROM diversion dv
              JOIN flight rf ON rf.flight_id = dv.recovery_flight_id
              LEFT JOIN flight_state rs ON rs.flight_id = rf.flight_id AND rs.scenario_id = p_scenario_id
              LEFT JOIN flight_state s0 ON s0.flight_id = dv.original_flight_id AND s0.scenario_id = p_scenario_id
             WHERE dv.scenario_id = p_scenario_id AND dv.case_id = p_case_id
               AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED')
        ), scored AS (
            SELECT ca.*,
                   (SELECT min(margin_min) FROM fdp_calculation fc JOIN crew_duty_leg l ON l.duty_id = fc.duty_id
                     WHERE l.scenario_id = p_scenario_id AND l.flight_id = ca.crew_flight
                       AND l.is_active AND fc.is_current
                       AND fc.crew_id IS NULL AND fc.scenario_id = p_scenario_id) AS crew_margin,
                   (SELECT count(*) FROM flight nf JOIN flight_state ns ON ns.flight_id = nf.flight_id
                                                   AND ns.scenario_id = p_scenario_id
                     WHERE ns.registration = ca.registration AND nf.dep_iata = c.hub_iata
                       AND nf.std_utc BETWEEN ca.earliest AND ca.earliest + interval '8 hours') AS next_rotations,
                   (SELECT coalesce(sum(pc.pax_count),0) FROM pax_connection_valid pc
                     WHERE pc.inbound_flight_id IN (ca.flight_id,
                           (SELECT parent_flight_id FROM flight WHERE flight_id = ca.flight_id))) AS connecting
              FROM cand ca
        )
        SELECT sc.*,
               CASE WHEN sc.loc LIKE 'AIRBORNE%' THEN
                        CASE WHEN sc.endurance IS NULL THEN 0.8
                             ELSE least(1, greatest(0, 1 - sc.endurance / 120.0)) END
                    ELSE 0 END AS s_fuel,
               CASE WHEN sc.crew_margin IS NULL THEN 0.5
                    ELSE least(1, greatest(0, 1 - sc.crew_margin / 240.0)) END AS s_crew,
               least(1, sc.next_rotations / 3.0) AS s_rot,
               least(1, (sc.pax + 2 * sc.connecting) / 400.0) AS s_pax
          FROM scored sc
    LOOP
        DECLARE
            v_score NUMERIC := (p_weights->>'fuel')::numeric * r.s_fuel + (p_weights->>'crew')::numeric * r.s_crew
                             + (p_weights->>'rotation')::numeric * r.s_rot + (p_weights->>'pax')::numeric * r.s_pax;
            v_feasible BOOLEAN := TRUE; v_why TEXT := NULL; v_lvp RECORD;
        BEGIN
            v_tmp := v_tmp + 1;
            SELECT * INTO v_lvp FROM flight_lvp_check(p_scenario_id, r.flight_id);
            IF r.loc LIKE 'AIRBORNE%' AND r.endurance IS NOT NULL
               AND r.earliest > v_now + make_interval(mins => r.endurance) THEN
                v_feasible := FALSE;
                v_why := format('Estimated fuel endurance (%s min) ends before earliest landing slot: must divert', r.endurance);
            ELSIF r.latest_dep IS NOT NULL
               AND r.latest_dep < r.earliest - (SELECT sta_utc - std_utc FROM flight WHERE flight_id = r.flight_id) THEN
                v_feasible := FALSE; v_why := 'Crew latest legal departure is before earliest possible departure: replacement crew or discretion needed';
            ELSIF lvp_in_force(p_scenario_id, c.hub_iata) AND v_lvp.lvp_ok IS FALSE THEN
                v_feasible := FALSE;
                v_why := format('LVP in force at %s and cockpit crew not LVP-qualified (%s): LVP-qualified crew change or wait for LVP cancellation',
                                c.hub_iata, (SELECT string_agg(x->>'position' || ' ' || (x->>'crew_id'), ', ')
                                               FROM jsonb_array_elements(v_lvp.not_qualified) x));
            ELSIF lvp_in_force(p_scenario_id, c.hub_iata) AND v_lvp.lvp_ok IS NULL THEN
                v_why := 'LVP in force: cockpit crew qualification could not be verified';
            ELSIF r.crew_margin IS NULL THEN
                v_why := 'Crew legality not computed: verification required';
            END IF;
            INSERT INTO recovery_plan_item (plan_id, rank, flight_id, current_location, earliest_arrival_utc,
                is_feasible, priority_score, score_breakdown, reasons, infeasible_reason)
            VALUES (v_plan, 10000 + v_tmp, r.flight_id, r.loc, r.earliest,
                v_feasible, round(v_score, 3),
                jsonb_build_object('fuel', round(r.s_fuel,3), 'crew', round(r.s_crew,3),
                                   'rotation', round(r.s_rot,3), 'pax', round(r.s_pax,3),
                                   'crew_margin_min', r.crew_margin, 'fuel_endurance_min', r.endurance,
                                   'next_rotations_8h', r.next_rotations, 'pax', r.pax,
                                   'connecting_pax', r.connecting),
                array_remove(ARRAY[
                    CASE WHEN r.s_fuel >= 0.5 THEN 'Low fuel endurance while airborne' END,
                    CASE WHEN r.s_crew >= 0.5 THEN format('Crew margin only %s', fmt_min(r.crew_margin)) END,
                    CASE WHEN r.next_rotations > 0 THEN format('%s onward rotation(s) within 8h', r.next_rotations) END,
                    CASE WHEN r.connecting > 0 THEN format('%s connecting pax', r.connecting) END], NULL),
                v_why);
        END;
    END LOOP;

    -- rank feasible flights by score and allocate arrival slots greedily
    FOR r IN SELECT * FROM recovery_plan_item WHERE plan_id = v_plan
              ORDER BY is_feasible DESC, priority_score DESC, earliest_arrival_utc LOOP
        v_rank := v_rank + 1;
        v_slot := NULL;
        IF r.is_feasible THEN
            k := greatest(0, ceil(extract(epoch FROM r.earliest_arrival_utc - v_reopen) / 60.0 / v_interval)::int);
            WHILE k = ANY (v_used) LOOP k := k + 1; END LOOP;
            v_used := v_used || k;
            v_slot := v_reopen + make_interval(mins => k * v_interval);
            IF v_slot < v_wend THEN v_in := v_in + 1; END IF;
        END IF;
        UPDATE recovery_plan_item SET rank = 20000 + v_rank, proposed_slot_utc = v_slot,
                                      within_window = (v_slot IS NOT NULL AND v_slot < v_wend)
         WHERE plan_id = v_plan AND flight_id = r.flight_id;
    END LOOP;
    -- final rank = landing order (priority decided who got which slot; infeasible flights last)
    UPDATE recovery_plan_item i SET rank = o.rn
      FROM (SELECT flight_id, row_number() OVER (ORDER BY is_feasible DESC, proposed_slot_utc NULLS LAST,
                                                          priority_score DESC) AS rn
              FROM recovery_plan_item WHERE plan_id = v_plan) o
     WHERE i.plan_id = v_plan AND i.flight_id = o.flight_id;
    UPDATE recovery_plan SET arrivals_in_window = v_in WHERE plan_id = v_plan;
    RETURN v_plan;
END $function$;

-- Connecting passengers on the onward flights of an inbound flight, for a given arrival time at the hub (30 min minimum, 24 h maximum).
CREATE OR REPLACE FUNCTION connection_impact(p_scenario_id INT, p_flight_id BIGINT, p_arrival TIMESTAMPTZ,
                                             OUT pax_missed INT, OUT pax_tight INT, OUT connections INT, OUT pax_total INT, OUT penalty NUMERIC)
LANGUAGE plpgsql STABLE SET search_path = fogops, public AS $$
#variable_conflict use_column
DECLARE
    v_min INT     := coalesce((SELECT value FROM divert_policy WHERE key = 'min_connection_min'), 30)::int;
    v_max INT     := coalesce((SELECT value FROM divert_policy WHERE key = 'max_connection_min'), 1440)::int;
    v_mrg INT     := coalesce((SELECT value FROM divert_policy WHERE key = 'connection_tight_margin_min'), 15)::int;
    v_pmax NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'pax_penalty_max'), 0.25);
    v_ref  NUMERIC := coalesce((SELECT value FROM divert_policy WHERE key = 'pax_penalty_ref_pax'), 300);
BEGIN
    pax_missed := 0; pax_tight := 0; connections := 0; pax_total := 0; penalty := 0;
    IF p_arrival IS NULL THEN RETURN; END IF;
    SELECT coalesce(sum(pc.pax_count) FILTER (WHERE x.dep < p_arrival + make_interval(mins => v_min)
                                                 OR x.dep > p_arrival + make_interval(mins => v_max)), 0)::int,
           coalesce(sum(pc.pax_count) FILTER (WHERE x.dep >= p_arrival + make_interval(mins => v_min)
                                                AND x.dep < p_arrival + make_interval(mins => v_min + v_mrg)), 0)::int,
           count(*)::int, coalesce(sum(pc.pax_count), 0)::int
      INTO pax_missed, pax_tight, connections, pax_total
      FROM pax_connection_valid pc
      JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
      LEFT JOIN flight_state so ON so.flight_id = pc.outbound_flight_id AND so.scenario_id = p_scenario_id
      CROSS JOIN LATERAL (SELECT coalesce(so.atd_utc, so.etd_utc, fo.std_utc) AS dep) x
     WHERE pc.inbound_flight_id = p_flight_id
       AND coalesce(so.is_cancelled, FALSE) = FALSE AND coalesce(so.status::text, '') <> 'CANCELLED';
    penalty := round(v_pmax * least(1, (pax_missed + 0.5 * pax_tight) / v_ref), 3);
END $$;

-- Recompute the recommendations of the live scenarios with the new connection rules.
SELECT enqueue_reassessment(scenario_id, 'migration 018: connection time window', 'airport', 'SHJ') FROM scenario WHERE kind = 'LIVE' AND is_active;
