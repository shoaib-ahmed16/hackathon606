-- Repairs fogops.pax_connection IN PLACE (no Excel needed, nothing else is touched).
--
-- Why: the Excel lists every connection twice (is_in_bound TRUE and FALSE, flight blocks swapped). The old loader
-- ignored that and stored about half the rows reversed (the "inbound" column held a flight departing the hub).
-- This swaps the reversed rows, counts each connection once (larger figure if the two listings differ) and drops
-- impossible connections (outbound leaves before the inbound lands).
--
-- Expected result with the supplied data: 9626 pairs / 60147 pax  ->  5044 pairs / 31454 pax, 0 reversed.
--
-- Run (a copy of the old table is kept as pax_connection_backup so this can be undone):
--   docker compose exec -T db psql -U postgres -d fogops -v ON_ERROR_STOP=1 < backend/scripts/fix_pax_connection.sql
-- Undo:   DELETE FROM fogops.pax_connection;  INSERT INTO fogops.pax_connection SELECT * FROM fogops.pax_connection_backup;
-- Clean up when happy:   DROP TABLE fogops.pax_connection_backup;
BEGIN;
SET search_path = fogops, public;

CREATE TABLE IF NOT EXISTS pax_connection_backup AS TABLE pax_connection;

CREATE TEMP TABLE fixed AS
SELECT i AS inbound_flight_id, o AS outbound_flight_id, max(pax_count) AS pax_count
  FROM (SELECT CASE WHEN fi.dep_iata = 'SHJ' THEN p.outbound_flight_id ELSE p.inbound_flight_id END AS i,
               CASE WHEN fi.dep_iata = 'SHJ' THEN p.inbound_flight_id ELSE p.outbound_flight_id END AS o,
               p.pax_count
          FROM pax_connection p JOIN flight fi ON fi.flight_id = p.inbound_flight_id) s
 GROUP BY 1, 2;

DELETE FROM pax_connection;
INSERT INTO pax_connection (inbound_flight_id, outbound_flight_id, pax_count)
SELECT f.inbound_flight_id, f.outbound_flight_id, f.pax_count
  FROM fixed f
  JOIN flight a ON a.flight_id = f.inbound_flight_id
  JOIN flight b ON b.flight_id = f.outbound_flight_id
 WHERE b.std_utc >= a.sta_utc;

SELECT 'pax_connection now: ' || count(*) || ' pairs, ' || sum(pax_count) || ' pax' AS result FROM pax_connection;
SELECT 'reversed pairs left: ' || count(*) FILTER (WHERE fi.dep_iata = 'SHJ') AS check
  FROM pax_connection p JOIN flight fi ON fi.flight_id = p.inbound_flight_id;
COMMIT;
