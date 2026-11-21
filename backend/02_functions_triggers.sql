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
        jsonb_build_object('op_status', NEW.op_status, 'expected_reopen_utc', NEW.expected_reopen_utc,
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
    v_worst legality_status; v_bind fdp_calculation%ROWTYPE; v_count INT := 0;
    c_order CONSTANT legality_status[] := ARRAY['LEGAL','AT_RISK','DISCRETION_REQUIRED',
                                                'VERIFICATION_REQUIRED','EXCEEDED']::legality_status[];
BEGIN
    SELECT * INTO d FROM crew_duty WHERE duty_id = p_duty_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'duty % not found', p_duty_id; END IF;
    v_rs := active_rule_set('GCAA FDP', v_now);
    IF v_rs IS NULL THEN RAISE EXCEPTION 'No approved FDP rule set effective at %', v_now; END IF;
    SELECT * INTO rs FROM rule_set WHERE rule_set_id = v_rs;

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
        v_reasons := '{}'; v_status := NULL;
        r := NULL; v_legal_end := NULL; v_disc_end := NULL; v_margin := NULL; v_dmargin := NULL;
        v_sign_in := coalesce(a.sign_in_utc, d.sign_in_utc);
        v_station := coalesce(a.report_station_iata, d.report_station_iata);
        v_tz := CASE rs.band_reference
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
                        v_reasons := array_append(v_reasons, 'SHEET_DISAGREES_WITH_RULESET');
                        PERFORM raise_exception_item(NULL, 'crew_assignment', a.assignment_id::text,
                            'SHEET_MAXFDP_MISMATCH', 'BLOCKING',
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
                               'band_reference', rs.band_reference,
                               'report_station', v_station,
                               'commander_discretion_min', rs.commander_discretion_min,
                               'last_leg_flight_id', v_last_flight,
                               'projected_end_basis', v_proj.basis,
                               'from_leg_seq', a.from_leg_seq,
                               'sheet_max_fdp_min', a.sheet_max_fdp_min,
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
    RETURNING flight_id INTO v_rec_flight;
    INSERT INTO flight_state (scenario_id, flight_id, registration, etd_utc, eta_utc, pax, last_received_at)
    VALUES (d.scenario_id, v_rec_flight, coalesce(s.registration, f.registration_planned), v_std,
            v_std + make_interval(mins => v_block), coalesce(s.pax, f.pax_planned), v_now);

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
BEGIN
    SELECT coalesce((parameters->>'min_rest_after_duty_min')::int, 720) INTO v_rest
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
                       (c.sign_in AT TIME ZONE (SELECT tz FROM airport WHERE iata = v_hub))::time, v_legs) r ON TRUE
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
                WHEN c.mx IS NULL THEN 'VERIFY: no FDP rule for this crew type/legs'
                WHEN c.legal_end < v_proj THEN 'NOT LEGAL for remaining legs'
                WHEN jsonb_array_length(cf.conflicts) > 0 THEN 'LEGAL but breaks planned roster'
                ELSE 'CANDIDATE' END
      FROM calc c JOIN conf cf USING (crew_id)
     ORDER BY (jsonb_array_length(cf.conflicts) > 0), (c.legal_end < v_proj), c.lvp DESC,
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
            v_feasible BOOLEAN := TRUE; v_why TEXT := NULL;
        BEGIN
            v_tmp := v_tmp + 1;
            IF r.loc LIKE 'AIRBORNE%' AND r.endurance IS NOT NULL
               AND r.earliest > v_now + make_interval(mins => r.endurance) THEN
                v_feasible := FALSE;
                v_why := format('Estimated fuel endurance (%s min) ends before earliest landing slot: must divert', r.endurance);
            ELSIF r.latest_dep IS NOT NULL
               AND r.latest_dep < r.earliest - (SELECT sta_utc - std_utc FROM flight WHERE flight_id = r.flight_id) THEN
                v_feasible := FALSE; v_why := 'Crew latest legal departure is before earliest possible departure: replacement crew or discretion needed';
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
    INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, arrival_capacity_per_hr,
        departure_capacity_per_hr, parking_available, weather_above_minima, handling_ok, fuel_ok,
        effective_from_utc, expected_reopen_utc, quality, entered_by, note)
    SELECT v_new, iata, op_status, reason, visibility_m, arrival_capacity_per_hr, departure_capacity_per_hr,
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
