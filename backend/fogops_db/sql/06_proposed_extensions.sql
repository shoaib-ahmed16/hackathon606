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
