-- 019: one clock for the screen and the database (usability review U9).
--
-- Problem: a replay or what-if keeps its time in scenario.sim_clock_utc, FROZEN. The screen showed that time plus the seconds since the
-- page loaded, so after eight minutes it said 02:53Z while approvals and executions were stamped 02:45Z, and the order of events could
-- not be read from the record.
-- Now the clock has two modes and both sides agree:
--   PAUSED (default, as before): the clock stands still at sim_clock_utc. The screen stands still too. Deterministic for a demo script.
--   RUNNING: scenario_now() = sim_clock_utc + the real time elapsed since clock_anchor_at, in the database and on the screen, so every
--            stamp (approvals, execution, notifications, outbox) follows the same time the screen shows.
-- set_scenario_clock() runs, pauses, sets or advances it. Every change queues a re-check so stored margins follow the new time.
-- Notifications and outbox entries are now stamped with the scenario time like the other records (non-live scenarios), so they no
-- longer show server time next to scenario time.
SET search_path = fogops, public;

ALTER TABLE scenario ADD COLUMN IF NOT EXISTS clock_running   BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE scenario ADD COLUMN IF NOT EXISTS clock_anchor_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION scenario_now(p_scenario_id INT) RETURNS TIMESTAMPTZ LANGUAGE sql STABLE SET search_path = fogops, public AS $$
    SELECT coalesce((SELECT CASE WHEN s.sim_clock_utc IS NOT NULL AND s.clock_running AND s.clock_anchor_at IS NOT NULL
                                 THEN s.sim_clock_utc + (now() - s.clock_anchor_at) ELSE s.sim_clock_utc END
                       FROM scenario s WHERE s.scenario_id = p_scenario_id), now())
$$;

CREATE OR REPLACE FUNCTION scenario_stamp(p_scenario_id INT) RETURNS TIMESTAMPTZ LANGUAGE sql STABLE SET search_path = fogops, public AS $$
    SELECT CASE WHEN s.kind = 'LIVE' OR s.sim_clock_utc IS NULL THEN clock_timestamp() ELSE scenario_now(s.scenario_id) END
      FROM scenario s WHERE s.scenario_id = p_scenario_id
$$;

CREATE OR REPLACE FUNCTION set_scenario_clock(p_scenario_id INT, p_action TEXT, p_to TIMESTAMPTZ DEFAULT NULL, p_minutes INT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE s scenario%ROWTYPE; v_now TIMESTAMPTZ;
BEGIN
    SELECT * INTO s FROM scenario WHERE scenario_id = p_scenario_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown scenario %', p_scenario_id; END IF;
    IF s.sim_clock_utc IS NULL THEN RAISE EXCEPTION 'This scenario runs on the real clock; there is nothing to set'; END IF;
    v_now := scenario_now(p_scenario_id);
    IF p_action = 'run' THEN
        UPDATE scenario SET sim_clock_utc = v_now, clock_running = TRUE, clock_anchor_at = now() WHERE scenario_id = p_scenario_id;
    ELSIF p_action = 'pause' THEN
        UPDATE scenario SET sim_clock_utc = v_now, clock_running = FALSE, clock_anchor_at = NULL WHERE scenario_id = p_scenario_id;
    ELSIF p_action = 'advance' THEN
        IF coalesce(p_minutes, 0) <= 0 OR p_minutes > 1440 THEN RAISE EXCEPTION 'Advance by 1 to 1440 minutes'; END IF;
        UPDATE scenario SET sim_clock_utc = v_now + make_interval(mins => p_minutes), clock_anchor_at = CASE WHEN clock_running THEN now() END WHERE scenario_id = p_scenario_id;
    ELSIF p_action = 'set' THEN
        IF p_to IS NULL THEN RAISE EXCEPTION 'Give the time to set'; END IF;
        IF s.kind = 'LIVE' AND p_to < v_now THEN RAISE EXCEPTION 'The live clock only moves forward'; END IF;
        UPDATE scenario SET sim_clock_utc = p_to, clock_anchor_at = CASE WHEN clock_running THEN now() END WHERE scenario_id = p_scenario_id;
    ELSE
        RAISE EXCEPTION 'Unknown clock action %: use run, pause, advance or set', p_action;
    END IF;
    PERFORM enqueue_reassessment(p_scenario_id, 'CLOCK', 'scenario', p_scenario_id::text, jsonb_build_object('action', p_action));
    SELECT * INTO s FROM scenario WHERE scenario_id = p_scenario_id;
    RETURN jsonb_build_object('scenario_id', p_scenario_id, 'clock_utc', scenario_now(p_scenario_id), 'running', s.clock_running);
END $$;

DROP TRIGGER IF EXISTS stamp_notification ON notification_outbox;
CREATE TRIGGER stamp_notification BEFORE INSERT ON notification_outbox FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('created_at');
DROP TRIGGER IF EXISTS stamp_integration ON integration_outbox;
CREATE TRIGGER stamp_integration BEFORE INSERT ON integration_outbox FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('created_at');

-- a what-if copies the EFFECTIVE time of its parent, not the stored one
CREATE OR REPLACE FUNCTION clone_scenario(p_src INT, p_name TEXT, p_kind TEXT DEFAULT 'WHATIF',
                                          p_overrides JSONB DEFAULT '{}'::jsonb)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_new INT;
BEGIN
    PERFORM set_config('fogops.skip_audit', 'on', true);     -- bulk copy is not a user action
    INSERT INTO scenario (name, kind, parent_scenario_id, description, sim_clock_utc, overrides, created_by)
    SELECT p_name, p_kind, scenario_id, 'Cloned from ' || name, CASE WHEN sim_clock_utc IS NULL THEN NULL ELSE scenario_now(p_src) END, p_overrides, actor_user_id()
      FROM scenario WHERE scenario_id = p_src
    RETURNING scenario_id INTO v_new;
    INSERT INTO flight_state SELECT v_new, flight_id, registration, etd_utc, eta_utc, atd_utc, toff_utc,
        tdown_utc, ata_utc, actual_arr_iata, is_holding, holding_since_utc, is_cancelled, pax, status,
        field_ts, NULL, last_event_ts, last_received_at, now()
      FROM flight_state WHERE scenario_id = p_src;
    -- airport status history is copied as events so the clone has the same starting picture
    INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force,
        arrival_capacity_per_hr, departure_capacity_per_hr, parking_available, weather_above_minima, handling_ok, fuel_ok,
        effective_from_utc, expected_reopen_utc, quality, entered_by, note)
    SELECT v_new, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr, departure_capacity_per_hr,
           parking_available, weather_above_minima, handling_ok, fuel_ok, effective_from_utc,
           expected_reopen_utc, quality, entered_by, 'cloned from scenario ' || p_src
      FROM airport_status_event WHERE scenario_id = p_src;
    INSERT INTO crew_duty_leg (scenario_id, duty_id, leg_seq, flight_id, leg_source, is_active,
                               added_by_decision_id, added_at)
    SELECT v_new, duty_id, leg_seq, flight_id, leg_source, is_active, NULL, added_at
      FROM crew_duty_leg WHERE scenario_id = p_src;
    INSERT INTO crew_assignment (scenario_id, duty_id, crew_id, position_code, valid_from, source,
                                 sign_in_utc, report_station_iata, from_leg_seq, sheet_max_fdp_min,
                                 changed_by, change_reason)
    SELECT v_new, duty_id, crew_id, position_code, valid_from, source, sign_in_utc, report_station_iata,
           from_leg_seq, sheet_max_fdp_min, changed_by, change_reason
      FROM crew_assignment WHERE scenario_id = p_src AND valid_to IS NULL;
    -- carry the current legality picture over so the clone starts consistent
    INSERT INTO fdp_calculation (scenario_id, duty_id, crew_id, position_code, rule_set_id, rule_id, sign_in_utc,
        band_tz, sign_in_local_time, legs_counted, max_fdp_min, legal_end_utc, discretion_end_utc,
        projected_end_utc, margin_min, discretion_margin_min, status, reasons, inputs, triggered_by)
    SELECT v_new, duty_id, crew_id, position_code, rule_set_id, rule_id, sign_in_utc, band_tz, sign_in_local_time,
        legs_counted, max_fdp_min, legal_end_utc, discretion_end_utc, projected_end_utc, margin_min,
        discretion_margin_min, status, reasons, inputs, 'cloned from scenario ' || p_src
      FROM fdp_calculation WHERE scenario_id = p_src AND is_current;
    PERFORM set_config('fogops.skip_audit', 'off', true);
    INSERT INTO audit_log (scenario_time_utc, actor_user_id, actor_role, scenario_id, entity_type, entity_id,
                           action, after_data)
    VALUES (clock_timestamp(), actor_user_id(), actor_role(), v_new, 'scenario', v_new::text, 'CLONE',
            jsonb_build_object('source_scenario_id', p_src, 'name', p_name, 'kind', p_kind, 'overrides', p_overrides));
    RETURN v_new;
END $$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
