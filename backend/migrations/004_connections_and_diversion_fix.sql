-- Passenger connections (richer shape from the New Plan) + connection-risk view + diversion fix.
-- The restored dump only has (inbound, outbound, pax_count). Add the new columns and backfill what can be derived;
-- source_view stays 'BOTH' (unknown) until the loader is re-run with the original files.
ALTER TABLE pax_connection
    ADD COLUMN IF NOT EXISTS connection_iata      CHAR(3) REFERENCES airport,
    ADD COLUMN IF NOT EXISTS pax_inbound_view     INT,
    ADD COLUMN IF NOT EXISTS pax_outbound_view    INT,
    ADD COLUMN IF NOT EXISTS source_view          TEXT NOT NULL DEFAULT 'BOTH'
        CHECK (source_view IN ('BOTH','INBOUND_VIEW','OUTBOUND_VIEW')),
    ADD COLUMN IF NOT EXISTS sched_connection_min INT;
-- Normalise direction. The old load kept both views of each connection, so ~5,060 rows have the flights
-- reversed ("inbound" arrives after the "outbound" departs). Swap them and merge with the correct row
-- (max of the two counts). Result matches the plan's loader: 5,061 connections, 31,548 passengers.
CREATE TEMP TABLE _rev ON COMMIT DROP AS
SELECT pc.* FROM pax_connection pc
  JOIN flight fi ON fi.flight_id = pc.inbound_flight_id
  JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
 WHERE fi.sta_utc > fo.std_utc;
INSERT INTO pax_connection (inbound_flight_id, outbound_flight_id, pax_count, source_view)
SELECT outbound_flight_id, inbound_flight_id, pax_count, 'OUTBOUND_VIEW' FROM _rev
ON CONFLICT (inbound_flight_id, outbound_flight_id) DO UPDATE
   SET pax_count = greatest(pax_connection.pax_count, excluded.pax_count), source_view = 'BOTH';
DELETE FROM pax_connection pc USING _rev r
 WHERE pc.inbound_flight_id = r.inbound_flight_id AND pc.outbound_flight_id = r.outbound_flight_id;

UPDATE pax_connection pc
   SET connection_iata = fi.arr_iata,
       sched_connection_min = floor(extract(epoch FROM fo.std_utc - fi.sta_utc) / 60)::int
  FROM flight fi, flight fo
 WHERE fi.flight_id = pc.inbound_flight_id AND fo.flight_id = pc.outbound_flight_id
   AND pc.connection_iata IS NULL;
CREATE INDEX IF NOT EXISTS ix_pax_conn_outbound ON pax_connection (outbound_flight_id);

-- Passenger connections at risk: projected connection time per scenario.
-- Minimum connection time 40 min = smallest scheduled connection in the supplied data (assumption).
CREATE OR REPLACE VIEW v_connection_risk AS
WITH c AS (
    SELECT si.scenario_id, pc.*, fi.flight_no AS inbound_flight, fi.dep_iata AS inbound_from,
           fo.flight_no AS outbound_flight, fo.arr_iata AS outbound_to,
           coalesce(si.ata_utc, si.eta_utc, fi.sta_utc) AS inbound_arrival_utc,
           coalesce(so.atd_utc, so.etd_utc, fo.std_utc) AS outbound_departure_utc,
           si.status AS inbound_status, si.actual_arr_iata, so.status AS outbound_status, so.atd_utc AS outbound_atd
      FROM pax_connection pc
      JOIN flight fi ON fi.flight_id = pc.inbound_flight_id
      JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
      JOIN flight_state si ON si.flight_id = pc.inbound_flight_id
      LEFT JOIN flight_state so ON so.flight_id = pc.outbound_flight_id AND so.scenario_id = si.scenario_id
)
SELECT scenario_id, inbound_flight_id, inbound_flight, inbound_from, outbound_flight_id, outbound_flight, outbound_to,
       connection_iata, pax_count, source_view, sched_connection_min,
       inbound_arrival_utc, outbound_departure_utc,
       floor(extract(epoch FROM outbound_departure_utc - inbound_arrival_utc) / 60)::int AS projected_connection_min,
       CASE WHEN actual_arr_iata IS NOT NULL AND actual_arr_iata <> connection_iata THEN 'INBOUND_DIVERTED'
            WHEN inbound_status = 'CANCELLED' OR outbound_status = 'CANCELLED' THEN 'CANCELLED'
            WHEN outbound_atd IS NOT NULL AND outbound_atd < inbound_arrival_utc THEN 'MISSED'
            WHEN outbound_departure_utc - inbound_arrival_utc < interval '0 minutes' THEN 'MISSED'
            WHEN outbound_departure_utc - inbound_arrival_utc < interval '40 minutes' THEN 'AT_RISK'
            ELSE 'OK' END AS connection_status
  FROM c;

-- execute_diversion: flights are shared across scenarios, so another replay may already have created the recovery leg
CREATE OR REPLACE FUNCTION execute_diversion(p_decision_id BIGINT, p_turnaround_min INT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    d decision%ROWTYPE; f flight%ROWTYPE; s flight_state%ROWTYPE;
    v_alt airport%ROWTYPE; v_rec_flight BIGINT; v_div BIGINT; v_std TIMESTAMPTZ; v_block INT;
    v_turn INT; l RECORD; v_now TIMESTAMPTZ;
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

    -- 1) feed: the flight now heads to the alternate
    PERFORM ingest_flight_event(d.scenario_id, 'MANUAL', 'DECISION-' || d.decision_id, d.flight_id,
        'DIVERT', v_now, jsonb_build_object('actual_arr_iata', d.alternate_iata, 'holding', false));

    -- 2) recovery leg ALT -> original destination
    SELECT coalesce(median_block_min, NULL) INTO v_block FROM block_time_reference
     WHERE from_iata = d.alternate_iata AND to_iata = f.arr_iata;
    v_block := coalesce(v_block, 60);
    v_std := coalesce(d.target_time_utc,
                      greatest(coalesce(s.eta_utc, f.sta_utc), v_now) + make_interval(mins => v_turn));
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

-- Crew swap / replacement: closes the old assignment, opens a new one (temporal history kept)
CREATE OR REPLACE FUNCTION swap_crew(p_scenario_id INT, p_duty_id BIGINT, p_out_crew INT, p_in_crew INT, p_reason TEXT,
                                     p_sign_in_utc TIMESTAMPTZ DEFAULT NULL, p_report_station CHAR(3) DEFAULT NULL,
                                     p_from_leg_seq SMALLINT DEFAULT 1, p_source TEXT DEFAULT 'SWAP')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE o crew_assignment%ROWTYPE; v_new BIGINT;
BEGIN
    IF actor_user_id() IS NULL THEN RAISE EXCEPTION 'set_actor() must be called before swap_crew'; END IF;
    SELECT * INTO o FROM crew_assignment
     WHERE scenario_id = p_scenario_id AND duty_id = p_duty_id AND crew_id = p_out_crew
       AND valid_to IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Crew % not active on duty %', p_out_crew, p_duty_id; END IF;
    UPDATE crew_assignment SET valid_to = greatest(scenario_stamp(p_scenario_id), o.valid_from + interval '1 second'),
                               changed_by = actor_user_id(),
                               change_reason = p_reason
     WHERE assignment_id = o.assignment_id;
    INSERT INTO crew_assignment (scenario_id, duty_id, crew_id, position_code, valid_from, source,
                                 replaced_assignment_id, sign_in_utc, report_station_iata, from_leg_seq,
                                 changed_by, change_reason)
    VALUES (p_scenario_id, p_duty_id, p_in_crew, o.position_code,
            greatest(scenario_stamp(p_scenario_id), o.valid_from + interval '1 second'), p_source, o.assignment_id,
            p_sign_in_utc, p_report_station, p_from_leg_seq, actor_user_id(), p_reason)
    RETURNING assignment_id INTO v_new;
    RETURN v_new;
END $$;

-- ---------------------------------------------------------------------
-- LVP (Low Visibility Procedures) qualification
-- Organizer decision: LVP qualification is required for fog landings. Every operating crew
-- position with crew_type.requires_lvp (CP and FO) must hold LVP to land where LVP is in force.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lvp_in_force(p_scenario_id INT, p_iata CHAR(3)) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT e.lvp_in_force FROM airport_status_event e
                      WHERE e.scenario_id = p_scenario_id AND e.iata = p_iata
                        AND e.effective_from_utc <= scenario_now(p_scenario_id)
                      ORDER BY e.effective_from_utc DESC, e.status_event_id DESC LIMIT 1), FALSE)
$$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
