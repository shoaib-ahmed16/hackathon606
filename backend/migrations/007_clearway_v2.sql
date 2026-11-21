-- 007: Clearway v2 (fogops_app_mockup_v2). Everything the new UI needs that the database did not have yet.
--  a) approval policy as agreed in the mockup (DIVERT needs OCC AND Crew Control)
--  b) flight tags (e.g. a medical case on board) so PRIORITY rules and the board can use them
--  c) role-based notifications: "your approval is needed", "approved, ready to execute", "rejected", "data requested"
--     (the 003 fan-out only reaches people who watch the flight)

-- a) -------------------------------------------------------------------------------------------------------------
DELETE FROM approval_policy;
INSERT INTO approval_policy (decision_type, approver_role, required, notify_roles) VALUES
  ('DIVERT',               'OCC',          TRUE, '{DISPATCH,STATION}'),
  ('DIVERT',               'CREW_CONTROL', TRUE, '{DISPATCH,STATION}'),
  ('HOLD',                 'OCC',          TRUE, '{CREW_CONTROL}'),
  ('DELAY',                'OCC',          TRUE, '{DISPATCH,STATION}'),
  ('RECOVER',              'OCC',          TRUE, '{CREW_CONTROL,STATION}'),
  ('COMMANDER_DISCRETION', 'CREW_CONTROL', TRUE, '{OCC}'),
  ('CREW_REPLACE',         'CREW_CONTROL', TRUE, '{OCC,STATION}'),
  ('AIRCRAFT_SWAP',        'OCC',          TRUE, '{DISPATCH,CREW_CONTROL,STATION}'),
  ('CANCEL',               'OCC',          TRUE, '{DISPATCH,CREW_CONTROL,STATION}');

-- b) -------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS flight_tag (
    scenario_id INT    NOT NULL REFERENCES scenario,
    flight_id   BIGINT NOT NULL REFERENCES flight,
    tag         TEXT   NOT NULL CHECK (tag IN ('MEDICAL','VIP','HIGH_IMPACT')),
    note        TEXT,
    set_by      INT REFERENCES app_user,
    set_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (scenario_id, flight_id, tag)
);
DROP TRIGGER IF EXISTS audit_flight_tag ON flight_tag;
CREATE TRIGGER audit_flight_tag AFTER INSERT OR DELETE ON flight_tag
    FOR EACH ROW EXECUTE FUNCTION trg_audit('flight_id');

-- c) -------------------------------------------------------------------------------------------------------------
-- In-app notification for every active user holding one of the roles, except the person who acted.
-- One row per (recipient, source) per transaction, so someone who both watches the flight and holds the role is told once.
CREATE OR REPLACE FUNCTION notify_roles(p_scenario_id INT, p_flight_id BIGINT, p_case_id INT, p_roles TEXT[],
                                        p_title TEXT, p_body TEXT, p_sev severity_level, p_entity TEXT, p_entity_id TEXT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
    IF p_roles IS NULL OR cardinality(p_roles) = 0 THEN RETURN 0; END IF;
    INSERT INTO notification_outbox (scenario_id, case_id, flight_id, channel, recipient, severity, title, body, source_entity, source_id)
    SELECT p_scenario_id, p_case_id, p_flight_id, 'IN_APP', u.username, p_sev, p_title, p_body, p_entity, p_entity_id
      FROM app_user u
     WHERE u.is_active AND u.role_code = ANY (p_roles)
       AND u.user_id IS DISTINCT FROM actor_user_id()
       AND NOT EXISTS (SELECT 1 FROM notification_outbox o
                        WHERE o.channel = 'IN_APP' AND o.recipient = u.username AND o.flight_id IS NOT DISTINCT FROM p_flight_id
                          AND o.source_entity IS NOT DISTINCT FROM p_entity AND o.source_id IS NOT DISTINCT FROM p_entity_id
                          AND o.created_at = now());
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN PERFORM pg_notify('fogops_notify', json_build_object('flight_id', p_flight_id, 'count', n)::text); END IF;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION trg_role_notify_decision() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_no TEXT; v_approvers TEXT[]; v_inform TEXT[]; v_type TEXT := NEW.decision_type::text;
BEGIN
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = NEW.flight_id;
    SELECT coalesce(array_agg(DISTINCT approver_role) FILTER (WHERE required), '{}') INTO v_approvers
      FROM approval_policy WHERE decision_type = NEW.decision_type;
    SELECT coalesce(array_agg(DISTINCT r), '{}') INTO v_inform
      FROM approval_policy p, unnest(p.notify_roles) r WHERE p.decision_type = NEW.decision_type;
    IF TG_OP = 'INSERT' AND NEW.status = 'PROPOSED' THEN
        PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NEW.case_id, v_approvers,
                format('%s: %s proposed, your approval is needed', v_no, v_type), coalesce(NEW.rationale, ''), 'WARN', 'decision', NEW.decision_id::text);
        PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NEW.case_id, v_inform,
                format('%s: %s proposed', v_no, v_type), coalesce(NEW.rationale, ''), 'INFO', 'decision', NEW.decision_id::text);
    ELSIF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
        IF NEW.status = 'APPROVED' THEN
            PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NEW.case_id, ARRAY['OCC'],
                    format('%s: %s approved by all, ready to execute', v_no, v_type), coalesce(NEW.rationale, ''), 'WARN', 'decision', NEW.decision_id::text);
        ELSIF NEW.status = 'REJECTED' THEN
            PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NEW.case_id, ARRAY[NEW.decided_role],
                    format('%s: %s rejected', v_no, v_type), coalesce(NEW.rationale, ''), 'WARN', 'decision', NEW.decision_id::text);
        ELSIF NEW.status = 'EXECUTED' THEN
            PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NEW.case_id, v_inform,
                    format('%s: %s executed', v_no, v_type), coalesce(NEW.rationale, ''), 'INFO', 'decision', NEW.decision_id::text);
        END IF;
    END IF;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_role_notify_decision ON decision;
CREATE TRIGGER zz_role_notify_decision AFTER INSERT OR UPDATE ON decision
    FOR EACH ROW EXECUTE FUNCTION trg_role_notify_decision();

-- one role approved, the others are still awaited
CREATE OR REPLACE FUNCTION trg_role_notify_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE d decision%ROWTYPE; v_no TEXT; v_missing TEXT[];
BEGIN
    SELECT * INTO d FROM decision WHERE decision_id = NEW.decision_id;
    IF d.status <> 'PROPOSED' OR NEW.verdict <> 'APPROVED' THEN RETURN NULL; END IF;
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = d.flight_id;
    SELECT coalesce(array_agg(p.approver_role), '{}') INTO v_missing FROM approval_policy p
     WHERE p.decision_type = d.decision_type AND p.required
       AND NOT EXISTS (SELECT 1 FROM decision_approval a WHERE a.decision_id = d.decision_id AND a.approver_role = p.approver_role AND a.verdict = 'APPROVED');
    PERFORM notify_roles(d.scenario_id, d.flight_id, d.case_id, v_missing,
            format('%s: approved by %s, waiting for you', v_no, NEW.approver_role), format('%s %s', d.decision_type, coalesce(d.alternate_iata, '')), 'WARN', 'decision_approval', NEW.approval_id::text);
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_role_notify_approval ON decision_approval;
CREATE TRIGGER zz_role_notify_approval AFTER INSERT ON decision_approval
    FOR EACH ROW EXECUTE FUNCTION trg_role_notify_approval();

-- a data request tells the team it is addressed to; the answer tells OCC and Dispatch
CREATE OR REPLACE FUNCTION trg_role_notify_request() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_no TEXT;
BEGIN
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = NEW.flight_id;
    IF TG_OP = 'INSERT' THEN
        PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NULL, ARRAY[NEW.requested_from_role],
                format('%s: data request, %s', v_no, lower(replace(NEW.field, '_', ' '))), NEW.question, 'WARN', 'data_request', NEW.request_id::text);
    ELSIF NEW.status = 'ANSWERED' AND OLD.status IS DISTINCT FROM 'ANSWERED' THEN
        PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, NULL, ARRAY['OCC','DISPATCH'],
                format('%s: data provided, %s', v_no, lower(replace(NEW.field, '_', ' '))), coalesce(NEW.answer->>'value', ''), 'INFO', 'data_request', NEW.request_id::text);
    END IF;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_role_notify_request ON data_request;
CREATE TRIGGER zz_role_notify_request AFTER INSERT OR UPDATE ON data_request
    FOR EACH ROW EXECUTE FUNCTION trg_role_notify_request();

-- a tag (for example MEDICAL) is announced to watchers and to OCC / Dispatch
CREATE OR REPLACE FUNCTION trg_flight_tag_notify() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_no TEXT; v_case INT;
BEGIN
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = NEW.flight_id;
    SELECT cf.case_id INTO v_case FROM case_flight cf JOIN disruption_case dc ON dc.case_id = cf.case_id
     WHERE dc.scenario_id = NEW.scenario_id AND cf.flight_id = NEW.flight_id ORDER BY cf.case_id LIMIT 1;
    PERFORM notify_flight(NEW.scenario_id, NEW.flight_id, v_case, format('%s: tagged %s', v_no, NEW.tag), coalesce(NEW.note, ''), 'WARN', 'flight_tag', NEW.tag);
    PERFORM notify_roles(NEW.scenario_id, NEW.flight_id, v_case, ARRAY['OCC','DISPATCH'], format('%s: tagged %s', v_no, NEW.tag), coalesce(NEW.note, ''), 'WARN', 'flight_tag', NEW.tag);
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_flight_tag_notify ON flight_tag;
CREATE TRIGGER zz_flight_tag_notify AFTER INSERT ON flight_tag
    FOR EACH ROW EXECUTE FUNCTION trg_flight_tag_notify();

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
