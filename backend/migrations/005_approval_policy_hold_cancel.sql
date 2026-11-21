-- 005: close a governance gap in the seeded approval policy.
-- With no policy rows for a decision type, ANY approver role may approve it, so Dispatch could approve its own HOLD.
-- Product guide section 4.1: Hold and cancellation are approved by OCC (Dispatch proposes). This is a working proposal,
-- configurable here until the client's recorded answer is transcribed (open question 1).
INSERT INTO approval_policy (decision_type, approver_role, required, notify_roles) VALUES
  ('HOLD',   'OCC', TRUE, '{DISPATCH,CREW_CONTROL}'),
  ('CANCEL', 'OCC', TRUE, '{DISPATCH,CREW_CONTROL,STATION}')
ON CONFLICT (decision_type, approver_role) DO NOTHING;
