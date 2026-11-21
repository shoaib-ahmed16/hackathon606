-- 018: a crew's report time can move before sign-in and is locked after it (usability review: FDP sign-in behaviour).
--
-- The maximum flight duty period depends on the SIGN-IN bracket (SHJ local time) and the number of sectors. Before sign-in the report
-- time can still move, and with it the bracket and the limit. After sign-in the bracket is fixed: only the number of sectors can still
-- change the limit. This is enforced HERE, in the database, so no screen or API call can move a report time after sign-in:
--   * trigger lock_sign_in  refuses any change of crew_assignment.sign_in_utc once the (scenario) clock has reached the old sign-in
--   * change_report_time()  the one supported way to move it: before sign-in only, a reason is required, at most 12 hours either way,
--                           never into the past; it recomputes legality and returns the bracket and limit before and after
-- Who did it and why is kept on the assignment (changed_by, change_reason) and in the audit trail (trg_audit on crew_assignment).
SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION trg_lock_sign_in() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_old TIMESTAMPTZ;
BEGIN
    IF NEW.sign_in_utc IS DISTINCT FROM OLD.sign_in_utc THEN
        v_old := coalesce(OLD.sign_in_utc, (SELECT sign_in_utc FROM crew_duty WHERE duty_id = OLD.duty_id));
        IF v_old IS NOT NULL AND v_old <= scenario_now(NEW.scenario_id) THEN
            RAISE EXCEPTION 'Sign-in is locked: this crew signed in at % UTC. The duty-time bracket was fixed at sign-in, so only the number of sectors can still change the limit.',
                to_char(v_old AT TIME ZONE 'UTC', 'DD Mon HH24:MI');
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS lock_sign_in ON crew_assignment;
CREATE TRIGGER lock_sign_in BEFORE UPDATE OF sign_in_utc ON crew_assignment FOR EACH ROW EXECUTE FUNCTION trg_lock_sign_in();

CREATE OR REPLACE FUNCTION change_report_time(p_scenario_id INT, p_duty_id BIGINT, p_new_sign_in_utc TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id); v_cur TIMESTAMPTZ; b RECORD; a RECORD; n INT;
BEGIN
    IF coalesce(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why the report time moves'; END IF;
    SELECT min(coalesce(ca.sign_in_utc, d.sign_in_utc)) INTO v_cur
      FROM crew_assignment ca JOIN crew_duty d USING (duty_id)
     WHERE ca.scenario_id = p_scenario_id AND ca.duty_id = p_duty_id AND ca.valid_to IS NULL;
    IF v_cur IS NULL THEN RAISE EXCEPTION 'No crew is assigned to duty % in this scenario', p_duty_id; END IF;
    IF v_cur <= v_now THEN
        RAISE EXCEPTION 'Sign-in is locked: this crew signed in at % UTC. The duty-time bracket was fixed at sign-in, so only the number of sectors can still change the limit.',
            to_char(v_cur AT TIME ZONE 'UTC', 'DD Mon HH24:MI');
    END IF;
    IF p_new_sign_in_utc <= v_now THEN
        RAISE EXCEPTION 'The new report time must be later than now (% UTC): a crew cannot be signed in retroactively', to_char(v_now AT TIME ZONE 'UTC', 'DD Mon HH24:MI');
    END IF;
    IF abs(extract(epoch FROM p_new_sign_in_utc - v_cur)) > 12 * 3600 THEN
        RAISE EXCEPTION 'A report time can move by at most 12 hours from the planned one';
    END IF;

    SELECT fc.sign_in_utc, fc.max_fdp_min, fc.legal_end_utc, r.local_start_from, r.local_start_to INTO b
      FROM fdp_calculation fc LEFT JOIN fdp_rule r ON r.rule_id = fc.rule_id
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.crew_id IS NOT NULL AND fc.is_current
     ORDER BY fc.margin_min NULLS LAST LIMIT 1;

    UPDATE crew_assignment SET sign_in_utc = p_new_sign_in_utc, changed_by = actor_user_id(), change_reason = left('Report time moved: ' || btrim(p_reason), 300)
     WHERE scenario_id = p_scenario_id AND duty_id = p_duty_id AND valid_to IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    PERFORM compute_duty_legality(p_scenario_id, p_duty_id, 'report_time_change');

    SELECT fc.sign_in_utc, fc.max_fdp_min, fc.legal_end_utc, fc.status::text AS status, r.local_start_from, r.local_start_to INTO a
      FROM fdp_calculation fc LEFT JOIN fdp_rule r ON r.rule_id = fc.rule_id
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.crew_id IS NOT NULL AND fc.is_current
     ORDER BY fc.margin_min NULLS LAST LIMIT 1;
    RETURN jsonb_build_object('duty_id', p_duty_id, 'crew_updated', n,
        'before', jsonb_build_object('report_utc', v_cur, 'bracket_from', b.local_start_from, 'bracket_to', b.local_start_to, 'max_fdp_min', b.max_fdp_min, 'legal_end_utc', b.legal_end_utc),
        'after',  jsonb_build_object('report_utc', p_new_sign_in_utc, 'bracket_from', a.local_start_from, 'bracket_to', a.local_start_to, 'max_fdp_min', a.max_fdp_min, 'legal_end_utc', a.legal_end_utc, 'status', a.status));
END $$;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
