-- 031: closure sets = reusable templates of station closures for simulations.
-- A set only describes "which stations are OPEN / RESTRICTED / CLOSED and for how long". Applying a set to a simulation scenario writes
-- ordinary airport_status_event rows (quality SIMULATED), so the engine, views and worker are unchanged. Sets are never applied to the
-- LIVE scenario (enforced in the API): closures there stay a person's real input.
SET search_path = fogops, hist, public;

CREATE TABLE IF NOT EXISTS closure_set (
    set_id       SERIAL PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    description  TEXT,
    created_by   INT REFERENCES app_user,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS closure_set_item (
    set_id            INT NOT NULL REFERENCES closure_set ON DELETE CASCADE,
    iata              CHAR(3) NOT NULL REFERENCES airport,
    op_status         airport_op_status NOT NULL,
    reopen_after_min  INT CHECK (reopen_after_min >= 0),   -- minutes after the scenario clock; NULL = no forecast
    parking_available INT CHECK (parking_available >= 0),  -- stands free; NULL = unknown
    reason            TEXT,
    PRIMARY KEY (set_id, iata)
);

CREATE TABLE IF NOT EXISTS closure_set_application (
    application_id  BIGSERIAL PRIMARY KEY,
    set_id          INT NOT NULL REFERENCES closure_set,   -- RESTRICT: a set that was applied cannot be deleted
    scenario_id     INT NOT NULL REFERENCES scenario,
    applied_by      INT REFERENCES app_user,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    items_written   INT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_closure_app_scenario ON closure_set_application (scenario_id, applied_at DESC);
