-- =====================================================================
-- Fog Operations & Crew Duty Recovery Agent — PostgreSQL schema
-- Target: PostgreSQL 14+
-- Conventions
--   * Every timestamp is TIMESTAMPTZ and stored in UTC. Local times are
--     derived via airport.tz (IANA). Roster "local" values are kept
--     side-by-side with their UTC conversion.
--   * Operational facts are append-only events; "current" tables are
--     projections that can be rebuilt from the events.
--   * Anything the agent produces (recommendations, calculations, plans)
--     is versioned with is_current / superseded_by, never overwritten.
--   * Humans decide: decisions/approvals require a human role (enforced
--     by trigger in 02_functions_triggers.sql).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS fogops;
CREATE SCHEMA IF NOT EXISTS hist;
SET search_path = fogops, public;

-- ---------------------------------------------------------------------
-- 0. Enumerated types
-- ---------------------------------------------------------------------
CREATE TYPE flight_status      AS ENUM ('SCHEDULED','TAXI_OUT','AIRBORNE','HOLDING','DIVERTING',
                                        'LANDED','ON_BLOCKS','CANCELLED');
CREATE TYPE airport_op_status  AS ENUM ('OPEN','RESTRICTED','CLOSED');
CREATE TYPE data_quality       AS ENUM ('MEASURED','FORECAST','SIMULATED','ASSUMED','ESTIMATED','MANUAL');
CREATE TYPE legality_status    AS ENUM ('LEGAL','AT_RISK','DISCRETION_REQUIRED','EXCEEDED',
                                        'VERIFICATION_REQUIRED');
CREATE TYPE rec_type           AS ENUM ('HOLD','DIVERT','MONITOR','RECOVER','CREW_REPLACE',
                                        'DELAY_DEPARTURE','NO_ACTION');
CREATE TYPE rec_status         AS ENUM ('PROPOSED','ACCEPTED','REJECTED','SUPERSEDED','EXPIRED');
CREATE TYPE decision_type      AS ENUM ('HOLD','DIVERT','RECOVER','CANCEL','DELAY','CREW_REPLACE',
                                        'COMMANDER_DISCRETION','AIRCRAFT_SWAP','OVERRIDE','OTHER');
CREATE TYPE decision_status    AS ENUM ('PROPOSED','APPROVED','REJECTED','EXECUTED','REVOKED');
CREATE TYPE severity_level     AS ENUM ('INFO','WARN','BLOCKING');

-- ---------------------------------------------------------------------
-- 1. Reference data
-- ---------------------------------------------------------------------
CREATE TABLE airport (
    iata                 CHAR(3) PRIMARY KEY,
    icao                 CHAR(4) UNIQUE,
    name                 TEXT,
    country              TEXT,
    tz                   TEXT NOT NULL,                 -- IANA, e.g. Asia/Dubai
    min_ground_time_min  INT  NOT NULL DEFAULT 40,      -- from icao_iata_ground_time
    is_hub               BOOLEAN NOT NULL DEFAULT FALSE,
    latitude             NUMERIC(9,6),
    longitude            NUMERIC(9,6),
    CONSTRAINT chk_tz_valid CHECK (now() AT TIME ZONE tz IS NOT NULL)
);

-- Which airports may serve as alternates for a hub, and their static suitability.
-- Dynamic suitability (open/closed, parking, weather) lives in airport_status_event.
CREATE TABLE alternate_airport (
    hub_iata                CHAR(3) REFERENCES airport,
    alt_iata                CHAR(3) REFERENCES airport,
    priority                SMALLINT NOT NULL DEFAULT 100,   -- lower = preferred
    road_positioning_min    INT,          -- crew positioning by road from hub (NULL = not by road)
    max_parking_stands      INT,
    handling_contract       BOOLEAN NOT NULL DEFAULT TRUE,
    fuel_available          BOOLEAN NOT NULL DEFAULT TRUE,
    customs_24h             BOOLEAN NOT NULL DEFAULT TRUE,
    historical_diversions   INT NOT NULL DEFAULT 0,
    notes                   TEXT,
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (hub_iata, alt_iata),
    CHECK (hub_iata <> alt_iata)
);

CREATE TABLE aircraft (
    registration  TEXT PRIMARY KEY,
    ac_type       TEXT,
    seats         INT,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE crew_type (
    code         TEXT PRIMARY KEY,       -- CP, FO, SO, CS, CC, SEC
    description  TEXT NOT NULL,
    category     TEXT NOT NULL CHECK (category IN ('COCKPIT','CABIN','OTHER')),
    -- only operating crew decide whether a flight is legal; others are evaluated and flagged
    gates_flight_legality BOOLEAN NOT NULL DEFAULT TRUE
);

-- Planned/average block times used for latest-departure math (e.g. FJR->SHJ)
CREATE TABLE block_time_reference (
    from_iata         CHAR(3) REFERENCES airport,
    to_iata           CHAR(3) REFERENCES airport,
    median_block_min  INT NOT NULL,
    p90_block_min     INT NOT NULL,
    sample_n          INT NOT NULL,
    source            TEXT NOT NULL,          -- e.g. 'hist.flight Jan-Nov 2026'
    computed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (from_iata, to_iata)
);

-- ---------------------------------------------------------------------
-- 2. Users, roles, scenarios, cases
-- ---------------------------------------------------------------------
CREATE TABLE app_role (
    code            TEXT PRIMARY KEY,   -- OCC, DISPATCH, CREW_CONTROL, STATION, RECOVERY, ADMIN, AGENT
    description     TEXT NOT NULL,
    is_human        BOOLEAN NOT NULL DEFAULT TRUE,
    can_approve     BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE app_user (
    user_id       SERIAL PRIMARY KEY,
    username      TEXT UNIQUE NOT NULL,
    display_name  TEXT NOT NULL,
    role_code     TEXT NOT NULL REFERENCES app_role,
    station_iata  CHAR(3) REFERENCES airport,      -- for station users
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- LIVE = the operational picture; REPLAY = demo replay; WHATIF = stretch-goal comparison
CREATE TABLE scenario (
    scenario_id         SERIAL PRIMARY KEY,
    name                TEXT NOT NULL UNIQUE,
    kind                TEXT NOT NULL CHECK (kind IN ('LIVE','REPLAY','WHATIF')),
    parent_scenario_id  INT REFERENCES scenario,
    description         TEXT,
    sim_clock_utc       TIMESTAMPTZ,     -- "now" for replays; NULL = wall clock
    overrides           JSONB NOT NULL DEFAULT '{}'::jsonb,  -- what-if parameters
    created_by          INT REFERENCES app_user,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE disruption_case (
    case_id      SERIAL PRIMARY KEY,
    scenario_id  INT NOT NULL REFERENCES scenario,
    title        TEXT NOT NULL,
    hub_iata     CHAR(3) NOT NULL REFERENCES airport,
    cause        TEXT NOT NULL DEFAULT 'FOG',
    phase        TEXT NOT NULL DEFAULT 'MONITORING'
                 CHECK (phase IN ('MONITORING','RESTRICTED','RECOVERY','CLOSED')),
    opened_by    INT REFERENCES app_user,
    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at    TIMESTAMPTZ,
    summary      TEXT
);

-- ---------------------------------------------------------------------
-- 3. Crew duty rules (versioned, approved, immutable once approved)
-- ---------------------------------------------------------------------
CREATE TABLE rule_set (
    rule_set_id                SERIAL PRIMARY KEY,
    name                       TEXT NOT NULL,             -- 'GCAA FDP'
    version                    TEXT NOT NULL,             -- 'v1-2026-11-20'
    source_document            TEXT NOT NULL,             -- 'Crew_FDTL.xlsx'
    checksum_sha256            TEXT,
    status                     TEXT NOT NULL DEFAULT 'DRAFT'
                               CHECK (status IN ('DRAFT','APPROVED','RETIRED')),
    effective_from             TIMESTAMPTZ NOT NULL,
    effective_to               TIMESTAMPTZ,
    commander_discretion_min   INT NOT NULL DEFAULT 180,
    -- Which local clock decides the FDP time band:
    --   HOME_BASE      = crew base timezone (validated: matches sheet for SHJ-origin duties)
    --   SIGNIN_STATION = timezone of the reporting station
    band_reference             TEXT NOT NULL DEFAULT 'SIGNIN_STATION'
                               CHECK (band_reference IN ('HOME_BASE','SIGNIN_STATION')),
    at_risk_threshold_min      INT NOT NULL DEFAULT 60,   -- margin below this = AT_RISK
    count_positioning_as_leg   BOOLEAN NOT NULL DEFAULT FALSE,
    parameters                 JSONB NOT NULL DEFAULT '{}'::jsonb,
    approved_by                TEXT,
    approved_at                TIMESTAMPTZ,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (name, version),
    CHECK (status <> 'APPROVED' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
-- only one approved, open-ended version per rule family
CREATE UNIQUE INDEX ux_rule_set_one_active
    ON rule_set (name) WHERE status = 'APPROVED' AND effective_to IS NULL;

CREATE TABLE fdp_rule (
    rule_id            SERIAL PRIMARY KEY,
    rule_set_id        INT NOT NULL REFERENCES rule_set ON DELETE CASCADE,
    source_rule_id     INT,                           -- FDP_ID in Crew_FDTL.xlsx
    crew_type_code     TEXT NOT NULL REFERENCES crew_type,
    local_start_from   TIME NOT NULL,
    local_start_to     TIME NOT NULL,
    no_of_legs         SMALLINT NOT NULL CHECK (no_of_legs BETWEEN 0 AND 8),
    max_fdp_min        INT NOT NULL CHECK (max_fdp_min > 0),
    UNIQUE (rule_set_id, crew_type_code, local_start_from, no_of_legs),
    CHECK (local_start_to > local_start_from)
);

-- ---------------------------------------------------------------------
-- 4. Flights, live feed, current state
-- ---------------------------------------------------------------------
CREATE TABLE flight (
    flight_id             BIGSERIAL PRIMARY KEY,
    flight_no             TEXT NOT NULL,                -- SAI, e.g. G9071 / G9071D
    flight_date           DATE NOT NULL,                -- UTC date of STD
    dep_iata              CHAR(3) NOT NULL REFERENCES airport,
    arr_iata              CHAR(3) NOT NULL REFERENCES airport,   -- planned destination
    std_utc               TIMESTAMPTZ NOT NULL,
    sta_utc               TIMESTAMPTZ NOT NULL,
    registration_planned  TEXT REFERENCES aircraft,
    op_type               TEXT,
    flight_kind           TEXT NOT NULL DEFAULT 'SCHEDULED'
                          CHECK (flight_kind IN ('SCHEDULED','RECOVERY','FERRY','POSITIONING','TEST')),
    parent_flight_id      BIGINT REFERENCES flight,     -- recovery leg -> diverted flight
    pax_planned           INT,
    source                TEXT NOT NULL,                -- file / system of origin
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (flight_no, std_utc, dep_iata),
    CHECK (sta_utc > std_utc)
);
CREATE INDEX ix_flight_std ON flight (std_utc);
CREATE INDEX ix_flight_arr ON flight (arr_iata, sta_utc);

CREATE TABLE feed_source (
    source_code        TEXT PRIMARY KEY,               -- OCC_ROTATION, SIM_FEED, MANUAL
    description        TEXT,
    stale_after_sec    INT NOT NULL DEFAULT 600,
    last_event_ts      TIMESTAMPTZ,
    last_received_at   TIMESTAMPTZ
);

-- Raw, append-only event log. Never updated (except apply bookkeeping), never deleted.
-- payload keys used by the projector: etd, eta, atd, toff, tdown, ata, registration,
--   pax, status, actual_arr_iata, holding (true/false), cancelled (true/false)
CREATE TABLE flight_event (
    event_id         BIGSERIAL PRIMARY KEY,
    scenario_id      INT NOT NULL REFERENCES scenario,
    flight_id        BIGINT NOT NULL REFERENCES flight,
    source_code      TEXT NOT NULL REFERENCES feed_source,
    message_id       TEXT NOT NULL,                    -- idempotency key from the source
    seq_no           BIGINT,                           -- source sequence, if provided
    event_type       TEXT NOT NULL,                    -- SNAPSHOT, ETA_UPDATE, OUT, OFF, ON, IN, HOLD, DIVERT...
    event_ts         TIMESTAMPTZ NOT NULL,             -- when it happened at the source
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload          JSONB NOT NULL,
    apply_result     TEXT,                             -- APPLIED, PARTIAL_OUT_OF_ORDER, IGNORED_STALE
    fields_applied   TEXT[],
    UNIQUE (scenario_id, source_code, message_id)
);
CREATE INDEX ix_flight_event_flight ON flight_event (scenario_id, flight_id, event_ts);

-- Projection: latest known state per flight per scenario.
CREATE TABLE flight_state (
    scenario_id        INT NOT NULL REFERENCES scenario,
    flight_id          BIGINT NOT NULL REFERENCES flight,
    registration       TEXT REFERENCES aircraft,
    etd_utc            TIMESTAMPTZ,
    eta_utc            TIMESTAMPTZ,
    atd_utc            TIMESTAMPTZ,     -- off-blocks (OUT)
    toff_utc           TIMESTAMPTZ,     -- wheels off (OFF)
    tdown_utc          TIMESTAMPTZ,     -- wheels on  (ON)
    ata_utc            TIMESTAMPTZ,     -- on-blocks  (IN)
    actual_arr_iata    CHAR(3) REFERENCES airport,  -- differs from flight.arr_iata when diverted
    is_holding         BOOLEAN NOT NULL DEFAULT FALSE,
    holding_since_utc  TIMESTAMPTZ,
    is_cancelled       BOOLEAN NOT NULL DEFAULT FALSE,
    pax                INT,
    status             flight_status NOT NULL DEFAULT 'SCHEDULED',   -- derived, never typed by hand
    field_ts           JSONB NOT NULL DEFAULT '{}'::jsonb,  -- per-field event_ts (out-of-order guard)
    last_event_id      BIGINT REFERENCES flight_event,
    last_event_ts      TIMESTAMPTZ,
    last_received_at   TIMESTAMPTZ,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (scenario_id, flight_id)
);
CREATE INDEX ix_flight_state_reg ON flight_state (scenario_id, registration);

-- Fuel / holding endurance, always labelled with its quality
CREATE TABLE flight_fuel_estimate (
    estimate_id                BIGSERIAL PRIMARY KEY,
    scenario_id                INT NOT NULL REFERENCES scenario,
    flight_id                  BIGINT NOT NULL REFERENCES flight,
    as_of_utc                  TIMESTAMPTZ NOT NULL,
    fuel_on_board_kg           INT,
    min_diversion_fuel_kg      INT,
    burn_rate_hold_kg_per_hr   INT,
    est_holding_endurance_min  INT,
    quality                    data_quality NOT NULL,
    basis                      JSONB NOT NULL DEFAULT '{}'::jsonb,
    entered_by                 INT REFERENCES app_user,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_fuel_flight ON flight_fuel_estimate (scenario_id, flight_id, as_of_utc DESC);

CREATE TABLE pax_connection (
    inbound_flight_id   BIGINT NOT NULL REFERENCES flight,
    outbound_flight_id  BIGINT NOT NULL REFERENCES flight,
    pax_count           INT NOT NULL CHECK (pax_count >= 0),
    PRIMARY KEY (inbound_flight_id, outbound_flight_id)
);

-- ---------------------------------------------------------------------
-- 5. Airport operating status (SHJ fog, alternates) — append-only
-- ---------------------------------------------------------------------
CREATE TABLE airport_status_event (
    status_event_id            BIGSERIAL PRIMARY KEY,
    scenario_id                INT NOT NULL REFERENCES scenario,
    iata                       CHAR(3) NOT NULL REFERENCES airport,
    op_status                  airport_op_status NOT NULL,
    reason                     TEXT,                 -- FOG, LVP, RWY_CLOSED...
    visibility_m               INT,
    arrival_capacity_per_hr    INT CHECK (arrival_capacity_per_hr >= 0),
    departure_capacity_per_hr  INT CHECK (departure_capacity_per_hr >= 0),
    parking_available          INT,
    weather_above_minima       BOOLEAN,
    handling_ok                BOOLEAN,
    fuel_ok                    BOOLEAN,
    effective_from_utc         TIMESTAMPTZ NOT NULL,
    expected_reopen_utc        TIMESTAMPTZ,          -- forecast fog clearance
    quality                    data_quality NOT NULL DEFAULT 'MANUAL',
    entered_by                 INT REFERENCES app_user,
    entered_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    note                       TEXT
);
CREATE INDEX ix_airport_status ON airport_status_event (scenario_id, iata, effective_from_utc DESC, status_event_id DESC);

-- ---------------------------------------------------------------------
-- 6. Crew
-- ---------------------------------------------------------------------
CREATE TABLE crew_member (
    crew_id          INT PRIMARY KEY,
    full_name        TEXT NOT NULL,
    crew_type_code   TEXT NOT NULL REFERENCES crew_type,
    base_iata        CHAR(3) REFERENCES airport,
    gender           TEXT,
    languages        TEXT[],
    aircraft_types   TEXT[],
    mobile           TEXT,           -- synthetic test data only
    is_active        BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE crew_qualification (
    crew_id    INT REFERENCES crew_member ON DELETE CASCADE,
    qual_code  TEXT NOT NULL,        -- LVP, ETOP, TRN
    source     TEXT,
    PRIMARY KEY (crew_id, qual_code)
);

-- A duty = one crew pairing for one day (Duty Sheet block)
CREATE TABLE crew_duty (
    duty_id                BIGSERIAL PRIMARY KEY,
    duty_date              DATE NOT NULL,
    source_duty_no         INT,
    source_file            TEXT,
    report_station_iata    CHAR(3) REFERENCES airport,
    sign_in_utc            TIMESTAMPTZ,               -- NULL => legality blocked
    oper_base              TEXT,
    -- values copied from the sheet for comparison only; never used for legality
    sheet_block_fdp_min    INT,
    sheet_duration_min     INT,
    status                 TEXT NOT NULL DEFAULT 'PLANNED'
                           CHECK (status IN ('PLANNED','ACTIVE','COMPLETED','BROKEN','CANCELLED')),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (duty_date, source_duty_no, source_file)
);

-- Legs and assignments are scenario-scoped: a diversion or crew swap in a replay/what-if
-- never leaks into LIVE. clone_scenario() copies them.
CREATE TABLE crew_duty_leg (
    scenario_id           INT NOT NULL REFERENCES scenario,
    duty_id               BIGINT NOT NULL REFERENCES crew_duty ON DELETE CASCADE,
    leg_seq               SMALLINT NOT NULL,
    flight_id             BIGINT NOT NULL REFERENCES flight,
    leg_source            TEXT NOT NULL DEFAULT 'PLANNED'
                          CHECK (leg_source IN ('PLANNED','DIVERSION','RECOVERY','POSITIONING')),
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    added_by_decision_id  BIGINT,          -- FK added after decision table exists
    added_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (scenario_id, duty_id, leg_seq)
);
CREATE INDEX ix_duty_leg_flight ON crew_duty_leg (scenario_id, flight_id);

-- Who is on the duty. Temporal: a swap closes one row (valid_to) and opens another.
CREATE TABLE crew_assignment (
    assignment_id           BIGSERIAL PRIMARY KEY,
    scenario_id             INT NOT NULL REFERENCES scenario,
    duty_id                 BIGINT NOT NULL REFERENCES crew_duty ON DELETE CASCADE,
    crew_id                 INT NOT NULL REFERENCES crew_member,
    position_code           TEXT NOT NULL REFERENCES crew_type,   -- position flown on this duty
    valid_from              TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_to                TIMESTAMPTZ,
    source                  TEXT NOT NULL DEFAULT 'DUTY_SHEET'
                            CHECK (source IN ('DUTY_SHEET','SWAP','REPLACEMENT','MANUAL')),
    replaced_assignment_id  BIGINT REFERENCES crew_assignment,
    -- replacement crew start their own FDP: own sign-in, own report station, first leg they operate
    sign_in_utc             TIMESTAMPTZ,          -- NULL = use crew_duty.sign_in_utc
    report_station_iata     CHAR(3) REFERENCES airport,
    from_leg_seq            SMALLINT NOT NULL DEFAULT 1,
    sheet_max_fdp_min       INT,                  -- from Duty Sheet, comparison only
    changed_by              INT REFERENCES app_user,
    change_reason           TEXT,
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX ux_assignment_active ON crew_assignment (scenario_id, duty_id, crew_id) WHERE valid_to IS NULL;
CREATE INDEX ix_assignment_crew ON crew_assignment (scenario_id, crew_id) WHERE valid_to IS NULL;

-- 10-day roster. Source file is LOCAL time; UTC is derived using the crew base tz.
CREATE TABLE roster_entry (
    roster_id         BIGSERIAL PRIMARY KEY,
    crew_id           INT NOT NULL REFERENCES crew_member,
    duty_type         TEXT NOT NULL,           -- FLIGHT, EVENT, LEAVE, TRAINING, SIM, GRT, DUTY, REST
    block_name        TEXT,
    start_local       TIMESTAMP NOT NULL,
    end_local         TIMESTAMP NOT NULL,
    local_tz          TEXT NOT NULL,
    start_utc         TIMESTAMPTZ NOT NULL,
    end_utc           TIMESTAMPTZ NOT NULL,
    flying_min        INT,
    duty_min          INT,
    no_of_legs        SMALLINT,
    blocks_standby_use BOOLEAN GENERATED ALWAYS AS (duty_type NOT IN ('EVENT')) STORED
);
CREATE INDEX ix_roster_crew_time ON roster_entry (crew_id, start_utc, end_utc);

CREATE TABLE standby_slot (
    standby_id         BIGSERIAL PRIMARY KEY,
    duty_date          DATE NOT NULL,
    pattern_name       TEXT NOT NULL,           -- ESBY-22:00, SBY 1-02:00 ...
    crew_id            INT NOT NULL REFERENCES crew_member,
    crew_type_code     TEXT NOT NULL REFERENCES crew_type,
    location_iata      CHAR(3) REFERENCES airport,
    start_utc          TIMESTAMPTZ NOT NULL,
    end_utc            TIMESTAMPTZ NOT NULL,
    times_basis        TEXT NOT NULL DEFAULT 'ASSUMED_UTC',   -- flagged until organizers confirm
    total_flying_hrs   NUMERIC(6,2),
    status             TEXT NOT NULL DEFAULT 'AVAILABLE'
                       CHECK (status IN ('AVAILABLE','RESERVED','CALLED_OUT','RELEASED')),
    source_file        TEXT,
    UNIQUE (duty_date, pattern_name, crew_id)
);

-- ---------------------------------------------------------------------
-- 7. Legality & latest-departure calculations (immutable, versioned)
-- ---------------------------------------------------------------------
CREATE TABLE fdp_calculation (
    calc_id               BIGSERIAL PRIMARY KEY,
    scenario_id           INT NOT NULL REFERENCES scenario,
    duty_id               BIGINT NOT NULL REFERENCES crew_duty,
    crew_id               INT REFERENCES crew_member,     -- NULL = duty-level binding summary
    position_code         TEXT REFERENCES crew_type,
    rule_set_id           INT NOT NULL REFERENCES rule_set,
    rule_id               INT REFERENCES fdp_rule,
    sign_in_utc           TIMESTAMPTZ,
    band_tz               TEXT,
    sign_in_local_time    TIME,
    legs_counted          SMALLINT,
    max_fdp_min           INT,
    legal_end_utc         TIMESTAMPTZ,
    discretion_end_utc    TIMESTAMPTZ,
    projected_end_utc     TIMESTAMPTZ,     -- projected on-blocks of the last leg
    margin_min            INT,             -- legal_end - projected_end
    discretion_margin_min INT,
    status                legality_status NOT NULL,
    reasons               TEXT[] NOT NULL DEFAULT '{}',
    inputs                JSONB NOT NULL DEFAULT '{}'::jsonb,   -- everything used, for display/audit
    is_current            BOOLEAN NOT NULL DEFAULT TRUE,
    triggered_by          TEXT,
    calculated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_fdp_calc_current ON fdp_calculation (scenario_id, duty_id) WHERE is_current;
CREATE INDEX ix_fdp_calc_crew    ON fdp_calculation (scenario_id, crew_id) WHERE is_current;

CREATE TABLE latest_departure_calc (
    calc_id                      BIGSERIAL PRIMARY KEY,
    scenario_id                  INT NOT NULL REFERENCES scenario,
    flight_id                    BIGINT NOT NULL REFERENCES flight,   -- the onward leg (e.g. FJR->SHJ)
    from_iata                    CHAR(3) NOT NULL REFERENCES airport,
    to_iata                      CHAR(3) NOT NULL REFERENCES airport,
    duty_id                      BIGINT REFERENCES crew_duty,
    binding_crew_id              INT REFERENCES crew_member,
    fdp_calc_id                  BIGINT REFERENCES fdp_calculation,
    legal_end_utc                TIMESTAMPTZ,
    discretion_end_utc           TIMESTAMPTZ,
    block_time_min               INT,
    block_time_basis             TEXT,      -- 'P90 hist FJR-SHJ n=12' / 'schedule' / 'assumed'
    latest_legal_offblocks_utc   TIMESTAMPTZ,
    latest_with_discretion_utc   TIMESTAMPTZ,
    operational_buffer_min       INT,
    operational_target_utc       TIMESTAMPTZ,
    status                       legality_status NOT NULL,
    assumptions                  JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_current                   BOOLEAN NOT NULL DEFAULT TRUE,
    calculated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (operational_target_utc IS NULL OR latest_legal_offblocks_utc IS NULL
           OR operational_target_utc <= latest_legal_offblocks_utc)
);
CREATE INDEX ix_ld_current ON latest_departure_calc (scenario_id, flight_id) WHERE is_current;

-- ---------------------------------------------------------------------
-- 8. Case watch list, recommendations, decisions
-- ---------------------------------------------------------------------
CREATE TABLE case_flight (
    case_id       INT NOT NULL REFERENCES disruption_case,
    flight_id     BIGINT NOT NULL REFERENCES flight,
    fog_exposure  TEXT NOT NULL DEFAULT 'NONE' CHECK (fog_exposure IN ('NONE','LOW','MEDIUM','HIGH')),
    owner_user_id INT REFERENCES app_user,
    owner_role    TEXT REFERENCES app_role,
    watch_note    TEXT,
    added_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (case_id, flight_id)
);

CREATE TABLE recommendation (
    rec_id                  BIGSERIAL PRIMARY KEY,
    scenario_id             INT NOT NULL REFERENCES scenario,
    case_id                 INT NOT NULL REFERENCES disruption_case,
    flight_id               BIGINT NOT NULL REFERENCES flight,
    rec_type                rec_type NOT NULL,
    confidence              NUMERIC(3,2) CHECK (confidence BETWEEN 0 AND 1),
    rationale               TEXT NOT NULL,
    assumptions             JSONB NOT NULL DEFAULT '[]'::jsonb,
    uncertainty             JSONB NOT NULL DEFAULT '{}'::jsonb,
    required_approver_role  TEXT NOT NULL REFERENCES app_role,
    status                  rec_status NOT NULL DEFAULT 'PROPOSED',
    superseded_by           BIGINT REFERENCES recommendation,
    rule_set_id             INT REFERENCES rule_set,
    input_snapshot          JSONB NOT NULL DEFAULT '{}'::jsonb,   -- state the agent saw
    generated_by            TEXT NOT NULL,       -- 'agent:fogops v0.3 / model x'
    generated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until_utc         TIMESTAMPTZ
);
CREATE INDEX ix_rec_flight ON recommendation (scenario_id, flight_id, generated_at DESC);
CREATE UNIQUE INDEX ux_rec_one_open ON recommendation (scenario_id, flight_id) WHERE status = 'PROPOSED';

CREATE TABLE recommendation_option (
    option_id              BIGSERIAL PRIMARY KEY,
    rec_id                 BIGINT NOT NULL REFERENCES recommendation ON DELETE CASCADE,
    rank                   SMALLINT NOT NULL,
    action                 rec_type NOT NULL,
    alternate_iata         CHAR(3) REFERENCES airport,
    hold_until_utc         TIMESTAMPTZ,
    est_arrival_utc        TIMESTAMPTZ,
    fuel_margin_min        INT,
    crew_margin_min        INT,
    score                  NUMERIC(8,3),
    is_executable          BOOLEAN NOT NULL,     -- FALSE if any hard constraint unmet/unknown
    blocking_constraints   JSONB NOT NULL DEFAULT '[]'::jsonb,
    reasons                TEXT[] NOT NULL DEFAULT '{}',
    UNIQUE (rec_id, rank)
);

CREATE TABLE decision (
    decision_id              BIGSERIAL PRIMARY KEY,
    scenario_id              INT NOT NULL REFERENCES scenario,
    case_id                  INT NOT NULL REFERENCES disruption_case,
    flight_id                BIGINT REFERENCES flight,
    rec_id                   BIGINT REFERENCES recommendation,
    option_id                BIGINT REFERENCES recommendation_option,
    decision_type            decision_type NOT NULL,
    alternate_iata           CHAR(3) REFERENCES airport,
    target_time_utc          TIMESTAMPTZ,      -- e.g. hold until / planned departure
    followed_recommendation  BOOLEAN,
    rationale                TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
    status                   decision_status NOT NULL DEFAULT 'PROPOSED',
    decided_by               INT NOT NULL REFERENCES app_user,
    decided_role             TEXT NOT NULL REFERENCES app_role,
    decided_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    executed_at              TIMESTAMPTZ,
    revoked_by               INT REFERENCES app_user,
    revoked_at               TIMESTAMPTZ,
    revoke_reason            TEXT,
    details                  JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_decision_flight ON decision (scenario_id, flight_id, decided_at DESC);

ALTER TABLE crew_duty_leg
    ADD CONSTRAINT fk_duty_leg_decision FOREIGN KEY (added_by_decision_id) REFERENCES decision;

CREATE TABLE decision_approval (
    approval_id    BIGSERIAL PRIMARY KEY,
    decision_id    BIGINT NOT NULL REFERENCES decision,
    approver_id    INT NOT NULL REFERENCES app_user,
    approver_role  TEXT NOT NULL REFERENCES app_role,
    verdict        TEXT NOT NULL CHECK (verdict IN ('APPROVED','REJECTED')),
    comment        TEXT,
    approved_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (decision_id, approver_id)
);

-- Station-side tracking of a diverted aircraft ("what is it waiting for?")
CREATE TABLE diversion (
    diversion_id              BIGSERIAL PRIMARY KEY,
    scenario_id               INT NOT NULL REFERENCES scenario,
    case_id                   INT NOT NULL REFERENCES disruption_case,
    original_flight_id        BIGINT NOT NULL REFERENCES flight,
    alternate_iata            CHAR(3) NOT NULL REFERENCES airport,
    decision_id               BIGINT REFERENCES decision,
    recovery_flight_id        BIGINT REFERENCES flight,
    landed_alt_utc            TIMESTAMPTZ,
    on_blocks_alt_utc         TIMESTAMPTZ,
    turnaround_min_assumed    INT,
    refuel_status             TEXT NOT NULL DEFAULT 'PENDING'
                              CHECK (refuel_status IN ('PENDING','IN_PROGRESS','DONE','NOT_REQUIRED')),
    handling_status           TEXT NOT NULL DEFAULT 'PENDING'
                              CHECK (handling_status IN ('PENDING','IN_PROGRESS','DONE')),
    pax_onboard               BOOLEAN NOT NULL DEFAULT TRUE,
    waiting_for               TEXT NOT NULL DEFAULT 'LANDING'
                              CHECK (waiting_for IN ('LANDING','HANDLING','FUEL','HUB_REOPENING','ARRIVAL_SLOT',
                                                     'REPLACEMENT_CREW','CREW_REST','ATC','NOTHING')),
    planned_departure_utc     TIMESTAMPTZ,
    actual_departure_utc      TIMESTAMPTZ,
    status                    TEXT NOT NULL DEFAULT 'DIVERTING'
                              CHECK (status IN ('DIVERTING','ON_GROUND_ALT','READY','DEPARTED','CLOSED','CANCELLED')),
    updated_by                INT REFERENCES app_user,
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (scenario_id, original_flight_id)
);

CREATE TABLE crew_replacement (
    replacement_id          BIGSERIAL PRIMARY KEY,
    scenario_id             INT NOT NULL REFERENCES scenario,
    case_id                 INT NOT NULL REFERENCES disruption_case,
    duty_id                 BIGINT NOT NULL REFERENCES crew_duty,
    outgoing_crew_id        INT NOT NULL REFERENCES crew_member,
    incoming_crew_id        INT NOT NULL REFERENCES crew_member,
    standby_id              BIGINT REFERENCES standby_slot,
    positioning_from_iata   CHAR(3) REFERENCES airport,
    positioning_to_iata     CHAR(3) REFERENCES airport,
    positioning_mode        TEXT CHECK (positioning_mode IN ('ROAD','DEADHEAD','NONE')),
    positioning_min         INT,
    new_sign_in_utc         TIMESTAMPTZ,
    roster_conflict         BOOLEAN NOT NULL DEFAULT FALSE,
    roster_conflict_detail  JSONB NOT NULL DEFAULT '[]'::jsonb,
    decision_id             BIGINT REFERENCES decision,
    status                  TEXT NOT NULL DEFAULT 'PROPOSED'
                            CHECK (status IN ('PROPOSED','APPROVED','IN_POSITION','CANCELLED')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 9. Recovery sequencing after hub reopens
-- ---------------------------------------------------------------------
CREATE TABLE recovery_plan (
    plan_id               BIGSERIAL PRIMARY KEY,
    scenario_id           INT NOT NULL REFERENCES scenario,
    case_id               INT NOT NULL REFERENCES disruption_case,
    hub_iata              CHAR(3) NOT NULL REFERENCES airport,
    reopening_utc         TIMESTAMPTZ NOT NULL,
    window_start_utc      TIMESTAMPTZ NOT NULL,
    window_end_utc        TIMESTAMPTZ NOT NULL,
    capacity_per_hr       INT NOT NULL CHECK (capacity_per_hr > 0),
    arrivals_in_window    INT,
    status                TEXT NOT NULL DEFAULT 'PROPOSED'
                          CHECK (status IN ('PROPOSED','APPROVED','SUPERSEDED','REJECTED')),
    weights               JSONB NOT NULL,
    inputs                JSONB NOT NULL DEFAULT '{}'::jsonb,
    generated_by          TEXT NOT NULL,
    generated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by           INT REFERENCES app_user,
    approved_at           TIMESTAMPTZ,
    CHECK (window_end_utc > window_start_utc)
);

CREATE TABLE recovery_plan_item (
    plan_id              BIGINT NOT NULL REFERENCES recovery_plan ON DELETE CASCADE,
    rank                 SMALLINT NOT NULL,
    flight_id            BIGINT NOT NULL REFERENCES flight,
    current_location     TEXT,              -- AIRBORNE_HOLDING / ON_GROUND_<ALT> / NOT_DEPARTED
    earliest_arrival_utc TIMESTAMPTZ,
    proposed_slot_utc    TIMESTAMPTZ,
    within_window        BOOLEAN,
    is_feasible          BOOLEAN NOT NULL,
    priority_score       NUMERIC(8,3),
    score_breakdown      JSONB NOT NULL DEFAULT '{}'::jsonb,
    reasons              TEXT[] NOT NULL DEFAULT '{}',
    infeasible_reason    TEXT,
    PRIMARY KEY (plan_id, flight_id),
    UNIQUE (plan_id, rank)
);

-- ---------------------------------------------------------------------
-- 10. Collaboration, exceptions, audit, reassessment, reports
-- ---------------------------------------------------------------------
CREATE TABLE case_comment (
    comment_id         BIGSERIAL PRIMARY KEY,
    case_id            INT NOT NULL REFERENCES disruption_case,
    flight_id          BIGINT REFERENCES flight,
    parent_comment_id  BIGINT REFERENCES case_comment,
    author_id          INT NOT NULL REFERENCES app_user,
    author_role        TEXT NOT NULL REFERENCES app_role,
    body               TEXT NOT NULL CHECK (length(trim(body)) > 0),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_comment_case ON case_comment (case_id, created_at);

-- "Verification required" items and data-quality findings shown in the UI
CREATE TABLE data_exception (
    exception_id   BIGSERIAL PRIMARY KEY,
    scenario_id    INT REFERENCES scenario,
    entity_type    TEXT NOT NULL,         -- crew_duty, flight, crew_member, feed_source...
    entity_id      TEXT NOT NULL,
    code           TEXT NOT NULL,         -- MAXFDP_MISMATCH, CREW_TYPE_NOT_IN_RULESET, STALE_FEED...
    severity       severity_level NOT NULL,
    message        TEXT NOT NULL,
    detail         JSONB NOT NULL DEFAULT '{}'::jsonb,
    status         TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED')),
    raised_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_by    INT REFERENCES app_user,
    resolved_at    TIMESTAMPTZ,
    resolution     TEXT
);
CREATE UNIQUE INDEX ux_exception_open
    ON data_exception (coalesce(scenario_id,0), entity_type, entity_id, code) WHERE status <> 'RESOLVED';

-- Generic append-only audit log (filled by triggers)
CREATE TABLE audit_log (
    audit_id       BIGSERIAL PRIMARY KEY,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),   -- wall clock
    scenario_time_utc TIMESTAMPTZ,       -- scenario clock (replays run on simulated time)
    actor_user_id  INT,
    actor_role     TEXT,
    scenario_id    INT,
    case_id        INT,
    entity_type    TEXT NOT NULL,
    entity_id      TEXT NOT NULL,
    action         TEXT NOT NULL,         -- INSERT / UPDATE / DELETE
    changed_fields TEXT[],
    before_data    JSONB,
    after_data     JSONB,
    txid           BIGINT NOT NULL DEFAULT txid_current()
);
CREATE INDEX ix_audit_case   ON audit_log (case_id, occurred_at);
CREATE INDEX ix_audit_entity ON audit_log (entity_type, entity_id, occurred_at);

-- Anything that changes inputs enqueues a reassessment; the agent worker LISTENs on 'fogops_reassess'
CREATE TABLE reassessment_queue (
    job_id        BIGSERIAL PRIMARY KEY,
    scenario_id   INT NOT NULL REFERENCES scenario,
    reason        TEXT NOT NULL,          -- ETA_CHANGED, AIRPORT_STATUS, CREW_CHANGE, DECISION
    entity_type   TEXT NOT NULL,
    entity_id     TEXT NOT NULL,
    detail        JSONB NOT NULL DEFAULT '{}'::jsonb,
    enqueued_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    picked_at     TIMESTAMPTZ,
    done_at       TIMESTAMPTZ,
    status        TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','DONE','FAILED')),
    error         TEXT
);
CREATE INDEX ix_reassess_pending ON reassessment_queue (status, enqueued_at) WHERE status = 'PENDING';

CREATE TABLE report (
    report_id           BIGSERIAL PRIMARY KEY,
    case_id             INT NOT NULL REFERENCES disruption_case,
    scenario_id         INT NOT NULL REFERENCES scenario,
    report_type         TEXT NOT NULL DEFAULT 'DISRUPTION_SUMMARY',
    generated_by        INT REFERENCES app_user,
    generated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    audit_watermark_id  BIGINT,          -- last audit_id included => reproducible
    rule_set_id         INT REFERENCES rule_set,
    content             JSONB NOT NULL,
    file_uri            TEXT
);

-- ---------------------------------------------------------------------
-- 11. Historical data (read-only reference for replay and estimates)
-- ---------------------------------------------------------------------
CREATE TABLE hist.flight (
    hist_id            BIGSERIAL PRIMARY KEY,
    flight_no          TEXT,
    registration       TEXT,
    dep_iata           TEXT,
    arr_iata           TEXT,          -- where it actually went (alternate when diverted)
    planned_dest_icao  TEXT,          -- original destination
    op_type            TEXT,
    std_utc            TIMESTAMPTZ,
    sta_utc            TIMESTAMPTZ,
    atd_utc            TIMESTAMPTZ,
    toff_utc           TIMESTAMPTZ,
    tdown_utc          TIMESTAMPTZ,
    ata_utc            TIMESTAMPTZ,
    dep_delay_min      INT,
    arr_delay_min      INT,
    dep_delay_codes    TEXT,
    arr_delay_codes    TEXT,
    pax                INT,
    block_min          INT,
    is_diversion       BOOLEAN,
    is_gtb             BOOLEAN,
    is_atb             BOOLEAN
);
CREATE INDEX ix_hist_flight_std ON hist.flight (std_utc);
CREATE INDEX ix_hist_flight_div ON hist.flight (is_diversion) WHERE is_diversion;

CREATE TABLE hist.fuel (
    hist_fuel_id            BIGSERIAL PRIMARY KEY,
    registration            TEXT,
    flight_no               TEXT,
    origin_iata             TEXT,
    destination_iata        TEXT,
    etd_utc                 TIMESTAMPTZ,
    atd_utc                 TIMESTAMPTZ,
    fuel_onboard_departure  NUMERIC,
    fuel_uplift_departure   NUMERIC,
    density                 NUMERIC,
    minimum_fuel            NUMERIC,
    remaining_fuel          NUMERIC,
    is_plausible            BOOLEAN       -- set by loader: filters 908000-kg style outliers
);
CREATE INDEX ix_hist_fuel_route ON hist.fuel (origin_iata, destination_iata);
