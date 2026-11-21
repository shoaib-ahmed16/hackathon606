-- 008: a message or update from a station reaches OCC by role, not only through "Watch flight".
--  * a comment written by the STATION role  -> OCC gets an in-app notification (bell)
--  * a station update at an alternate (status, waiting for, refuel, handling, passengers) -> OCC gets a notification
-- Same mechanism as the other role alerts (notify_roles): never to the person who acted, one per recipient per event.
CREATE OR REPLACE FUNCTION trg_role_notify_comment() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_no TEXT; v_scn INT;
BEGIN
    IF NEW.flight_id IS NULL OR coalesce(NEW.author_role, '') <> 'STATION' THEN RETURN NULL; END IF;
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = NEW.flight_id;
    SELECT scenario_id INTO v_scn FROM disruption_case WHERE case_id = NEW.case_id;
    PERFORM notify_roles(v_scn, NEW.flight_id, NEW.case_id, ARRAY['OCC'], format('%s: message from a station', v_no), NEW.body, 'WARN', 'case_comment', NEW.comment_id::text);
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_role_notify_comment ON case_comment;
CREATE TRIGGER zz_role_notify_comment AFTER INSERT ON case_comment
    FOR EACH ROW EXECUTE FUNCTION trg_role_notify_comment();

CREATE OR REPLACE FUNCTION trg_role_notify_diversion() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_no TEXT; v_what TEXT;
BEGIN
    IF actor_role() IS DISTINCT FROM 'STATION' THEN RETURN NULL; END IF;
    IF (NEW.status, NEW.waiting_for, NEW.refuel_status, NEW.handling_status, NEW.pax_onboard)
       IS NOT DISTINCT FROM (OLD.status, OLD.waiting_for, OLD.refuel_status, OLD.handling_status, OLD.pax_onboard) THEN RETURN NULL; END IF;
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = NEW.original_flight_id;
    v_what := concat_ws(', ',
        CASE WHEN NEW.status IS DISTINCT FROM OLD.status THEN 'status ' || lower(replace(NEW.status::text, '_', ' ')) END,
        CASE WHEN NEW.waiting_for IS DISTINCT FROM OLD.waiting_for THEN 'waiting for ' || lower(replace(NEW.waiting_for::text, '_', ' ')) END,
        CASE WHEN NEW.refuel_status IS DISTINCT FROM OLD.refuel_status THEN 'refuel ' || lower(replace(NEW.refuel_status::text, '_', ' ')) END,
        CASE WHEN NEW.handling_status IS DISTINCT FROM OLD.handling_status THEN 'handling ' || lower(replace(NEW.handling_status::text, '_', ' ')) END,
        CASE WHEN NEW.pax_onboard IS DISTINCT FROM OLD.pax_onboard THEN CASE WHEN NEW.pax_onboard THEN 'passengers on board' ELSE 'passengers off' END END);
    PERFORM notify_roles(NEW.scenario_id, NEW.original_flight_id, NEW.case_id, ARRAY['OCC'], format('%s at %s: %s', v_no, NEW.alternate_iata, v_what), 'Station update', 'INFO', 'diversion', NEW.diversion_id::text);
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_role_notify_diversion ON diversion;
CREATE TRIGGER zz_role_notify_diversion AFTER UPDATE ON diversion
    FOR EACH ROW EXECUTE FUNCTION trg_role_notify_diversion();

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
