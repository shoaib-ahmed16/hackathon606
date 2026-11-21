-- 019: the airports and alternates a diversion needs, so any database has them (a fresh install, a restored dump, a scratch copy).
--
-- Diversions are ranked from alternate_airport (hub -> alternate, priority, road positioning, handling, fuel) joined to airport
-- (name, ICAO, time zone, coordinates for distance, minimum ground time). Both normally arrive with the baseline dump; this
-- migration makes sure they are there even if the baseline was loaded without them.
--
-- Idempotent and non-destructive: ON CONFLICT DO NOTHING, so a value someone has edited (a stand count, a road time, a flag) is
-- never overwritten. Road times are ASSUMED (see the notes column); stand counts are NOT seeded (nobody supplied them): the engine
-- uses the live status first, then the demonstrated peak from the history (alternate_history_stats).
--
--   hub SHJ (Sharjah)   alternates, in priority order: FJR, RKT, MCT, AAN, DWC, AUH

SET search_path = fogops, hist, public;

INSERT INTO airport (iata, icao, name, country, tz, min_ground_time_min, is_hub, latitude, longitude) VALUES
  ('SHJ', 'OMSJ', 'Sharjah International Airport',         'AE', 'Asia/Dubai',  40, TRUE,  25.328600, 55.517200),
  ('FJR', 'OMFJ', 'Fujairah International Airport',        'AE', 'Asia/Dubai',  40, FALSE, 25.112200, 56.324000),
  ('RKT', 'OMRK', 'Ras Al Khaimah International Airport',  'AE', 'Asia/Dubai',  40, TRUE,  25.613500, 55.938800),
  ('MCT', 'OOMS', 'Muscat International Airport',          'OM', 'Asia/Muscat', 40, FALSE, 23.593300, 58.284400),
  ('AAN', 'OMAL', 'Al Ain International Airport',          'AE', 'Asia/Dubai',  40, FALSE, 24.261700, 55.609200),
  ('DWC', 'OMDW', 'Al Maktoum International Airport',      'AE', 'Asia/Dubai',  40, FALSE, 24.896670, 55.161390),
  ('AUH', 'OMAA', 'Abu Dhabi International Airport',       'AE', 'Asia/Dubai',  45, FALSE, 24.433000, 54.651100)
ON CONFLICT (iata) DO NOTHING;

INSERT INTO alternate_airport (hub_iata, alt_iata, priority, road_positioning_min, max_parking_stands, handling_contract, fuel_available,
                               customs_24h, historical_diversions, hist_median_ground_min, notes, is_active) VALUES
  ('SHJ', 'FJR', 1, 90,   NULL, TRUE, TRUE, TRUE, 33, 139, 'ASSUMED road time SHJ-FJR', TRUE),
  ('SHJ', 'RKT', 2, 60,   NULL, TRUE, TRUE, TRUE, 18, 180, 'ASSUMED road time SHJ-RKT', TRUE),
  ('SHJ', 'MCT', 3, NULL, NULL, TRUE, TRUE, TRUE, 15, 59,  'Not reachable by road in time: deadhead required', TRUE),
  ('SHJ', 'AAN', 4, 120,  NULL, TRUE, TRUE, TRUE, 9,  77,  'ASSUMED road time SHJ-AAN', TRUE),
  ('SHJ', 'DWC', 5, 60,   NULL, TRUE, TRUE, TRUE, 2,  158, 'ASSUMED road time SHJ-DWC', TRUE),
  ('SHJ', 'AUH', 6, 120,  NULL, TRUE, TRUE, TRUE, 2,  97,  'ASSUMED road time SHJ-AUH', TRUE)
ON CONFLICT (hub_iata, alt_iata) DO NOTHING;

-- The pair travel table (016) and the history statistics (015) are built from alternate_airport; refresh the live recommendations.
SELECT enqueue_reassessment(scenario_id, 'migration 019: alternate airports seed', 'airport', 'SHJ') FROM scenario WHERE kind = 'LIVE' AND is_active;
