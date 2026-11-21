-- 006: custom rules. Remember which flights each ALERT rule has already matched so an alert fires when a rule STARTS
-- matching a flight (not on every evaluation), and fires again if the flight stops matching and later matches again.
CREATE TABLE IF NOT EXISTS ops_rule_match (
    rule_id          INT    NOT NULL REFERENCES ops_rule ON DELETE CASCADE,
    scenario_id      INT    NOT NULL REFERENCES scenario,
    flight_id        BIGINT NOT NULL REFERENCES flight,
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    first_matched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_matched_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_id, scenario_id, flight_id)
);
CREATE INDEX IF NOT EXISTS ix_ops_rule_match_active ON ops_rule_match (scenario_id, rule_id) WHERE active;

-- who created, approved, retired a rule: same audit trail as every other operational table
DROP TRIGGER IF EXISTS audit_ops_rule ON ops_rule;
CREATE TRIGGER audit_ops_rule AFTER INSERT OR UPDATE OR DELETE ON ops_rule
    FOR EACH ROW EXECUTE FUNCTION trg_audit('rule_id');
