-- 020: flight plan and load sheet for the return leg (usability review, "stretch" item).
-- After a diversion the aircraft can only go back to the hub when its paperwork is ready: a flight plan filed by Dispatch and a load sheet
-- made ready by the station (load control). Each is recorded with who and when. "Ready to depart" now REQUIRES both, enforced here in
-- the database (trigger check_ready_paperwork), so no screen or API call can mark an aircraft ready without them.
-- OCC can ask for either one like any other missing fact: data requests accept FLIGHT_PLAN (to Dispatch) and LOAD_SHEET (to the station).
SET search_path = fogops, public;

ALTER TABLE diversion ADD COLUMN IF NOT EXISTS flight_plan_filed_at TIMESTAMPTZ;
ALTER TABLE diversion ADD COLUMN IF NOT EXISTS flight_plan_filed_by INT REFERENCES app_user;
ALTER TABLE diversion ADD COLUMN IF NOT EXISTS load_sheet_ready_at  TIMESTAMPTZ;
ALTER TABLE diversion ADD COLUMN IF NOT EXISTS load_sheet_ready_by  INT REFERENCES app_user;

CREATE OR REPLACE FUNCTION trg_check_ready_paperwork() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'READY' AND (NEW.flight_plan_filed_at IS NULL OR NEW.load_sheet_ready_at IS NULL) THEN
        RAISE EXCEPTION 'Ready to depart needs the flight plan filed (Dispatch) and the load sheet ready (Station). Missing: %',
            concat_ws(' and ', CASE WHEN NEW.flight_plan_filed_at IS NULL THEN 'flight plan' END, CASE WHEN NEW.load_sheet_ready_at IS NULL THEN 'load sheet' END);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS check_ready_paperwork ON diversion;
CREATE TRIGGER check_ready_paperwork BEFORE INSERT OR UPDATE ON diversion FOR EACH ROW EXECUTE FUNCTION trg_check_ready_paperwork();

ALTER TABLE data_request DROP CONSTRAINT IF EXISTS data_request_field_check;
ALTER TABLE data_request ADD CONSTRAINT data_request_field_check
    CHECK (field IN ('FUEL_ENDURANCE', 'ALTERNATE_STATUS', 'ALTERNATE_STANDS', 'CREW_SIGN_IN', 'CREW_QUALIFICATION', 'ETA', 'FLIGHT_PLAN', 'LOAD_SHEET', 'OTHER'));

-- aircraft that were already marked READY before this rule existed keep their state but get no paperwork credit: show them as missing
-- (the rule applies to the next change), so nobody believes a plan exists that nobody filed.

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
