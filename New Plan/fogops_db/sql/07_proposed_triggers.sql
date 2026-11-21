SET search_path = fogops, public;

-- T1. Multi-role approval: a decision becomes APPROVED only when every required role in
--     approval_policy has approved; any REJECTED verdict rejects it. No policy rows = any approver.
CREATE OR REPLACE FUNCTION trg_decision_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_ok BOOLEAN; v_user_role TEXT; d decision%ROWTYPE; v_has_policy BOOLEAN; v_missing INT;
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
    IF d.status <> 'PROPOSED' THEN RAISE EXCEPTION 'Decision % is already %', d.decision_id, d.status; END IF;

    SELECT EXISTS (SELECT 1 FROM approval_policy WHERE decision_type = d.decision_type) INTO v_has_policy;
    IF v_has_policy AND NOT EXISTS (SELECT 1 FROM approval_policy
                                     WHERE decision_type = d.decision_type AND approver_role = NEW.approver_role) THEN
        RAISE EXCEPTION 'Role % is not an approver for % decisions', NEW.approver_role, d.decision_type;
    END IF;

    IF NEW.verdict = 'REJECTED' THEN
        UPDATE decision SET status = 'REJECTED' WHERE decision_id = d.decision_id;
    ELSE
        SELECT count(*) INTO v_missing FROM approval_policy p
         WHERE p.decision_type = d.decision_type AND p.required
           AND NOT EXISTS (SELECT 1 FROM decision_approval a
                            WHERE a.decision_id = d.decision_id AND a.approver_role = p.approver_role
                              AND a.verdict = 'APPROVED');
        IF NOT v_has_policy OR v_missing = 0 THEN
            UPDATE decision SET status = 'APPROVED' WHERE decision_id = d.decision_id;
        END IF;
    END IF;
    IF d.rec_id IS NOT NULL THEN
        UPDATE recommendation
           SET status = CASE WHEN NEW.verdict = 'REJECTED' THEN 'REJECTED'::rec_status
                             WHEN coalesce(d.followed_recommendation, TRUE) THEN 'ACCEPTED'::rec_status
                             ELSE 'REJECTED'::rec_status END
         WHERE rec_id = d.rec_id AND status = 'PROPOSED'
           AND (NEW.verdict = 'REJECTED' OR (SELECT status FROM decision WHERE decision_id = d.decision_id) = 'APPROVED');
    END IF;
    RETURN NEW;
END $$;

-- T2. Notification fan-out to flight subscribers (+ NOTIFY for the notification worker)
CREATE OR REPLACE FUNCTION notify_flight(p_scenario_id INT, p_flight_id BIGINT, p_case_id INT,
                                         p_title TEXT, p_body TEXT, p_sev severity_level,
                                         p_entity TEXT, p_entity_id TEXT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
    INSERT INTO notification_outbox (scenario_id, case_id, flight_id, channel, recipient, severity, title, body,
                                     source_entity, source_id)
    SELECT p_scenario_id, p_case_id, p_flight_id, s.channel,
           coalesce(s.target, (SELECT username FROM app_user WHERE user_id = s.user_id)),
           p_sev, p_title, p_body, p_entity, p_entity_id
      FROM flight_subscription s
     WHERE s.active AND s.scenario_id = p_scenario_id AND s.flight_id = p_flight_id
       AND (s.user_id IS NULL OR s.user_id IS DISTINCT FROM actor_user_id());   -- don't notify the author
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
        PERFORM pg_notify('fogops_notify', json_build_object('flight_id', p_flight_id, 'count', n)::text);
    END IF;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION trg_flight_notify() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v JSONB := to_jsonb(NEW); o JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END;
        v_flight BIGINT; v_scn INT; v_case INT; v_title TEXT; v_body TEXT; v_sev severity_level := 'INFO'; v_no TEXT;
BEGIN
    v_flight := coalesce((v->>'flight_id')::bigint, (v->>'original_flight_id')::bigint);
    v_case   := (v->>'case_id')::int;
    v_scn    := coalesce((v->>'scenario_id')::int, (SELECT scenario_id FROM disruption_case WHERE case_id = v_case));
    IF v_flight IS NULL OR v_scn IS NULL THEN RETURN NEW; END IF;
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = v_flight;
    CASE TG_TABLE_NAME
      WHEN 'decision' THEN
        IF TG_OP = 'UPDATE' AND o->>'status' = v->>'status' THEN RETURN NEW; END IF;
        v_title := format('%s: %s %s', v_no, v->>'decision_type', v->>'status');
        v_body  := v->>'rationale';
        v_sev   := CASE WHEN v->>'status' IN ('PROPOSED','APPROVED') THEN 'WARN' ELSE 'INFO' END;
      WHEN 'case_comment' THEN
        v_title := format('%s: new %s', v_no, lower(coalesce(v->>'kind', 'comment')));
        v_body  := v->>'body';
      WHEN 'diversion' THEN
        IF TG_OP = 'UPDATE' AND (o->>'status', o->>'waiting_for') IS NOT DISTINCT FROM (v->>'status', v->>'waiting_for') THEN
            RETURN NEW; END IF;
        v_title := format('%s at %s: %s', v_no, v->>'alternate_iata', v->>'status');
        v_body  := 'Waiting for ' || (v->>'waiting_for');
      WHEN 'data_request' THEN
        v_title := format('%s: data request %s', v_no, v->>'status');
        v_body  := v->>'question';
        v_sev   := 'WARN';
      ELSE RETURN NEW;
    END CASE;
    PERFORM notify_flight(v_scn, v_flight, v_case, v_title, v_body, v_sev, TG_TABLE_NAME, coalesce(v->>'decision_id', v->>'comment_id', v->>'diversion_id', v->>'request_id'));
    RETURN NEW;
END $$;
CREATE TRIGGER notify_decision  AFTER INSERT OR UPDATE ON decision     FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_comment   AFTER INSERT           ON case_comment FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_diversion AFTER INSERT OR UPDATE ON diversion    FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_request   AFTER INSERT OR UPDATE ON data_request FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();

-- T3. Integration outbox: an EXECUTED diversion queues the aeroMart entry (idempotent)
CREATE OR REPLACE FUNCTION trg_integration_outbox() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE f flight%ROWTYPE;
BEGIN
    IF NEW.status = 'EXECUTED' AND OLD.status IS DISTINCT FROM 'EXECUTED' AND NEW.decision_type = 'DIVERT' THEN
        SELECT * INTO f FROM flight WHERE flight_id = NEW.flight_id;
        INSERT INTO integration_outbox (system_code, scenario_id, decision_id, flight_id, action, payload, idempotency_key)
        VALUES ('AEROMART', NEW.scenario_id, NEW.decision_id, NEW.flight_id, 'CREATE_DIVERSION_ENTRY',
                jsonb_build_object('flight_no', f.flight_no, 'flight_date', f.flight_date, 'dep', f.dep_iata,
                                   'planned_arr', f.arr_iata, 'diverted_to', NEW.alternate_iata,
                                   'recovery_flight_id', NEW.details->>'recovery_flight_id',
                                   'decided_by', NEW.decided_by, 'decision_id', NEW.decision_id),
                'DIVERT-' || NEW.decision_id)
        ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER integration_on_execute AFTER UPDATE ON decision FOR EACH ROW EXECUTE FUNCTION trg_integration_outbox();
