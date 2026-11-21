-- 017: a diverted aircraft gets a real landing time (usability review U1).
-- execute_diversion() sent the DIVERT event without an ETA and built the recovery leg from the OLD hub estimate. Right after executing a
-- diversion the flight therefore carried a landing time that was already in the past, and the recovery leg was planned from it.
-- Now: ETA at the alternate = now + historical P50 flight time hub -> alternate (distance estimate if there is no history), set on the
-- DIVERT event, and the recovery leg departs ETA + turnaround. Everything else is the 004 function unchanged.
SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION execute_diversion(p_decision_id BIGINT, p_turnaround_min INT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    d decision%ROWTYPE; f flight%ROWTYPE; s flight_state%ROWTYPE;
    v_alt airport%ROWTYPE; v_rec_flight BIGINT; v_div BIGINT; v_std TIMESTAMPTZ; v_block INT;
    v_turn INT; l RECORD; v_now TIMESTAMPTZ; v_fl INT; v_eta TIMESTAMPTZ;
BEGIN
    SELECT * INTO d FROM decision WHERE decision_id = p_decision_id FOR UPDATE;
    IF d.decision_type <> 'DIVERT' THEN RAISE EXCEPTION 'Decision % is not a DIVERT', p_decision_id; END IF;
    IF d.status <> 'APPROVED' THEN RAISE EXCEPTION 'Decision % must be APPROVED (is %)', p_decision_id, d.status; END IF;
    IF d.alternate_iata IS NULL THEN RAISE EXCEPTION 'Decision % has no alternate', p_decision_id; END IF;
    v_now := scenario_now(d.scenario_id);

    SELECT * INTO f FROM flight WHERE flight_id = d.flight_id;
    SELECT * INTO s FROM flight_state WHERE scenario_id = d.scenario_id AND flight_id = d.flight_id;
    SELECT * INTO v_alt FROM airport WHERE iata = d.alternate_iata;
    v_turn := coalesce(p_turnaround_min, v_alt.min_ground_time_min, 40);

    -- the flight now has a NEW landing time: flying from the hub area to the alternate (historical P50, else from the distance).
    -- Before this the old SHJ estimate stayed on the flight, so right after a diversion it looked like it had landed in the past.
    SELECT airborne_p50_min INTO v_fl FROM leg_time_reference WHERE from_iata = f.arr_iata AND to_iata = d.alternate_iata;
    v_fl := coalesce(v_fl, ceil(distance_km(f.arr_iata, d.alternate_iata) / 7.0)::int + 10);
    v_eta := v_now + make_interval(mins => v_fl);

    -- 1) feed: the flight now heads to the alternate
    PERFORM ingest_flight_event(d.scenario_id, 'MANUAL', 'DECISION-' || d.decision_id, d.flight_id,
        'DIVERT', v_now, jsonb_build_object('actual_arr_iata', d.alternate_iata, 'holding', false, 'eta', v_eta));

    -- 2) recovery leg ALT -> original destination
    SELECT coalesce(median_block_min, NULL) INTO v_block FROM block_time_reference
     WHERE from_iata = d.alternate_iata AND to_iata = f.arr_iata;
    v_block := coalesce(v_block, 60);
    -- the recovery leg can leave once the aircraft has landed at the alternate and turned round
    v_std := coalesce(d.target_time_utc, v_eta + make_interval(mins => v_turn));
    INSERT INTO flight (flight_no, flight_date, dep_iata, arr_iata, std_utc, sta_utc, registration_planned,
                        op_type, flight_kind, parent_flight_id, pax_planned, source)
    VALUES (f.flight_no || 'D', (v_std AT TIME ZONE 'UTC')::date, d.alternate_iata, f.arr_iata, v_std,
            v_std + make_interval(mins => v_block), coalesce(s.registration, f.registration_planned),
            f.op_type, 'RECOVERY', f.flight_id, coalesce(s.pax, f.pax_planned),
            'decision:' || d.decision_id)
    -- flights are shared across scenarios: another replay may already have created this recovery leg
    ON CONFLICT (flight_no, std_utc, dep_iata) DO UPDATE SET source = flight.source
    RETURNING flight_id INTO v_rec_flight;
    INSERT INTO flight_state (scenario_id, flight_id, registration, etd_utc, eta_utc, pax, last_received_at)
    VALUES (d.scenario_id, v_rec_flight, coalesce(s.registration, f.registration_planned), v_std,
            v_std + make_interval(mins => v_block), coalesce(s.pax, f.pax_planned), v_now)
    ON CONFLICT (scenario_id, flight_id) DO NOTHING;

    -- 3) diversion tracking record for the station
    INSERT INTO diversion (scenario_id, case_id, original_flight_id, alternate_iata, decision_id,
                           recovery_flight_id, turnaround_min_assumed, planned_departure_utc,
                           waiting_for, status, updated_by)
    VALUES (d.scenario_id, d.case_id, d.flight_id, d.alternate_iata, d.decision_id, v_rec_flight,
            v_turn, v_std, 'LANDING', 'DIVERTING', d.decided_by)
    RETURNING diversion_id INTO v_div;

    -- 4) every crew duty operating the diverted flight gets the extra sector
    FOR l IN SELECT duty_id, leg_seq FROM crew_duty_leg
              WHERE scenario_id = d.scenario_id AND flight_id = d.flight_id AND is_active LOOP
        UPDATE crew_duty_leg SET leg_seq = leg_seq + 100
         WHERE scenario_id = d.scenario_id AND duty_id = l.duty_id AND leg_seq > l.leg_seq;
        UPDATE crew_duty_leg SET leg_seq = leg_seq - 99
         WHERE scenario_id = d.scenario_id AND duty_id = l.duty_id AND leg_seq > 100;
        INSERT INTO crew_duty_leg (scenario_id, duty_id, leg_seq, flight_id, leg_source, added_by_decision_id)
        VALUES (d.scenario_id, l.duty_id, l.leg_seq + 1, v_rec_flight, 'RECOVERY', d.decision_id);
        PERFORM compute_duty_legality(d.scenario_id, l.duty_id, 'diversion:' || d.decision_id);
    END LOOP;

    UPDATE decision SET status = 'EXECUTED', executed_at = v_now,
                        details = details || jsonb_build_object('diversion_id', v_div, 'recovery_flight_id', v_rec_flight)
     WHERE decision_id = p_decision_id;
    PERFORM compute_latest_departure(d.scenario_id, v_rec_flight);
    RETURN v_div;
END $$;

ALTER FUNCTION execute_diversion(BIGINT, INT) SET search_path = fogops, public;
