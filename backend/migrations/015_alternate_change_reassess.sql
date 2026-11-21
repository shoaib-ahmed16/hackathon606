-- 015: changing the list of alternates re-ranks the open cases (alternates manager screen).
-- Adding an alternate, editing its road time / stands / fuel / handling, or switching it off changes what the engine can offer.
-- Same mechanism as an airport status change: queue one reassessment per scenario that has an open case at this hub; the worker then
-- recomputes legality and recommendations for the watched flights.
SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION trg_reassess_alternate() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE s RECORD;
BEGIN
    FOR s IN SELECT DISTINCT scenario_id FROM disruption_case WHERE hub_iata = NEW.hub_iata AND phase <> 'CLOSED' LOOP
        PERFORM enqueue_reassessment(s.scenario_id, 'ALTERNATE_CHANGE', 'airport', NEW.alt_iata,
            jsonb_build_object('hub', NEW.hub_iata, 'alt', NEW.alt_iata, 'is_active', NEW.is_active,
                               'road_positioning_min', NEW.road_positioning_min, 'max_parking_stands', NEW.max_parking_stands));
    END LOOP;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS reassess_alternate ON alternate_airport;
CREATE TRIGGER reassess_alternate AFTER INSERT OR UPDATE ON alternate_airport
    FOR EACH ROW EXECUTE FUNCTION trg_reassess_alternate();

ALTER FUNCTION trg_reassess_alternate() SET search_path = fogops, public;
