-- =====================================================================
-- Functions & triggers
--   A. Session actor + clock helpers
--   B. Audit + append-only guards
--   C. Guardrails (rule-set immutability, human-only decisions)
--   D. Reassessment queue (LISTEN fogops_reassess)
--   E. Flight feed ingestion (dedupe, out-of-order, derived status)
--   F. Crew legality engine (FDP) + latest departure
--   G. Operational actions (diversion, crew swap, standby search)
--   H. Recovery sequencing
--   I. Scenario cloning + report generation
-- =====================================================================
SET search_path = fogops, public;

-- ---------------------------------------------------------------------
-- A. Helpers
-- ---------------------------------------------------------------------
-- The API calls this at the start of each transaction:  SELECT fogops.set_actor(42);
CREATE OR REPLACE FUNCTION set_actor(p_user_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_role TEXT;
BEGIN
    SELECT role_code INTO v_role FROM app_user WHERE user_id = p_user_id AND is_active;
    IF v_role IS NULL THEN RAISE EXCEPTION 'Unknown or inactive user %', p_user_id; END IF;
    PERFORM set_config('fogops.actor_user_id', p_user_id::text, true);
    PERFORM set_config('fogops.actor_role', v_role, true);
END $$;

CREATE OR REPLACE FUNCTION actor_user_id() RETURNS INT LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('fogops.actor_user_id', true), '')::int $$;

CREATE OR REPLACE FUNCTION actor_role() RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('fogops.actor_role', true), '') $$;

-- Scenario clock: replays run on a simulated clock, LIVE uses wall clock
CREATE OR REPLACE FUNCTION scenario_now(p_scenario_id INT) RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT sim_clock_utc FROM scenario WHERE scenario_id = p_scenario_id), now()) $$;

-- Timestamp for records created *in* a scenario: wall clock in LIVE, simulated clock in REPLAY/WHATIF
CREATE OR REPLACE FUNCTION scenario_stamp(p_scenario_id INT) RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN s.kind = 'LIVE' OR s.sim_clock_utc IS NULL THEN clock_timestamp() ELSE s.sim_clock_utc END
     FROM scenario s WHERE s.scenario_id = p_scenario_id $$;

CREATE OR REPLACE FUNCTION to_local(p_ts TIMESTAMPTZ, p_iata CHAR(3)) RETURNS TIMESTAMP LANGUAGE sql STABLE AS
$$ SELECT p_ts AT TIME ZONE (SELECT tz FROM airport WHERE iata = p_iata) $$;

CREATE OR REPLACE FUNCTION fmt_min(p_min INT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p_min IS NULL THEN NULL
               ELSE (CASE WHEN p_min < 0 THEN '-' ELSE '' END)
                    || lpad((abs(p_min)/60)::text, 2, '0') || ':' || lpad((abs(p_min)%60)::text, 2, '0') END $$;

-- ---------------------------------------------------------------------
-- B. Audit trail + append-only protection
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
    v_old JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_row JSONB := coalesce(v_new, v_old);
    v_changed TEXT[];
    v_sid INT := (v_row->>'scenario_id')::int;
    v_cid INT := (v_row->>'case_id')::int;
BEGIN
    IF current_setting('fogops.skip_audit', true) = 'on' THEN RETURN coalesce(NEW, OLD); END IF;
    IF v_row ? 'decision_id' AND (v_sid IS NULL OR v_cid IS NULL) THEN
        SELECT scenario_id, case_id INTO v_sid, v_cid FROM decision WHERE decision_id = (v_row->>'decision_id')::bigint;
    END IF;
    IF v_sid IS NULL AND v_cid IS NOT NULL THEN
        SELECT scenario_id INTO v_sid FROM disruption_case WHERE case_id = v_cid;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(k ORDER BY k) INTO v_changed
        FROM jsonb_object_keys(v_new) k
        WHERE v_new -> k IS DISTINCT FROM v_old -> k;
        IF v_changed IS NULL THEN RETURN NEW; END IF;   -- no-op update, nothing to log
    END IF;
    INSERT INTO audit_log (scenario_time_utc, actor_user_id, actor_role, scenario_id, case_id, entity_type,
                           entity_id, action, changed_fields, before_data, after_data)
    VALUES (CASE WHEN v_sid IS NOT NULL THEN scenario_stamp(v_sid) ELSE clock_timestamp() END,
            actor_user_id(), actor_role(), v_sid, v_cid,
            TG_TABLE_NAME, v_row->>TG_ARGV[0], TG_OP, v_changed, v_old, v_new);
    RETURN coalesce(NEW, OLD);
END $$;

CREATE OR REPLACE FUNCTION trg_append_only() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only (% blocked)', TG_TABLE_NAME, TG_OP;
END $$;

-- flight_event: only the projector's bookkeeping columns may be filled in once
CREATE OR REPLACE FUNCTION trg_flight_event_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'flight_event is append-only'; END IF;
    IF OLD.apply_result IS NOT NULL
       OR (to_jsonb(NEW) - 'apply_result' - 'fields_applied') IS DISTINCT FROM
          (to_jsonb(OLD) - 'apply_result' - 'fields_applied') THEN
        RAISE EXCEPTION 'flight_event % is immutable', OLD.event_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();
CREATE TRIGGER airport_status_append_only BEFORE UPDATE OR DELETE ON airport_status_event
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();
CREATE TRIGGER flight_event_guard BEFORE UPDATE OR DELETE ON flight_event
    FOR EACH ROW EXECUTE FUNCTION trg_flight_event_guard();
CREATE TRIGGER decision_approval_append_only BEFORE UPDATE OR DELETE ON decision_approval
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();
CREATE TRIGGER case_comment_append_only BEFORE UPDATE OR DELETE ON case_comment
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- Stamp "when" columns with the scenario clock (replays/what-ifs run on simulated time).
-- arg = column to stamp. Scenario is resolved from scenario_id, case_id or decision_id.
CREATE OR REPLACE FUNCTION trg_scenario_stamp() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v JSONB := to_jsonb(NEW); v_sid INT := (v->>'scenario_id')::int;
BEGIN
    IF v_sid IS NULL AND v ? 'case_id' THEN
        SELECT scenario_id INTO v_sid FROM disruption_case WHERE case_id = (v->>'case_id')::int;
    END IF;
    IF v_sid IS NULL AND v ? 'decision_id' THEN
        SELECT scenario_id INTO v_sid FROM decision WHERE decision_id = (v->>'decision_id')::bigint;
    END IF;
    IF v_sid IS NOT NULL AND (SELECT kind FROM scenario WHERE scenario_id = v_sid) <> 'LIVE' THEN
        NEW := jsonb_populate_record(NEW, jsonb_build_object(TG_ARGV[0], scenario_stamp(v_sid)));
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER stamp_decision      BEFORE INSERT ON decision             FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('decided_at');
CREATE TRIGGER stamp_approval      BEFORE INSERT ON decision_approval    FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('approved_at');
CREATE TRIGGER stamp_comment       BEFORE INSERT ON case_comment         FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('created_at');
CREATE TRIGGER stamp_airport       BEFORE INSERT ON airport_status_event FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('entered_at');
CREATE TRIGGER stamp_rec           BEFORE INSERT ON recommendation       FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('generated_at');
CREATE TRIGGER stamp_diversion     BEFORE INSERT OR UPDATE ON diversion  FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('updated_at');
CREATE TRIGGER stamp_replacement   BEFORE INSERT ON crew_replacement     FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('created_at');
CREATE TRIGGER stamp_plan          BEFORE INSERT ON recovery_plan        FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('generated_at');
CREATE TRIGGER stamp_report        BEFORE INSERT ON report               FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('generated_at');
CREATE TRIGGER stamp_case_flight   BEFORE INSERT ON case_flight          FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('added_at');
CREATE TRIGGER stamp_case          BEFORE INSERT ON disruption_case      FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('opened_at');
CREATE TRIGGER stamp_fuel          BEFORE INSERT ON flight_fuel_estimate FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('created_at');
CREATE TRIGGER stamp_fdp           BEFORE INSERT ON fdp_calculation      FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('calculated_at');
CREATE TRIGGER stamp_ld            BEFORE INSERT ON latest_departure_calc FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('calculated_at');
CREATE TRIGGER stamp_reassess      BEFORE INSERT ON reassessment_queue   FOR EACH ROW EXECUTE FUNCTION trg_scenario_stamp('enqueued_at');

-- Audited tables (arg = primary key column)
CREATE TRIGGER audit_decision          AFTER INSERT OR UPDATE OR DELETE ON decision             FOR EACH ROW EXECUTE FUNCTION trg_audit('decision_id');
CREATE TRIGGER audit_decision_approval AFTER INSERT                     ON decision_approval    FOR EACH ROW EXECUTE FUNCTION trg_audit('approval_id');
CREATE TRIGGER audit_recommendation    AFTER INSERT OR UPDATE OR DELETE ON recommendation       FOR EACH ROW EXECUTE FUNCTION trg_audit('rec_id');
CREATE TRIGGER audit_diversion         AFTER INSERT OR UPDATE OR DELETE ON diversion            FOR EACH ROW EXECUTE FUNCTION trg_audit('diversion_id');
CREATE TRIGGER audit_crew_assignment   AFTER INSERT OR UPDATE OR DELETE ON crew_assignment      FOR EACH ROW EXECUTE FUNCTION trg_audit('assignment_id');
CREATE TRIGGER audit_crew_replacement  AFTER INSERT OR UPDATE OR DELETE ON crew_replacement     FOR EACH ROW EXECUTE FUNCTION trg_audit('replacement_id');
CREATE TRIGGER audit_crew_duty_leg     AFTER INSERT OR UPDATE OR DELETE ON crew_duty_leg        FOR EACH ROW EXECUTE FUNCTION trg_audit('duty_id');
CREATE TRIGGER audit_airport_status    AFTER INSERT                     ON airport_status_event FOR EACH ROW EXECUTE FUNCTION trg_audit('status_event_id');
CREATE TRIGGER audit_case_flight       AFTER INSERT OR UPDATE OR DELETE ON case_flight          FOR EACH ROW EXECUTE FUNCTION trg_audit('flight_id');
CREATE TRIGGER audit_case              AFTER INSERT OR UPDATE OR DELETE ON disruption_case      FOR EACH ROW EXECUTE FUNCTION trg_audit('case_id');
CREATE TRIGGER audit_comment           AFTER INSERT                     ON case_comment         FOR EACH ROW EXECUTE FUNCTION trg_audit('comment_id');
CREATE TRIGGER audit_recovery_plan     AFTER INSERT OR UPDATE OR DELETE ON recovery_plan        FOR EACH ROW EXECUTE FUNCTION trg_audit('plan_id');
CREATE TRIGGER audit_rule_set          AFTER INSERT OR UPDATE OR DELETE ON rule_set             FOR EACH ROW EXECUTE FUNCTION trg_audit('rule_set_id');
CREATE TRIGGER audit_exception         AFTER INSERT OR UPDATE           ON data_exception       FOR EACH ROW EXECUTE FUNCTION trg_audit('exception_id');
CREATE TRIGGER audit_report            AFTER INSERT                     ON report               FOR EACH ROW EXECUTE FUNCTION trg_audit('report_id');
CREATE TRIGGER audit_fuel_estimate     AFTER INSERT                     ON flight_fuel_estimate FOR EACH ROW EXECUTE FUNCTION trg_audit('estimate_id');

-- ---------------------------------------------------------------------
-- C. Guardrails
-- ---------------------------------------------------------------------
-- Approved rule sets are frozen; only retirement is allowed.
CREATE OR REPLACE FUNCTION trg_rule_set_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND OLD.status = 'APPROVED' THEN
        RAISE EXCEPTION 'Approved rule set % cannot be deleted', OLD.rule_set_id;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'APPROVED' THEN
        IF (to_jsonb(NEW) - 'status' - 'effective_to') IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'effective_to')
           OR NEW.status NOT IN ('APPROVED','RETIRED') THEN
            RAISE EXCEPTION 'Approved rule set % is immutable; create a new version', OLD.rule_set_id;
        END IF;
    END IF;
    RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER rule_set_guard BEFORE UPDATE OR DELETE ON rule_set
    FOR EACH ROW EXECUTE FUNCTION trg_rule_set_guard();

CREATE OR REPLACE FUNCTION trg_fdp_rule_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM rule_set
     WHERE rule_set_id = coalesce(NEW.rule_set_id, OLD.rule_set_id);
    IF v_status = 'APPROVED' THEN
        RAISE EXCEPTION 'Rules of an approved rule set are immutable';
    END IF;
    RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER fdp_rule_guard BEFORE INSERT OR UPDATE OR DELETE ON fdp_rule
    FOR EACH ROW EXECUTE FUNCTION trg_fdp_rule_guard();

-- Decisions: humans only, role must match the user, legal state transitions only.
CREATE OR REPLACE FUNCTION trg_decision_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_user_role TEXT; v_is_human BOOLEAN;
BEGIN
    SELECT u.role_code, r.is_human INTO v_user_role, v_is_human
      FROM app_user u JOIN app_role r ON r.code = u.role_code
     WHERE u.user_id = NEW.decided_by;
    IF NOT coalesce(v_is_human, FALSE) THEN
        RAISE EXCEPTION 'Guardrail: decisions must be made by a human user (user % is %)', NEW.decided_by, v_user_role;
    END IF;
    IF NEW.decided_role <> v_user_role THEN
        RAISE EXCEPTION 'decided_role % does not match role % of user %', NEW.decided_role, v_user_role, NEW.decided_by;
    END IF;
    IF TG_OP = 'INSERT' AND NEW.status NOT IN ('PROPOSED') THEN
        RAISE EXCEPTION 'New decisions start as PROPOSED; approval happens via decision_approval';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'PROPOSED' AND NEW.status IN ('APPROVED','REJECTED','REVOKED'))
             OR (OLD.status = 'APPROVED' AND NEW.status IN ('EXECUTED','REVOKED'))
             OR (OLD.status = 'EXECUTED' AND NEW.status = 'REVOKED')) THEN
            RAISE EXCEPTION 'Illegal decision transition % -> %', OLD.status, NEW.status;
        END IF;
        IF NEW.status = 'EXECUTED' THEN NEW.executed_at := coalesce(NEW.executed_at, scenario_stamp(NEW.scenario_id)); END IF;
        IF NEW.status = 'REVOKED' AND (NEW.revoked_by IS NULL OR NEW.revoke_reason IS NULL) THEN
            RAISE EXCEPTION 'Revoking a decision requires revoked_by and revoke_reason';
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.decision_type, NEW.rationale, NEW.decided_by, NEW.flight_id, NEW.alternate_iata)
                    IS DISTINCT FROM (OLD.decision_type, OLD.rationale, OLD.decided_by, OLD.flight_id, OLD.alternate_iata) THEN
        RAISE EXCEPTION 'Decision content is immutable; record a new decision instead';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER decision_guard BEFORE INSERT OR UPDATE ON decision
    FOR EACH ROW EXECUTE FUNCTION trg_decision_guard();

-- An approval by an authorised human moves the decision; recommendation status follows.
CREATE OR REPLACE FUNCTION trg_decision_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_ok BOOLEAN; v_user_role TEXT; d decision%ROWTYPE;
BEGIN
    SELECT u.role_code, (r.is_human AND r.can_approve) INTO v_user_role, v_ok
      FROM app_user u JOIN app_role r ON r.code = u.role_code WHERE u.user_id = NEW.approver_id;
    IF NOT coalesce(v_ok, FALSE) THEN
        RAISE EXCEPTION 'Guardrail: user % (%) is not authorised to approve decisions', NEW.approver_id, v_user_role;
    END IF;
    IF NEW.approver_role <> v_user_role THEN
        RAISE EXCEPTION 'approver_role % does not match user role %', NEW.approver_role, v_user_role;
    END IF;
    SELECT * INTO d FROM decision WHERE decision_id = NEW.decision_id FOR UPDATE;
    IF d.status <> 'PROPOSED' THEN
        RAISE EXCEPTION 'Decision % is already %', d.decision_id, d.status;
    END IF;
    UPDATE decision SET status = NEW.verdict::decision_status WHERE decision_id = NEW.decision_id;
    IF d.rec_id IS NOT NULL THEN
        UPDATE recommendation
           SET status = CASE WHEN NEW.verdict = 'APPROVED' AND coalesce(d.followed_recommendation, TRUE)
                             THEN 'ACCEPTED'::rec_status ELSE 'REJECTED'::rec_status END
         WHERE rec_id = d.rec_id AND status = 'PROPOSED';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER decision_approval_apply AFTER INSERT ON decision_approval
    FOR EACH ROW EXECUTE FUNCTION trg_decision_approval();

-- A new recommendation supersedes the open one for the same flight
CREATE OR REPLACE FUNCTION trg_recommendation_supersede() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE recommendation SET status = 'SUPERSEDED', superseded_by = NULL
     WHERE scenario_id = NEW.scenario_id AND flight_id = NEW.flight_id
       AND status = 'PROPOSED' AND rec_id <> coalesce(NEW.rec_id, -1);
    RETURN NEW;
END $$;
CREATE TRIGGER recommendation_supersede BEFORE INSERT ON recommendation
    FOR EACH ROW EXECUTE FUNCTION trg_recommendation_supersede();

CREATE OR REPLACE FUNCTION trg_recommendation_link() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE recommendation SET superseded_by = NEW.rec_id
     WHERE scenario_id = NEW.scenario_id AND flight_id = NEW.flight_id
       AND status = 'SUPERSEDED' AND superseded_by IS NULL AND rec_id <> NEW.rec_id;
    RETURN NULL;
END $$;
CREATE TRIGGER recommendation_link AFTER INSERT ON recommendation
    FOR EACH ROW EXECUTE FUNCTION trg_recommendation_link();

-- ---------------------------------------------------------------------
-- D. Reassessment queue + NOTIFY
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enqueue_reassessment(p_scenario_id INT, p_reason TEXT, p_entity_type TEXT,
                                                p_entity_id TEXT, p_detail JSONB DEFAULT '{}'::jsonb)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_job BIGINT;
BEGIN
    INSERT INTO reassessment_queue (scenario_id, reason, entity_type, entity_id, detail)
    VALUES (p_scenario_id, p_reason, p_entity_type, p_entity_id, p_detail)
    RETURNING job_id INTO v_job;
    PERFORM pg_notify('fogops_reassess', json_build_object(
        'job_id', v_job, 'scenario_id', p_scenario_id, 'reason', p_reason,
        'entity_type', p_entity_type, 'entity_id', p_entity_id)::text);
    RETURN v_job;
END $$;

CREATE OR REPLACE FUNCTION trg_reassess_airport() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM enqueue_reassessment(NEW.scenario_id, 'AIRPORT_STATUS', 'airport', NEW.iata,
        jsonb_build_object('op_status', NEW.op_status, 'lvp_in_force', NEW.lvp_in_force,
                           'expected_reopen_utc', NEW.expected_reopen_utc,
                           'arrival_capacity_per_hr', NEW.arrival_capacity_per_hr));
    RETURN NULL;
END $$;
CREATE TRIGGER reassess_airport AFTER INSERT ON airport_status_event
    FOR EACH ROW EXECUTE FUNCTION trg_reassess_airport();

CREATE OR REPLACE FUNCTION trg_reassess_crew() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM enqueue_reassessment(NEW.scenario_id, 'CREW_CHANGE', 'crew_duty', NEW.duty_id::text,
                                 jsonb_build_object('table', TG_TABLE_NAME, 'op', TG_OP,
                                                    'crew_id', NEW.crew_id, 'valid_to', NEW.valid_to));
    RETURN NULL;
END $$;
CREATE TRIGGER reassess_crew_assignment AFTER INSERT OR UPDATE ON crew_assignment
    FOR EACH ROW WHEN (pg_trigger_depth() < 2) EXECUTE FUNCTION trg_reassess_crew();

CREATE OR REPLACE FUNCTION trg_reassess_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('APPROVED','EXECUTED','REVOKED') THEN
        PERFORM enqueue_reassessment(NEW.scenario_id, 'DECISION_' || NEW.status, 'decision',
                                     NEW.decision_id::text,
                                     jsonb_build_object('flight_id', NEW.flight_id, 'type', NEW.decision_type));
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER reassess_decision AFTER UPDATE ON decision
    FOR EACH ROW EXECUTE FUNCTION trg_reassess_decision();

-- ---------------------------------------------------------------------
-- E. Flight feed ingestion
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derive_flight_status(s flight_state, p_planned_arr CHAR(3))
RETURNS flight_status LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN s.is_cancelled                                             THEN 'CANCELLED'
        WHEN s.ata_utc   IS NOT NULL                                    THEN 'ON_BLOCKS'
        WHEN s.tdown_utc IS NOT NULL                                    THEN 'LANDED'
        WHEN s.actual_arr_iata IS NOT NULL AND s.actual_arr_iata <> p_planned_arr THEN 'DIVERTING'
        WHEN s.is_holding                                               THEN 'HOLDING'
        WHEN s.toff_utc  IS NOT NULL                                    THEN 'AIRBORNE'
        WHEN s.atd_utc   IS NOT NULL                                    THEN 'TAXI_OUT'
        ELSE 'SCHEDULED' END::flight_status
$$;

-- Idempotent, order-tolerant ingest. Returns DUPLICATE / APPLIED / PARTIAL_OUT_OF_ORDER / IGNORED_STALE.
-- Each field keeps the event_ts that last set it; an older event never overwrites a newer value.
CREATE OR REPLACE FUNCTION ingest_flight_event(
    p_scenario_id INT, p_source TEXT, p_message_id TEXT, p_flight_id BIGINT,
    p_event_type TEXT, p_event_ts TIMESTAMPTZ, p_payload JSONB,
    p_seq_no BIGINT DEFAULT NULL, p_received_at TIMESTAMPTZ DEFAULT NULL)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_event_id BIGINT;
    s flight_state%ROWTYPE;
    v_before flight_state%ROWTYPE;
    f flight%ROWTYPE;
    k TEXT; v_val JSONB; v_prev_ts TIMESTAMPTZ;
    v_applied TEXT[] := '{}'; v_skipped TEXT[] := '{}';
    v_result TEXT;
    c_fields CONSTANT TEXT[] := ARRAY['etd','eta','atd','toff','tdown','ata','registration',
                                      'pax','actual_arr_iata','holding','cancelled'];
    v_recv TIMESTAMPTZ := coalesce(p_received_at, scenario_stamp(p_scenario_id));
BEGIN
    INSERT INTO flight_event (scenario_id, flight_id, source_code, message_id, seq_no,
                              event_type, event_ts, received_at, payload)
    VALUES (p_scenario_id, p_flight_id, p_source, p_message_id, p_seq_no,
            p_event_type, p_event_ts, v_recv, p_payload)
    ON CONFLICT (scenario_id, source_code, message_id) DO NOTHING
    RETURNING event_id INTO v_event_id;
    IF v_event_id IS NULL THEN
        RETURN 'DUPLICATE';
    END IF;

    SELECT * INTO f FROM flight WHERE flight_id = p_flight_id;
    INSERT INTO flight_state (scenario_id, flight_id, registration)
    VALUES (p_scenario_id, p_flight_id, f.registration_planned)
    ON CONFLICT DO NOTHING;
    SELECT * INTO s FROM flight_state
     WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id FOR UPDATE;
    v_before := s;

    FOR k IN SELECT jsonb_object_keys(p_payload) LOOP
        CONTINUE WHEN NOT k = ANY (c_fields);
        v_prev_ts := (s.field_ts ->> k)::timestamptz;
        IF v_prev_ts IS NOT NULL AND v_prev_ts > p_event_ts THEN
            v_skipped := v_skipped || k;        -- older than what we already have
            CONTINUE;
        END IF;
        v_val := p_payload -> k;
        CASE k
            WHEN 'etd'   THEN s.etd_utc   := (v_val #>> '{}')::timestamptz;
            WHEN 'eta'   THEN s.eta_utc   := (v_val #>> '{}')::timestamptz;
            WHEN 'atd'   THEN s.atd_utc   := (v_val #>> '{}')::timestamptz;
            WHEN 'toff'  THEN s.toff_utc  := (v_val #>> '{}')::timestamptz;
            WHEN 'tdown' THEN s.tdown_utc := (v_val #>> '{}')::timestamptz;
            WHEN 'ata'   THEN s.ata_utc   := (v_val #>> '{}')::timestamptz;
            WHEN 'registration'    THEN s.registration    := v_val #>> '{}';
            WHEN 'pax'             THEN s.pax             := (v_val #>> '{}')::int;
            WHEN 'actual_arr_iata' THEN s.actual_arr_iata := v_val #>> '{}';
            WHEN 'holding' THEN
                s.is_holding := coalesce((v_val #>> '{}')::boolean, FALSE);
                s.holding_since_utc := CASE WHEN s.is_holding
                                            THEN coalesce(s.holding_since_utc, p_event_ts) END;
            WHEN 'cancelled' THEN s.is_cancelled := coalesce((v_val #>> '{}')::boolean, FALSE);
        END CASE;
        s.field_ts := s.field_ts || jsonb_build_object(k, p_event_ts);
        v_applied := v_applied || k;
    END LOOP;

    v_result := CASE WHEN cardinality(v_applied) = 0 AND cardinality(v_skipped) > 0 THEN 'IGNORED_STALE'
                     WHEN cardinality(v_skipped) > 0 THEN 'PARTIAL_OUT_OF_ORDER'
                     ELSE 'APPLIED' END;

    s.status := derive_flight_status(s, f.arr_iata);
    UPDATE flight_state SET
        registration = s.registration, etd_utc = s.etd_utc, eta_utc = s.eta_utc, atd_utc = s.atd_utc,
        toff_utc = s.toff_utc, tdown_utc = s.tdown_utc, ata_utc = s.ata_utc,
        actual_arr_iata = s.actual_arr_iata, is_holding = s.is_holding,
        holding_since_utc = s.holding_since_utc, is_cancelled = s.is_cancelled, pax = s.pax,
        status = s.status, field_ts = s.field_ts,
        last_event_id   = CASE WHEN cardinality(v_applied) > 0 THEN v_event_id ELSE last_event_id END,
        last_event_ts   = greatest(last_event_ts, p_event_ts),
        last_received_at = v_recv,
        updated_at = clock_timestamp()
     WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id;

    UPDATE flight_event SET apply_result = v_result, fields_applied = v_applied WHERE event_id = v_event_id;

    UPDATE feed_source SET last_event_ts = greatest(last_event_ts, p_event_ts),
                           last_received_at = greatest(last_received_at, v_recv)
     WHERE source_code = p_source;

    -- material changes trigger reassessment
    IF (s.eta_utc, s.etd_utc, s.registration, s.status, s.actual_arr_iata, s.is_holding, s.is_cancelled)
       IS DISTINCT FROM
       (v_before.eta_utc, v_before.etd_utc, v_before.registration, v_before.status,
        v_before.actual_arr_iata, v_before.is_holding, v_before.is_cancelled)
       AND p_event_type <> 'BASELINE' THEN
        PERFORM enqueue_reassessment(p_scenario_id, 'FLIGHT_CHANGED', 'flight', p_flight_id::text,
            jsonb_build_object('event_id', v_event_id, 'fields', v_applied,
                               'eta_before', v_before.eta_utc, 'eta_after', s.eta_utc,
                               'status_before', v_before.status, 'status_after', s.status));
    END IF;
    RETURN v_result;
END $$;

-- ---------------------------------------------------------------------
-- F. Crew legality engine
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION active_rule_set(p_name TEXT DEFAULT 'GCAA FDP', p_at TIMESTAMPTZ DEFAULT now())
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT rule_set_id FROM rule_set
     WHERE name = p_name AND status = 'APPROVED'
       AND effective_from <= p_at AND (effective_to IS NULL OR effective_to > p_at)
     ORDER BY effective_from DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION lookup_fdp_rule(p_rule_set_id INT, p_crew_type TEXT, p_local_time TIME, p_legs INT)
RETURNS fdp_rule LANGUAGE sql STABLE AS $$
    SELECT * FROM fdp_rule
     WHERE rule_set_id = p_rule_set_id AND crew_type_code = p_crew_type AND no_of_legs = p_legs
       AND p_local_time >= local_start_from
       -- bands are inclusive to the minute (06:00-07:59); never add a full minute: 23:59 + 1min wraps to 00:00
       AND p_local_time <= local_start_to + interval '59.999999 seconds'
     LIMIT 1
$$;

CREATE OR REPLACE FUNCTION raise_exception_item(p_scenario_id INT, p_entity_type TEXT, p_entity_id TEXT,
                                                p_code TEXT, p_sev severity_level, p_msg TEXT,
                                                p_detail JSONB DEFAULT '{}'::jsonb)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO data_exception (scenario_id, entity_type, entity_id, code, severity, message, detail)
    VALUES (p_scenario_id, p_entity_type, p_entity_id, p_code, p_sev, p_msg, p_detail)
    ON CONFLICT (coalesce(scenario_id,0), entity_type, entity_id, code) WHERE status <> 'RESOLVED'
    DO UPDATE SET detail = EXCLUDED.detail, message = EXCLUDED.message
$$;

-- Projected on-blocks of a flight in a scenario (actual > estimate > schedule), with quality label
CREATE OR REPLACE FUNCTION projected_on_blocks(p_scenario_id INT, p_flight_id BIGINT,
                                               OUT ts TIMESTAMPTZ, OUT basis TEXT, OUT stale BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT coalesce(s.ata_utc, s.eta_utc, f.sta_utc),
           CASE WHEN s.ata_utc IS NOT NULL THEN 'ACTUAL'
                WHEN s.eta_utc IS NOT NULL THEN 'ESTIMATE' ELSE 'SCHEDULE' END,
           -- stale only matters for flights in progress
           (coalesce(s.status::text,'SCHEDULED') IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING')
             AND (s.last_received_at IS NULL
                  OR scenario_now(p_scenario_id) - s.last_received_at >
                     make_interval(secs => coalesce((SELECT max(stale_after_sec) FROM feed_source), 600))))
      FROM flight f
      LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
     WHERE f.flight_id = p_flight_id
$$;

-- Computes per-crew FDP legality for a duty and a duty-level summary (crew_id NULL).
-- Old results are kept (is_current = false) for the audit trail.
CREATE OR REPLACE FUNCTION compute_duty_legality(p_scenario_id INT, p_duty_id BIGINT,
                                                 p_triggered_by TEXT DEFAULT 'manual')
RETURNS legality_status LANGUAGE plpgsql AS $$
DECLARE
    d crew_duty%ROWTYPE; rs rule_set%ROWTYPE; a RECORD; r fdp_rule%ROWTYPE;
    v_rs INT; v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_last_flight BIGINT; v_proj RECORD;
    v_sign_in TIMESTAMPTZ; v_station CHAR(3); v_tz TEXT; v_local TIME; v_legs INT;
    v_legal_end TIMESTAMPTZ; v_disc_end TIMESTAMPTZ; v_margin INT; v_dmargin INT;
    v_status legality_status; v_reasons TEXT[]; v_planned_legs INT; rp fdp_rule%ROWTYPE;
    v_notes TEXT[]; v_policy TEXT;
    v_worst legality_status; v_bind fdp_calculation%ROWTYPE; v_count INT := 0;
    c_order CONSTANT legality_status[] := ARRAY['LEGAL','AT_RISK','DISCRETION_REQUIRED',
                                                'VERIFICATION_REQUIRED','EXCEEDED']::legality_status[];
BEGIN
    SELECT * INTO d FROM crew_duty WHERE duty_id = p_duty_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'duty % not found', p_duty_id; END IF;
    v_rs := active_rule_set('GCAA FDP', v_now);
    IF v_rs IS NULL THEN RAISE EXCEPTION 'No approved FDP rule set effective at %', v_now; END IF;
    SELECT * INTO rs FROM rule_set WHERE rule_set_id = v_rs;
    -- BLOCK: a duty sheet that disagrees with the approved rules forces VERIFICATION_REQUIRED
    -- WARN : the rule set is authoritative; the disagreement is shown and logged, not blocking
    v_policy := coalesce(rs.parameters->>'sheet_mismatch_policy', 'BLOCK');

    UPDATE fdp_calculation SET is_current = FALSE
     WHERE scenario_id = p_scenario_id AND duty_id = p_duty_id AND is_current;

    -- last active leg of the duty decides the end of FDP
    SELECT l.flight_id INTO v_last_flight FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
     ORDER BY l.leg_seq DESC LIMIT 1;
    SELECT * INTO v_proj FROM projected_on_blocks(p_scenario_id, v_last_flight);

    FOR a IN
        SELECT ca.*, cm.full_name, cm.base_iata, ct.code AS ct_code
          FROM crew_assignment ca
          JOIN crew_member cm USING (crew_id)
          LEFT JOIN crew_type ct ON ct.code = ca.position_code
         WHERE ca.scenario_id = p_scenario_id AND ca.duty_id = p_duty_id AND ca.valid_to IS NULL
    LOOP
        v_reasons := '{}'; v_notes := '{}'; v_status := NULL;
        r := NULL; v_legal_end := NULL; v_disc_end := NULL; v_margin := NULL; v_dmargin := NULL;
        v_sign_in := coalesce(a.sign_in_utc, d.sign_in_utc);
        v_station := coalesce(a.report_station_iata, d.report_station_iata);
        v_tz := CASE rs.band_reference
                    WHEN 'FIXED_TZ'  THEN rs.band_tz
                    WHEN 'HOME_BASE' THEN (SELECT tz FROM airport WHERE iata = a.base_iata)
                    ELSE (SELECT tz FROM airport WHERE iata = v_station) END;
        SELECT count(*) INTO v_legs FROM crew_duty_leg l
         WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
           AND l.leg_seq >= a.from_leg_seq
           AND (rs.count_positioning_as_leg OR l.leg_source <> 'POSITIONING');

        IF v_sign_in IS NULL THEN v_reasons := array_append(v_reasons, 'SIGN_IN_MISSING'); END IF;
        IF v_tz IS NULL THEN v_reasons := array_append(v_reasons, 'BAND_TIMEZONE_UNKNOWN'); END IF;
        IF v_sign_in IS NOT NULL AND v_tz IS NOT NULL THEN
            v_local := (v_sign_in AT TIME ZONE v_tz)::time;
            r := lookup_fdp_rule(v_rs, a.position_code, v_local, v_legs);
            IF r.rule_id IS NULL THEN
                v_reasons := v_reasons || format('NO_RULE:%s/%s legs', a.position_code, v_legs);
                PERFORM raise_exception_item(NULL, 'crew_assignment', a.assignment_id::text,
                    'NO_FDP_RULE', 'BLOCKING',
                    format('No approved FDP rule for crew type %s with %s legs; legality cannot be asserted',
                           a.position_code, v_legs),
                    jsonb_build_object('duty_id', p_duty_id, 'crew_id', a.crew_id, 'rule_set_id', v_rs));
            ELSE
                v_legal_end := v_sign_in + make_interval(mins => r.max_fdp_min);
                v_disc_end  := v_legal_end + make_interval(mins => rs.commander_discretion_min);
                -- Cross-check the duty sheet against the rule for the PLANNED pairing (before any
                -- diversion legs). A disagreement is an inconsistent input => verification required.
                IF a.sheet_max_fdp_min IS NOT NULL AND a.source = 'DUTY_SHEET' THEN
                    SELECT count(*) INTO v_planned_legs FROM crew_duty_leg l
                     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.leg_source = 'PLANNED';
                    rp := lookup_fdp_rule(v_rs, a.position_code, v_local, v_planned_legs);
                    IF rp.rule_id IS NULL OR a.sheet_max_fdp_min <> rp.max_fdp_min THEN
                        IF v_policy = 'BLOCK' THEN
                            v_reasons := array_append(v_reasons, 'SHEET_DISAGREES_WITH_RULESET');
                        ELSE
                            v_notes := array_append(v_notes, format('Duty sheet max FDP %s differs from rule %s',
                                                     fmt_min(a.sheet_max_fdp_min), fmt_min(rp.max_fdp_min)));
                        END IF;
                        PERFORM raise_exception_item(NULL, 'crew_assignment', a.assignment_id::text,
                            'SHEET_MAXFDP_MISMATCH',
                            CASE WHEN v_policy = 'BLOCK' THEN 'BLOCKING' ELSE 'WARN' END::severity_level,
                            format('Duty sheet max FDP %s vs approved rule %s (rule %s, %s legs, local sign-in %s %s)',
                                   fmt_min(a.sheet_max_fdp_min), coalesce(fmt_min(rp.max_fdp_min), 'n/a'),
                                   rp.source_rule_id, v_planned_legs, to_char(v_local, 'HH24:MI'), v_tz),
                            jsonb_build_object('duty_id', p_duty_id, 'crew_id', a.crew_id,
                                               'sheet_min', a.sheet_max_fdp_min, 'rule_min', rp.max_fdp_min,
                                               'conservative_min', least(a.sheet_max_fdp_min, rp.max_fdp_min)));
                    END IF;
                END IF;
            END IF;
        END IF;
        IF v_proj.ts IS NULL THEN v_reasons := array_append(v_reasons, 'PROJECTED_END_UNKNOWN'); END IF;
        IF v_proj.stale THEN v_reasons := array_append(v_reasons, 'FLIGHT_FEED_STALE'); END IF;

        IF v_legal_end IS NOT NULL AND v_proj.ts IS NOT NULL THEN
            v_margin  := floor(extract(epoch FROM v_legal_end - v_proj.ts) / 60);
            v_dmargin := floor(extract(epoch FROM v_disc_end  - v_proj.ts) / 60);
            v_status := CASE WHEN v_dmargin < 0 THEN 'EXCEEDED'
                             WHEN v_margin  < 0 THEN 'DISCRETION_REQUIRED'
                             WHEN v_margin  < rs.at_risk_threshold_min THEN 'AT_RISK'
                             ELSE 'LEGAL' END;
        END IF;
        -- Guardrail: any missing/conflicting input blocks a definitive legality claim
        IF cardinality(v_reasons) > 0 AND coalesce(v_status::text,'') <> 'EXCEEDED' THEN
            v_status := 'VERIFICATION_REQUIRED';
        END IF;

        INSERT INTO fdp_calculation (scenario_id, duty_id, crew_id, position_code, rule_set_id, rule_id,
            sign_in_utc, band_tz, sign_in_local_time, legs_counted, max_fdp_min, legal_end_utc,
            discretion_end_utc, projected_end_utc, margin_min, discretion_margin_min, status, reasons,
            inputs, triggered_by)
        VALUES (p_scenario_id, p_duty_id, a.crew_id, a.position_code, v_rs, r.rule_id,
            v_sign_in, v_tz, v_local, v_legs, r.max_fdp_min, v_legal_end, v_disc_end, v_proj.ts,
            v_margin, v_dmargin, v_status, v_reasons,
            jsonb_build_object('rule_set', rs.name || ' ' || rs.version,
                               'source_rule_id', r.source_rule_id,
                               'band', CASE WHEN r.rule_id IS NOT NULL THEN
                                       to_char(r.local_start_from,'HH24:MI') || '-' || to_char(r.local_start_to,'HH24:MI') END,
                               'band_reference', rs.band_reference || coalesce(' ' || rs.band_tz, ''),
                               'report_station', v_station,
                               'commander_discretion_min', rs.commander_discretion_min,
                               'last_leg_flight_id', v_last_flight,
                               'projected_end_basis', v_proj.basis,
                               'from_leg_seq', a.from_leg_seq,
                               'sheet_max_fdp_min', a.sheet_max_fdp_min,
                               'notes', to_jsonb(v_notes),
                               'conservative_legal_end_utc', CASE WHEN a.sheet_max_fdp_min IS NOT NULL AND v_sign_in IS NOT NULL
                                    THEN v_sign_in + make_interval(mins => least(a.sheet_max_fdp_min, coalesce(r.max_fdp_min, a.sheet_max_fdp_min))) END,
                               'evaluated_at', v_now),
            p_triggered_by);
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        v_worst := 'VERIFICATION_REQUIRED';
        PERFORM raise_exception_item(NULL, 'crew_duty', p_duty_id::text, 'NO_CREW_ASSIGNED', 'BLOCKING',
                                     'Duty has no active crew assignment');
    ELSE
        SELECT c_order[max(array_position(c_order, fc.status))] INTO v_worst
          FROM fdp_calculation fc JOIN crew_type ct ON ct.code = fc.position_code
         WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id
           AND fc.is_current AND fc.crew_id IS NOT NULL AND ct.gates_flight_legality;
        v_worst := coalesce(v_worst, 'VERIFICATION_REQUIRED');
    END IF;

    -- duty-level summary = the binding (smallest-margin) crew member
    SELECT fc.* INTO v_bind FROM fdp_calculation fc JOIN crew_type ct ON ct.code = fc.position_code
     WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id AND fc.is_current
       AND fc.crew_id IS NOT NULL AND ct.gates_flight_legality
     ORDER BY fc.margin_min ASC NULLS LAST, fc.legal_end_utc ASC NULLS LAST LIMIT 1;

    INSERT INTO fdp_calculation (scenario_id, duty_id, crew_id, position_code, rule_set_id, rule_id,
        sign_in_utc, band_tz, sign_in_local_time, legs_counted, max_fdp_min, legal_end_utc,
        discretion_end_utc, projected_end_utc, margin_min, discretion_margin_min, status, reasons, inputs, triggered_by)
    VALUES (p_scenario_id, p_duty_id, NULL, v_bind.position_code, v_rs, v_bind.rule_id,
        v_bind.sign_in_utc, v_bind.band_tz, v_bind.sign_in_local_time, v_bind.legs_counted, v_bind.max_fdp_min,
        v_bind.legal_end_utc, v_bind.discretion_end_utc, coalesce(v_bind.projected_end_utc, v_proj.ts),
        v_bind.margin_min, v_bind.discretion_margin_min, v_worst,
        coalesce((SELECT array_agg(DISTINCT x) FROM fdp_calculation fc
                    JOIN crew_type ct ON ct.code = fc.position_code AND ct.gates_flight_legality,
                    unnest(fc.reasons) x
                   WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = p_duty_id
                     AND fc.is_current AND fc.crew_id IS NOT NULL), '{}'),
        jsonb_build_object('binding_crew_id', v_bind.crew_id, 'crew_evaluated', v_count,
                           'binding_calc_id', v_bind.calc_id),
        p_triggered_by);
    RETURN v_worst;
END $$;

-- Recompute every duty that touches a flight
CREATE OR REPLACE FUNCTION compute_flight_legality(p_scenario_id INT, p_flight_id BIGINT,
                                                   p_triggered_by TEXT DEFAULT 'manual')
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_duty BIGINT; n INT := 0;
BEGIN
    FOR v_duty IN SELECT DISTINCT duty_id FROM crew_duty_leg
                   WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id AND is_active LOOP
        PERFORM compute_duty_legality(p_scenario_id, v_duty, p_triggered_by);
        n := n + 1;
    END LOOP;
    IF n = 0 THEN
        PERFORM raise_exception_item(p_scenario_id, 'flight', p_flight_id::text, 'NO_CREW_PAIRING',
            'BLOCKING', 'No crew duty linked to this flight; legality cannot be asserted');
    END IF;
    RETURN n;
END $$;

-- Latest legal off-blocks from the current station for a given (onward) flight.
-- Accounts for any remaining legs after this one (their block time + min ground time).
CREATE OR REPLACE FUNCTION compute_latest_departure(p_scenario_id INT, p_flight_id BIGINT,
                                                    p_buffer_min INT DEFAULT 30,
                                                    p_block_basis TEXT DEFAULT 'P90')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    f flight%ROWTYPE; v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_duty RECORD; v_best RECORD := NULL;
    v_block INT; v_basis TEXT; v_after INT; v_tail_detail JSONB;
    v_latest TIMESTAMPTZ; v_latest_d TIMESTAMPTZ; v_status legality_status;
    v_vr BOOLEAN := FALSE; v_id BIGINT; v_rs rule_set%ROWTYPE; v_bt RECORD;
    v_tail_chosen JSONB := '[]'::jsonb; v_after_chosen INT := 0;
BEGIN
    SELECT * INTO f FROM flight WHERE flight_id = p_flight_id;
    SELECT * INTO v_rs FROM rule_set WHERE rule_set_id = active_rule_set('GCAA FDP', v_now);

    SELECT * INTO v_bt FROM block_time_reference WHERE from_iata = f.dep_iata AND to_iata = f.arr_iata;
    IF FOUND THEN
        v_block := CASE WHEN p_block_basis = 'MEDIAN' THEN v_bt.median_block_min ELSE v_bt.p90_block_min END;
        v_basis := format('%s of %s historical %s-%s blocks', p_block_basis, v_bt.sample_n, f.dep_iata, f.arr_iata);
    ELSE
        v_block := ceil(extract(epoch FROM f.sta_utc - f.std_utc) / 60);
        v_basis := 'scheduled block time (no history for route)';
    END IF;

    FOR v_duty IN SELECT l.duty_id, l.leg_seq FROM crew_duty_leg l
                   WHERE l.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active LOOP
        PERFORM compute_duty_legality(p_scenario_id, v_duty.duty_id, 'latest_departure');
        -- legs after this one must still fit inside the FDP
        SELECT coalesce(sum(ceil(extract(epoch FROM f2.sta_utc - f2.std_utc)/60)
                            + coalesce(ap.min_ground_time_min, 40)), 0),
               coalesce(jsonb_agg(jsonb_build_object('flight', f2.flight_no, 'block_min',
                         ceil(extract(epoch FROM f2.sta_utc - f2.std_utc)/60),
                         'ground_min', coalesce(ap.min_ground_time_min, 40))), '[]')
          INTO v_after, v_tail_detail
          FROM crew_duty_leg l2 JOIN flight f2 ON f2.flight_id = l2.flight_id
          LEFT JOIN airport ap ON ap.iata = f2.dep_iata
         WHERE l2.scenario_id = p_scenario_id AND l2.duty_id = v_duty.duty_id
           AND l2.is_active AND l2.leg_seq > v_duty.leg_seq;

        FOR v_best IN
            SELECT fc.*, v_after AS tail_min, v_tail_detail AS tail
              FROM fdp_calculation fc JOIN crew_type ct ON ct.code = fc.position_code
             WHERE fc.scenario_id = p_scenario_id AND fc.duty_id = v_duty.duty_id
               AND fc.is_current AND fc.crew_id IS NOT NULL AND ct.gates_flight_legality
        LOOP
            IF v_best.status = 'VERIFICATION_REQUIRED' THEN v_vr := TRUE; END IF;
            IF v_best.legal_end_utc IS NOT NULL THEN
                IF v_latest IS NULL OR v_best.legal_end_utc - make_interval(mins => v_block + v_best.tail_min) < v_latest THEN
                    v_latest   := v_best.legal_end_utc - make_interval(mins => v_block + v_best.tail_min);
                    v_latest_d := v_best.discretion_end_utc - make_interval(mins => v_block + v_best.tail_min);
                    v_id := v_best.calc_id;
                    v_tail_chosen := v_best.tail; v_after_chosen := v_best.tail_min;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    SELECT * INTO v_best FROM fdp_calculation WHERE calc_id = v_id;
    v_status := CASE WHEN v_latest IS NULL THEN 'VERIFICATION_REQUIRED'
                     WHEN v_now > v_latest_d THEN 'EXCEEDED'
                     WHEN v_now > v_latest THEN 'DISCRETION_REQUIRED'
                     WHEN v_vr THEN 'VERIFICATION_REQUIRED'
                     WHEN extract(epoch FROM v_latest - v_now)/60 < v_rs.at_risk_threshold_min THEN 'AT_RISK'
                     ELSE 'LEGAL' END;

    UPDATE latest_departure_calc SET is_current = FALSE
     WHERE scenario_id = p_scenario_id AND flight_id = p_flight_id AND is_current;

    INSERT INTO latest_departure_calc (scenario_id, flight_id, from_iata, to_iata, duty_id, binding_crew_id,
        fdp_calc_id, legal_end_utc, discretion_end_utc, block_time_min, block_time_basis,
        latest_legal_offblocks_utc, latest_with_discretion_utc, operational_buffer_min,
        operational_target_utc, status, assumptions)
    VALUES (p_scenario_id, p_flight_id, f.dep_iata, f.arr_iata, v_best.duty_id, v_best.crew_id, v_id,
        v_best.legal_end_utc, v_best.discretion_end_utc, v_block, v_basis,
        v_latest, v_latest_d, p_buffer_min,
        v_latest - make_interval(mins => p_buffer_min), v_status,
        jsonb_build_object(
            'block_time', v_basis,
            'operational_buffer', format('%s min (refuel/ATC/fog margin) - configurable', p_buffer_min),
            'remaining_legs_after_this', v_tail_chosen,
            'remaining_legs_total_min', v_after_chosen,
            'discretion', 'Commander discretion is a captain decision, never planned by default',
            'verification_required', v_vr,
            'evaluated_at', v_now))
    RETURNING calc_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- G. Operational actions
-- ---------------------------------------------------------------------
-- Execute an APPROVED divert decision: records the diversion, creates the recovery leg
-- (e.g. G9071D FJR->SHJ), inserts it into every affected crew duty (+1 sector) and
-- recomputes legality.
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

-- Is the cockpit crew operating this flight cleared to land under LVP at its destination?
-- lvp_required is evaluated against the destination's current status (scenario clock).
CREATE OR REPLACE FUNCTION flight_lvp_check(p_scenario_id INT, p_flight_id BIGINT,
                                            OUT lvp_required BOOLEAN, OUT lvp_ok BOOLEAN,
                                            OUT not_qualified JSONB, OUT dest_iata CHAR(3))
LANGUAGE sql STABLE AS $$
    WITH dest AS (
        SELECT coalesce(s.actual_arr_iata, f.arr_iata) AS iata
          FROM flight f LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
         WHERE f.flight_id = p_flight_id
    ), crew AS (
        SELECT ca.crew_id, ca.position_code, cm.full_name,
               EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = ca.crew_id AND q.qual_code = 'LVP') AS has_lvp
          FROM crew_duty_leg l
          JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id
                                 AND ca.valid_to IS NULL AND ca.from_leg_seq <= l.leg_seq
          JOIN crew_type ct ON ct.code = ca.position_code AND ct.requires_lvp
          JOIN crew_member cm ON cm.crew_id = ca.crew_id
         WHERE l.scenario_id = p_scenario_id AND l.flight_id = p_flight_id AND l.is_active
    )
    SELECT lvp_in_force(p_scenario_id, d.iata),
           CASE WHEN NOT lvp_in_force(p_scenario_id, d.iata) THEN TRUE
                WHEN NOT EXISTS (SELECT 1 FROM crew) THEN NULL          -- no cockpit crew linked: unknown
                ELSE bool_and(c.has_lvp) END,
           coalesce(jsonb_agg(jsonb_build_object('crew_id', c.crew_id, 'position', c.position_code,
                                                 'name', c.full_name)) FILTER (WHERE NOT c.has_lvp), '[]'),
           d.iata
      FROM dest d LEFT JOIN crew c ON TRUE
     GROUP BY d.iata
$$;

-- Q4: who can replace a crew member at a station without breaking the planned roster?
CREATE OR REPLACE FUNCTION standby_candidates(p_scenario_id INT, p_duty_id BIGINT, p_position TEXT,
                                              p_station CHAR(3), p_from_leg_seq SMALLINT)
RETURNS TABLE (crew_id INT, full_name TEXT, position_code TEXT, standby_id BIGINT, pattern_name TEXT,
               lvp_qualified BOOLEAN, positioning_min INT, new_sign_in_utc TIMESTAMPTZ,
               legs_to_operate INT, max_fdp_min INT, legal_end_utc TIMESTAMPTZ,
               projected_end_utc TIMESTAMPTZ, margin_min INT, roster_conflict BOOLEAN,
               conflicts JSONB, verdict TEXT)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_rs INT := active_rule_set('GCAA FDP', scenario_now(p_scenario_id));
    v_rest INT; v_hub CHAR(3) := 'SHJ'; v_pos INT; v_last BIGINT; v_proj TIMESTAMPTZ; v_legs INT;
    v_band_tz TEXT; v_lvp_needed BOOLEAN;
BEGIN
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720),
           CASE WHEN band_reference = 'FIXED_TZ' THEN band_tz ELSE 'Asia/Dubai' END
      INTO v_rest, v_band_tz
      FROM rule_set WHERE rule_set_id = v_rs;
    v_pos := CASE WHEN p_station = v_hub THEN 0
                  ELSE (SELECT road_positioning_min FROM alternate_airport
                         WHERE hub_iata = v_hub AND alt_iata = p_station) END;
    SELECT count(*) INTO v_legs FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
       AND l.leg_seq >= p_from_leg_seq AND l.leg_source <> 'POSITIONING';
    SELECT l.flight_id INTO v_last FROM crew_duty_leg l
     WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
     ORDER BY l.leg_seq DESC LIMIT 1;
    SELECT ts INTO v_proj FROM projected_on_blocks(p_scenario_id, v_last);
    -- LVP is needed if this position requires it and any remaining leg lands where LVP is in force
    v_lvp_needed := (SELECT requires_lvp FROM crew_type WHERE code = p_position)
                    AND EXISTS (SELECT 1 FROM crew_duty_leg l JOIN flight f ON f.flight_id = l.flight_id
                                 WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
                                   AND l.leg_seq >= p_from_leg_seq AND lvp_in_force(p_scenario_id, f.arr_iata));

    RETURN QUERY
    WITH cand AS (
        SELECT sb.crew_id, cm.full_name, sb.crew_type_code, sb.standby_id, sb.pattern_name,
               EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = sb.crew_id AND q.qual_code = 'LVP') AS lvp,
               v_now AS sign_in,
               cm.base_iata
          FROM standby_slot sb JOIN crew_member cm ON cm.crew_id = sb.crew_id
         WHERE sb.crew_type_code = p_position AND sb.status = 'AVAILABLE'
           AND v_now BETWEEN sb.start_utc AND sb.end_utc
           AND NOT EXISTS (SELECT 1 FROM crew_assignment ca JOIN crew_duty cd ON cd.duty_id = ca.duty_id
                            WHERE ca.scenario_id = p_scenario_id AND ca.crew_id = sb.crew_id AND ca.valid_to IS NULL
                              AND cd.sign_in_utc BETWEEN v_now - interval '14 hours' AND v_now + interval '14 hours')
    ), calc AS (
        SELECT c.*, r.max_fdp_min AS mx,
               c.sign_in + make_interval(mins => r.max_fdp_min) AS legal_end
          FROM cand c
          LEFT JOIN LATERAL lookup_fdp_rule(v_rs, c.crew_type_code,
                       (c.sign_in AT TIME ZONE v_band_tz)::time, v_legs) r ON TRUE
    ), conf AS (
        SELECT c.crew_id,
               coalesce(jsonb_agg(jsonb_build_object('duty_type', re.duty_type, 'block', re.block_name,
                        'start_local', re.start_local, 'end_local', re.end_local))
                        FILTER (WHERE re.roster_id IS NOT NULL), '[]') AS conflicts
          FROM calc c
          LEFT JOIN roster_entry re ON re.crew_id = c.crew_id
               AND re.duty_type IN ('FLIGHT','TRAINING','SIM','DUTY','GRT')
               AND re.start_utc < coalesce(greatest(v_proj, c.legal_end), c.legal_end) + make_interval(mins => v_rest)
               AND re.end_utc > v_now
         GROUP BY c.crew_id
    )
    SELECT c.crew_id, c.full_name, c.crew_type_code, c.standby_id, c.pattern_name, c.lvp,
           v_pos, c.sign_in, v_legs, c.mx, c.legal_end, v_proj,
           floor(extract(epoch FROM c.legal_end - v_proj)/60)::int,
           jsonb_array_length(cf.conflicts) > 0, cf.conflicts,
           CASE WHEN v_pos IS NULL THEN 'VERIFY: no positioning time configured for ' || p_station
                WHEN v_lvp_needed AND NOT c.lvp THEN 'NOT LVP QUALIFIED (LVP in force at destination)'
                WHEN c.mx IS NULL THEN 'VERIFY: no FDP rule for this crew type/legs'
                WHEN c.legal_end < v_proj THEN 'NOT LEGAL for remaining legs'
                WHEN jsonb_array_length(cf.conflicts) > 0 THEN 'LEGAL but breaks planned roster'
                ELSE 'CANDIDATE' END
      FROM calc c JOIN conf cf USING (crew_id)
     ORDER BY (v_lvp_needed AND NOT c.lvp), (jsonb_array_length(cf.conflicts) > 0), (c.legal_end < v_proj), c.lvp DESC,
              floor(extract(epoch FROM c.legal_end - v_proj)/60) DESC;
END $$;

-- ---------------------------------------------------------------------
-- H. Recovery sequencing after the hub reopens
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_recovery_plan(p_scenario_id INT, p_case_id INT, p_window_min INT DEFAULT 60,
                                               p_weights JSONB DEFAULT '{"fuel":0.40,"crew":0.30,"rotation":0.15,"pax":0.15}',
                                               p_generated_by TEXT DEFAULT 'agent')
RETURNS BIGINT LANGUAGE plpgsql AS $$
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
                   (SELECT coalesce(sum(pc.pax_count),0) FROM pax_connection pc
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
END $$;

-- ---------------------------------------------------------------------
-- I. Scenario cloning (what-if) and report generation
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clone_scenario(p_src INT, p_name TEXT, p_kind TEXT DEFAULT 'WHATIF',
                                          p_overrides JSONB DEFAULT '{}'::jsonb)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_new INT;
BEGIN
    PERFORM set_config('fogops.skip_audit', 'on', true);     -- bulk copy is not a user action
    INSERT INTO scenario (name, kind, parent_scenario_id, description, sim_clock_utc, overrides, created_by)
    SELECT p_name, p_kind, scenario_id, 'Cloned from ' || name, sim_clock_utc, p_overrides, actor_user_id()
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

CREATE OR REPLACE FUNCTION generate_report(p_case_id INT, p_user_id INT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE c disruption_case%ROWTYPE; v_content JSONB; v_wm BIGINT; v_id BIGINT; v_rs INT;
BEGIN
    SELECT * INTO c FROM disruption_case WHERE case_id = p_case_id;
    SELECT max(audit_id) INTO v_wm FROM audit_log;
    v_rs := active_rule_set('GCAA FDP', scenario_now(c.scenario_id));
    v_content := jsonb_build_object(
        'case', to_jsonb(c),
        'generated_at_utc', now(),
        'scenario_clock_utc', scenario_now(c.scenario_id),
        'rule_set', (SELECT name || ' ' || version FROM rule_set WHERE rule_set_id = v_rs),
        'hub_status_history', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY effective_from_utc, status_event_id), '[]')
                                 FROM airport_status_event a WHERE a.scenario_id = c.scenario_id),
        'flights', (SELECT coalesce(jsonb_agg(to_jsonb(w) ORDER BY w.std_utc), '[]')
                      FROM v_flight_watch w WHERE w.case_id = p_case_id),
        'diversions', (SELECT coalesce(jsonb_agg(to_jsonb(dv)), '[]') FROM diversion dv WHERE dv.case_id = p_case_id),
        'decisions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'decision', to_jsonb(d),
                           'approvals', (SELECT coalesce(jsonb_agg(to_jsonb(ap)), '[]') FROM decision_approval ap
                                          WHERE ap.decision_id = d.decision_id)) ORDER BY d.decided_at), '[]')
                        FROM decision d WHERE d.case_id = p_case_id),
        'recovery_plan', (SELECT jsonb_build_object('plan', to_jsonb(p),
                                 'items', (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.rank) FROM recovery_plan_item i
                                            WHERE i.plan_id = p.plan_id))
                            FROM recovery_plan p WHERE p.case_id = p_case_id
                           ORDER BY generated_at DESC LIMIT 1),
        'open_exceptions', (SELECT count(*) FROM data_exception WHERE status = 'OPEN'),
        'timeline', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.occurred_at), '[]')
                       FROM v_case_timeline t WHERE t.case_id = p_case_id));
    INSERT INTO report (case_id, scenario_id, generated_by, audit_watermark_id, rule_set_id, content)
    VALUES (p_case_id, c.scenario_id, p_user_id, v_wm, v_rs, v_content)
    RETURNING report_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- J. Hold / divert options: alternate ranking + recommendation generation
--    Deterministic and explainable. Hard constraints make an option non-executable;
--    any unconfirmed input is a blocking "verify" constraint (never shown as executable).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION distance_km(a CHAR(3), b CHAR(3)) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT round((2 * 6371 * asin(sqrt(
              power(sin(radians(y.latitude - x.latitude) / 2), 2)
            + cos(radians(x.latitude)) * cos(radians(y.latitude))
              * power(sin(radians(y.longitude - x.longitude) / 2), 2))))::numeric, 1)
      FROM airport x, airport y WHERE x.iata = a AND y.iata = b
$$;

-- Inputs shared by hold and divert evaluation for one flight
CREATE OR REPLACE FUNCTION flight_decision_inputs(p_scenario_id INT, p_flight_id BIGINT)
RETURNS TABLE (hub_iata CHAR(3), now_utc TIMESTAMPTZ, endurance_left_min INT, fuel_quality TEXT,
               hub_status TEXT, hub_lvp BOOLEAN, reopen_utc TIMESTAMPTZ, reopen_quality TEXT,
               cockpit_all_lvp BOOLEAN, crew_known BOOLEAN,
               legal_end_now TIMESTAMPTZ, disc_end_now TIMESTAMPTZ,
               legal_end_if_diverted TIMESTAMPTZ, disc_end_if_diverted TIMESTAMPTZ,
               -- time-base fields (rule TB-1..TB-4, see README "Time-base rules")
               flight_phase TEXT, anchor_utc TIMESTAMPTZ, endurance_until TIMESTAMPTZ, earliest_sign_in TIMESTAMPTZ)
LANGUAGE plpgsql STABLE AS $$
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
    SELECT fe.as_of_utc + make_interval(mins => fe.est_holding_endurance_min) AS until, fe.quality::text AS q
      INTO e FROM flight_fuel_estimate fe
     WHERE fe.scenario_id = p_scenario_id AND fe.flight_id = p_flight_id ORDER BY fe.as_of_utc DESC LIMIT 1;
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
END $$;

-- Rank every active alternate for a flight. Read-only: safe to call on every screen refresh.
CREATE OR REPLACE FUNCTION rank_alternates(p_scenario_id INT, p_flight_id BIGINT,
                                           p_km_per_min NUMERIC DEFAULT 7.0, p_approach_min INT DEFAULT 10)
RETURNS TABLE (rank INT, alt_iata CHAR(3), alt_name TEXT, is_executable BOOLEAN, score NUMERIC,
               op_status TEXT, lvp_in_force BOOLEAN, weather_above_minima BOOLEAN, stands_left INT,
               fuel_ok BOOLEAN, handling_ok BOOLEAN, distance_km NUMERIC, est_flight_min INT,
               est_arrival_utc TIMESTAMPTZ, fuel_margin_min INT, return_block_min INT, return_block_basis TEXT,
               ready_at_alt_utc TIMESTAMPTZ, earliest_return_dep_utc TIMESTAMPTZ,
               latest_legal_return_dep_utc TIMESTAMPTZ, latest_return_dep_with_discretion_utc TIMESTAMPTZ,
               crew_return_margin_min INT, crew_outcome TEXT, road_positioning_min INT,
               historical_diversions INT, hist_median_ground_min INT,
               blocking_constraints JSONB, reasons TEXT[], score_breakdown JSONB)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE i RECORD;
BEGIN
    SELECT * INTO i FROM flight_decision_inputs(p_scenario_id, p_flight_id);
    RETURN QUERY
    WITH alt AS (
        SELECT aa.*, ap.name AS alt_name, ap.min_ground_time_min,
               st.op_status::text AS op_status, st.lvp_in_force, st.weather_above_minima, st.parking_available,
               st.fuel_ok, st.handling_ok,
               distance_km(i.hub_iata, aa.alt_iata) AS dist,
               (SELECT count(*) FROM diversion dv
                 WHERE dv.scenario_id = p_scenario_id AND dv.alternate_iata = aa.alt_iata
                   AND dv.original_flight_id <> p_flight_id
                   AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED'))::int AS occupied,
               b.p90_block_min, b.sample_n
          FROM alternate_airport aa JOIN airport ap ON ap.iata = aa.alt_iata
          LEFT JOIN LATERAL (SELECT * FROM airport_status_event x
                              WHERE x.scenario_id = p_scenario_id AND x.iata = aa.alt_iata
                                AND x.effective_from_utc <= i.now_utc
                              ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1) st ON TRUE
          LEFT JOIN block_time_reference b ON b.from_iata = aa.alt_iata AND b.to_iata = i.hub_iata
         WHERE aa.hub_iata = i.hub_iata AND aa.is_active
    ), m AS (
        SELECT a.*,
               (ceil(a.dist / p_km_per_min) + p_approach_min)::int AS fl_min,
               coalesce(a.p90_block_min, (ceil(a.dist / p_km_per_min) + p_approach_min + 10)::int) AS ret_blk,
               CASE WHEN a.p90_block_min IS NOT NULL THEN format('P90 of %s historical %s-%s', a.sample_n, a.alt_iata, i.hub_iata)
                    ELSE 'ESTIMATED from distance' END AS ret_basis,
               a.parking_available - a.occupied AS stands
          FROM alt a
    ), t AS (
        SELECT m.*,
               i.anchor_utc + make_interval(mins => m.fl_min) AS arr_utc,
               floor(extract(epoch FROM i.endurance_until - i.anchor_utc)/60)::int - m.fl_min AS fuel_margin,
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
                  (CASE WHEN t.op_status IS NULL THEN jsonb_build_object('code','ALTERNATE_STATUS_UNKNOWN','verify',true) END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.op_status <> 'OPEN' THEN jsonb_build_object('code','ALTERNATE_NOT_OPEN','value',t.op_status) END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.weather_above_minima IS NULL THEN jsonb_build_object('code','WEATHER_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.weather_above_minima IS FALSE THEN jsonb_build_object('code','WEATHER_BELOW_MINIMA') END),
                  (CASE WHEN t.op_status IS NOT NULL AND t.stands IS NULL THEN jsonb_build_object('code','PARKING_UNCONFIRMED','verify',true) END),
                  (CASE WHEN t.stands <= 0 THEN jsonb_build_object('code','NO_PARKING','occupied',t.occupied) END),
                  (CASE WHEN t.fuel_ok IS FALSE THEN jsonb_build_object('code','NO_FUEL_AT_ALTERNATE') END),
                  (CASE WHEN t.handling_ok IS FALSE THEN jsonb_build_object('code','NO_HANDLING') END),
                  (CASE WHEN i.endurance_left_min IS NULL THEN jsonb_build_object('code','FUEL_ENDURANCE_UNKNOWN','verify',true) END),
                  (CASE WHEN t.fuel_margin < 0 THEN jsonb_build_object('code','CANNOT_REACH_WITH_FUEL','margin_min',t.fuel_margin) END),
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
           fin.op_status, fin.lvp_in_force, fin.weather_above_minima, fin.stands, fin.fuel_ok, fin.handling_ok,
           fin.dist, fin.fl_min, fin.arr_utc, fin.fuel_margin, fin.ret_blk, fin.ret_basis, fin.ready, fin.earliest_dep,
           fin.latest_legal, fin.latest_disc, fin.crew_margin, fin.outcome, fin.road_positioning_min,
           fin.historical_diversions, fin.hist_median_ground_min, fin.blocking,
           array_remove(ARRAY[
               CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                    THEN format('Pre-departure assessment: times anchored at projected arrival %s', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"')) END,
               CASE WHEN fin.fuel_margin IS NOT NULL THEN format('Fuel margin on arrival %s min', fin.fuel_margin) END,
               CASE fin.outcome
                    WHEN 'CREW_CAN_RETURN' THEN format('Crew can fly %s-%s legally (%s min spare)', fin.alt_iata, i.hub_iata, fin.crew_margin)
                    WHEN 'NEEDS_COMMANDER_DISCRETION' THEN 'Return needs commander discretion'
                    WHEN 'NEEDS_REPLACEMENT_BY_ROAD' THEN format('Replacement crew needed: %s min by road from %s', fin.road_positioning_min, i.hub_iata)
                    WHEN 'NEEDS_REPLACEMENT_DEADHEAD' THEN 'Replacement crew needed: deadhead flight'
                    ELSE 'Crew legality unverified' END,
               CASE WHEN fin.stands IS NOT NULL THEN format('%s stand(s) left', fin.stands) END,
               format('%s-%s block %s min (%s)', fin.alt_iata, i.hub_iata, fin.ret_blk, fin.ret_basis),
               CASE WHEN fin.historical_diversions > 0 THEN format('Used for %s SHJ diversions in 2026', fin.historical_diversions) END],
               NULL),
           jsonb_build_object('fuel', round(fin.s_fuel,3), 'crew', round(fin.s_crew,3), 'recovery', round(fin.s_rec,3),
                              'stands', round(fin.s_stand,3), 'history', round(fin.s_hist,3),
                              'weights', '{"fuel":0.30,"crew":0.30,"recovery":0.15,"stands":0.10,"history":0.15}'::jsonb)
      FROM fin
     ORDER BY 1;
END $$;

-- Generate a full hold/divert recommendation (HOLD option + every alternate), ranked.
-- Writes recommendation + recommendation_option rows; the previous open recommendation is superseded.
CREATE OR REPLACE FUNCTION propose_hold_or_divert(p_scenario_id INT, p_case_id INT, p_flight_id BIGINT,
                                                  p_generated_by TEXT DEFAULT 'rules-engine v1',
                                                  p_approach_min INT DEFAULT 10,
                                                  p_min_hold_spare_min INT DEFAULT 15)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    i RECORD; v_rec BIGINT; v_hold_block JSONB := '[]'; v_hold_ok BOOLEAN; v_hold_score NUMERIC := 0;
    v_land TIMESTAMPTZ; v_spare INT; v_hold_crew INT; v_best RECORD; v_conf NUMERIC; v_type rec_type;
    v_rationale TEXT; v_hold_reasons TEXT[] := '{}';
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
    IF v_hold_ok THEN
        v_hold_score := CASE WHEN v_spare >= p_min_hold_spare_min THEN round(1.0 + least(1, v_spare / 60.0), 3)
                             ELSE 0.2 END;
    END IF;
    v_hold_reasons := array_remove(ARRAY[
        CASE WHEN v_land IS NOT NULL THEN format('Landing at %s after forecast reopening (%s)', to_char(v_land AT TIME ZONE 'UTC','HH24:MI"Z"'), i.reopen_quality) END,
        CASE WHEN v_spare IS NOT NULL THEN format('Fuel spare at landing %s min (%s)', v_spare, i.fuel_quality) END,
        CASE WHEN v_hold_crew IS NOT NULL THEN format('Crew margin at landing %s min', v_hold_crew) END,
        CASE WHEN v_hold_crew < 0 AND v_land <= i.disc_end_now THEN 'Needs commander discretion' END,
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
        SELECT 'DIVERT', r.alt_iata, NULL, r.est_arrival_utc, r.fuel_margin_min, r.crew_return_margin_min, r.score,
               r.is_executable, r.blocking_constraints, r.reasons
          FROM rank_alternates(p_scenario_id, p_flight_id) r
      ) x;

    SELECT * INTO v_best FROM recommendation_option WHERE rec_id = v_rec AND rank = 1;
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
        assumptions = jsonb_build_array(
            format('Fuel endurance quality: %s', coalesce(i.fuel_quality, 'none')),
            format('Hub reopening quality: %s', coalesce(i.reopen_quality, 'none')),
            'Distance to alternates measured from the hub (aircraft assumed in the hub terminal area)',
            'Diversion counts as one extra sector for every operating crew member',
            CASE WHEN i.flight_phase = 'NOT_DEPARTED'
                 THEN format('Flight not yet departed: pre-departure assessment, all times anchored at projected arrival %s (not at the current clock)',
                             to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'))
                 ELSE format('Decision moment %s (%s)', to_char(i.anchor_utc AT TIME ZONE 'UTC','DD HH24:MI"Z"'), lower(i.flight_phase)) END,
            'Alternate status/parking taken from the latest airport_status_event',
            format('Hold preferred when feasible with >= %s min fuel spare at landing', p_min_hold_spare_min)),
        uncertainty = jsonb_build_object('reopening_utc', i.reopen_utc, 'reopening_quality', i.reopen_quality,
                                         'endurance_left_min', i.endurance_left_min)
     WHERE rec_id = v_rec;
    RETURN v_rec;
END $$;

-- ---------------------------------------------------------------------
-- K. Downstream impact: what else breaks if this flight is late or diverted
--    Aircraft: the same registration's next legs, with delay propagated leg by leg.
--    Crew: remaining legs of the duty are already inside legality (compute_latest_departure);
--          here we add each operating crew member's NEXT planned roster duty and the rest gap.
--    Passengers: connections at risk per downstream leg.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION downstream_impact(p_scenario_id INT, p_flight_id BIGINT,
                                             p_ready_at_hub_utc TIMESTAMPTZ DEFAULT NULL,
                                             p_horizon_hours INT DEFAULT 24)
RETURNS TABLE (kind TEXT, seq INT, ref TEXT, route TEXT, planned_utc TIMESTAMPTZ, projected_utc TIMESTAMPTZ,
               delay_min INT, connecting_pax INT, impact TEXT)
LANGUAGE plpgsql STABLE AS $$
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
        connecting_pax := coalesce((SELECT sum(pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = nx.flight_id), 0)::int;
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
END $$;

-- ---------------------------------------------------------------------
-- Pin search_path on every function so callers' settings can't change behaviour
-- ---------------------------------------------------------------------
DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
