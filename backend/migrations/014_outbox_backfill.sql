-- 014: queue the aeroMart entry for diversions that were executed before the outbox trigger existed (demo test report H3).
-- The seed's demo replay executes its diversions while the database is built, before this application's migrations (and the
-- trigger trg_integration_outbox from 003) are applied, so the Integrations outbox read "empty" with two executed diversions.
-- Same row the trigger writes, same idempotency key, so running this twice (or after the trigger fired) adds nothing.
SET search_path = fogops, public;

INSERT INTO integration_outbox (system_code, scenario_id, decision_id, flight_id, action, payload, idempotency_key)
SELECT 'AEROMART', d.scenario_id, d.decision_id, d.flight_id, 'CREATE_DIVERSION_ENTRY',
       jsonb_build_object('flight_no', f.flight_no, 'flight_date', f.flight_date, 'dep', f.dep_iata,
                          'planned_arr', f.arr_iata, 'diverted_to', d.alternate_iata,
                          'recovery_flight_id', d.details->>'recovery_flight_id',
                          'decided_by', d.decided_by, 'decision_id', d.decision_id),
       'DIVERT-' || d.decision_id
  FROM decision d JOIN flight f ON f.flight_id = d.flight_id
 WHERE d.decision_type = 'DIVERT' AND d.status = 'EXECUTED'
ON CONFLICT (idempotency_key) DO NOTHING;
