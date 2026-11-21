-- MVP extensions from the New Plan (Developer Guide appendices A and B): subscriptions, notifications,
-- discussion kinds, data requests, custom rules, approval policy, external systems + outbox, KPI/severity views,
-- multi-role approval trigger, notification fan-out, integration outbox.
SET search_path = fogops, public;

-- E1. Watch / subscribe to a flight
CREATE TABLE flight_subscription (
    subscription_id  BIGSERIAL PRIMARY KEY,
    scenario_id      INT NOT NULL REFERENCES scenario,
    flight_id        BIGINT NOT NULL REFERENCES flight,
    user_id          INT REFERENCES app_user,          -- NULL when the target is a channel/address
    channel          TEXT NOT NULL CHECK (channel IN ('IN_APP','TEAMS','EMAIL')),
    target           TEXT,                              -- Teams channel id / email when not a user
    reason           TEXT,                              -- MEDICAL, VIP, HIGH_IMPACT, OWNER ...
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_by       INT REFERENCES app_user,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (user_id IS NOT NULL OR target IS NOT NULL)
);
CREATE UNIQUE INDEX ux_subscription ON flight_subscription
    (scenario_id, flight_id, coalesce(user_id, 0), channel, coalesce(target, '')) WHERE active;

-- E2. Notification outbox (in-app, Teams, email) - filled by triggers, sent by a worker
CREATE TABLE notification_outbox (
    notification_id  BIGSERIAL PRIMARY KEY,
    scenario_id      INT NOT NULL REFERENCES scenario,
    case_id          INT REFERENCES disruption_case,
    flight_id        BIGINT REFERENCES flight,
    channel          TEXT NOT NULL CHECK (channel IN ('IN_APP','TEAMS','EMAIL')),
    recipient        TEXT NOT NULL,
    severity         severity_level NOT NULL DEFAULT 'INFO',
    title            TEXT NOT NULL,
    body             TEXT NOT NULL,
    source_entity    TEXT,
    source_id        TEXT,
    status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','FAILED','SUPPRESSED')),
    attempts         INT NOT NULL DEFAULT 0,
    last_error       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at          TIMESTAMPTZ
);
CREATE INDEX ix_notification_pending ON notification_outbox (status, created_at) WHERE status = 'PENDING';

-- E3. Flight discussion thread: extend case_comment
ALTER TABLE case_comment
    ADD COLUMN kind TEXT NOT NULL DEFAULT 'COMMENT'
        CHECK (kind IN ('COMMENT','QUESTION','ANSWER','RECOMMENDATION','DATA_REQUEST','SYSTEM')),
    ADD COLUMN external_ref TEXT;                       -- Teams message id when mirrored

-- E4. "?" data requests (fuel not available -> ask crew -> enter)
CREATE TABLE data_request (
    request_id          BIGSERIAL PRIMARY KEY,
    scenario_id         INT NOT NULL REFERENCES scenario,
    flight_id           BIGINT REFERENCES flight,
    iata                CHAR(3) REFERENCES airport,      -- for alternate-status requests
    field               TEXT NOT NULL CHECK (field IN ('FUEL_ENDURANCE','ALTERNATE_STATUS','ALTERNATE_STANDS',
                                                       'CREW_SIGN_IN','CREW_QUALIFICATION','ETA','OTHER')),
    question            TEXT NOT NULL,
    requested_from_role TEXT REFERENCES app_role,
    requested_by        INT NOT NULL REFERENCES app_user,
    status              TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ANSWERED','CANCELLED')),
    answer              JSONB,
    answered_by         INT REFERENCES app_user,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    answered_at         TIMESTAMPTZ
);

-- E5. Custom operational rules with a validity window and priority
--     FILTER/ALERT/PRIORITY rules change what users see; CONSTRAINT rules may only TIGHTEN limits,
--     never relax the approved FDP rule set, and need approval before they become ACTIVE.
CREATE TABLE ops_rule (
    rule_id      SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('FILTER','ALERT','PRIORITY','CONSTRAINT')),
    description  TEXT NOT NULL,
    definition   JSONB NOT NULL,     -- e.g. {"all":[{"field":"lvp_crew_ok","op":"eq","value":false}]}
    priority     SMALLINT NOT NULL DEFAULT 100,
    valid_from   TIMESTAMPTZ NOT NULL,
    valid_to     TIMESTAMPTZ,
    status       TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','EXPIRED','REJECTED')),
    created_by   INT NOT NULL REFERENCES app_user,
    approved_by  INT REFERENCES app_user,
    approved_at  TIMESTAMPTZ,
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (kind <> 'CONSTRAINT' OR status <> 'ACTIVE' OR approved_by IS NOT NULL)
);

-- E6. Approval policy: which roles must approve which decision type ("approved by all")
CREATE TABLE approval_policy (
    decision_type  decision_type NOT NULL,
    approver_role  TEXT NOT NULL REFERENCES app_role,
    required       BOOLEAN NOT NULL DEFAULT TRUE,
    notify_roles   TEXT[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (decision_type, approver_role)
);
INSERT INTO approval_policy VALUES
 ('DIVERT','OCC',TRUE,'{DISPATCH,CREW_CONTROL,STATION}'),
 ('CREW_REPLACE','CREW_CONTROL',TRUE,'{OCC,STATION}'),
 ('COMMANDER_DISCRETION','CREW_CONTROL',TRUE,'{OCC}'),
 ('AIRCRAFT_SWAP','OCC',TRUE,'{DISPATCH,CREW_CONTROL,STATION}'),
 ('DELAY','OCC',TRUE,'{DISPATCH,STATION}'),
 ('RECOVER','OCC',TRUE,'{RECOVERY,STATION}');

-- E7. External systems (aeroMart / aeroOps / crew system): deep links + integration outbox
CREATE TABLE external_system (
    code                TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    purpose             TEXT,
    deep_link_template  TEXT,          -- placeholders: {flight_no} {flight_date} {dep} {arr} {reg} {crew_id}
    api_base_url        TEXT,
    enabled             BOOLEAN NOT NULL DEFAULT FALSE
);
INSERT INTO external_system (code, name, purpose, deep_link_template) VALUES
 ('AEROMART','aeroMart','Reservations / inventory: diversion and re-protection entries',
  'https://aeromart.example/flight?flt={flight_no}&date={flight_date}&dep={dep}'),
 ('AEROOPS','aeroOps','Operations / movement control',
  'https://aeroops.example/flight?flt={flight_no}&date={flight_date}&dep={dep}&arr={arr}&reg={reg}'),
 ('CREW_SYSTEM','Crew management system (name to confirm)','Crew tracking / rostering',
  'https://crew.example/duty?flt={flight_no}&date={flight_date}');

CREATE TABLE integration_outbox (
    message_id       BIGSERIAL PRIMARY KEY,
    system_code      TEXT NOT NULL REFERENCES external_system,
    scenario_id      INT NOT NULL REFERENCES scenario,
    decision_id      BIGINT REFERENCES decision,
    flight_id        BIGINT REFERENCES flight,
    action           TEXT NOT NULL,          -- CREATE_DIVERSION_ENTRY, UPDATE_ETD, CREW_CHANGE ...
    payload          JSONB NOT NULL,
    idempotency_key  TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','ACKED','FAILED','MANUAL')),
    attempts         INT NOT NULL DEFAULT 0,
    response         JSONB,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at          TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION deep_link(p_system TEXT, p_flight_id BIGINT, p_scenario_id INT DEFAULT 1)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT replace(replace(replace(replace(replace(es.deep_link_template,
             '{flight_no}', f.flight_no), '{flight_date}', f.flight_date::text),
             '{dep}', f.dep_iata), '{arr}', coalesce(s.actual_arr_iata, f.arr_iata)),
             '{reg}', coalesce(s.registration, f.registration_planned, ''))
      FROM external_system es, flight f
      LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
     WHERE es.code = p_system AND f.flight_id = p_flight_id
$$;

-- E8. KPI bar (per case) and severity score (per flight)
CREATE OR REPLACE VIEW v_flight_severity AS
SELECT w.case_id, w.scenario_id, w.flight_id, w.flight_no,
       coalesce((SELECT sum(pc.pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = w.flight_id), 0) AS connecting_pax,
       least(100, round(
           40 * CASE WHEN w.minutes_to_latest_legal_departure IS NOT NULL
                     THEN greatest(0, 1 - w.minutes_to_latest_legal_departure / 120.0) ELSE 0.3 END
         + 20 * CASE w.crew_status WHEN 'EXCEEDED' THEN 1 WHEN 'DISCRETION_REQUIRED' THEN .8
                                   WHEN 'AT_RISK' THEN .6 WHEN 'VERIFICATION_REQUIRED' THEN .5 ELSE 0 END
         + 15 * CASE WHEN w.lvp_required AND w.lvp_crew_ok IS NOT TRUE THEN 1 ELSE 0 END
         + 15 * least(1, coalesce((SELECT sum(pc.pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = w.flight_id), 0) / 200.0)
         + 10 * CASE WHEN w.open_exceptions > 0 THEN 1 ELSE 0 END))::int AS severity_score
  FROM v_flight_watch w;

CREATE OR REPLACE VIEW v_disruption_kpis AS
SELECT w.case_id, w.scenario_id,
       count(*)                                                               AS flights_watched,
       count(*) FILTER (WHERE w.status IN ('AIRBORNE','HOLDING','DIVERTING') OR w.diverted_to IS NOT NULL
                          OR w.status = 'SCHEDULED')                          AS flights_affected,
       count(*) FILTER (WHERE w.status = 'HOLDING')                           AS holding,
       count(*) FILTER (WHERE w.diverted_to IS NOT NULL)                      AS diverted,
       count(*) FILTER (WHERE w.crew_status IN ('AT_RISK','DISCRETION_REQUIRED','EXCEEDED')) AS crew_at_risk,
       count(*) FILTER (WHERE w.lvp_required AND w.lvp_crew_ok IS NOT TRUE)   AS lvp_blocked,
       count(*) FILTER (WHERE w.crew_status = 'VERIFICATION_REQUIRED' OR w.open_exceptions > 0) AS needs_verification,
       (SELECT count(*) FROM decision d WHERE d.case_id = w.case_id AND d.status = 'PROPOSED') AS decisions_pending,
       sum(coalesce(fs.pax, 0))                                               AS pax_on_board,
       sum(sv.connecting_pax)                                                 AS connecting_pax,
       min(w.minutes_to_latest_legal_departure)                               AS next_departure_deadline_min
  FROM v_flight_watch w
  LEFT JOIN flight_state fs ON fs.flight_id = w.flight_id AND fs.scenario_id = w.scenario_id
  LEFT JOIN v_flight_severity sv ON sv.case_id = w.case_id AND sv.flight_id = w.flight_id
 GROUP BY w.case_id, w.scenario_id;

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

-- pin search_path on the new functions too (same block as the end of 02_functions_triggers.sql)
DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
