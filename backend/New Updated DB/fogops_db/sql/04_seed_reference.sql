SET search_path = fogops, public;

-- requires_lvp: both operating pilots must be LVP-qualified to land where LVP is in force (organizer decision)
INSERT INTO crew_type (code, description, category, gates_flight_legality, requires_lvp) VALUES
 ('CP',  'Captain',                 'COCKPIT', TRUE,  TRUE),
 ('FO',  'First Officer',           'COCKPIT', TRUE,  TRUE),
 ('SO',  'Second Officer',          'COCKPIT', TRUE,  FALSE),  -- not in Crew_FDTL.xlsx => verification required
 ('CS',  'Cabin Supervisor',        'CABIN',   TRUE,  FALSE),
 ('CC',  'Cabin Crew',              'CABIN',   TRUE,  FALSE),
 ('SEC', 'Security officer',        'OTHER',   FALSE, FALSE),  -- not in Crew_FDTL.xlsx
 ('EN',  'Engineer on board',       'OTHER',   FALSE, FALSE);  -- not in Crew_FDTL.xlsx

INSERT INTO app_role (code, description, is_human, can_approve) VALUES
 ('OCC',          'Operations Control Centre duty manager', TRUE,  TRUE),
 ('DISPATCH',     'Flight Dispatch',                        TRUE,  TRUE),
 ('CREW_CONTROL', 'Crew Control',                           TRUE,  TRUE),
 ('STATION',      'Station / ground handling',              TRUE,  FALSE),
 ('RECOVERY',     'Recovery coordinator',                   TRUE,  TRUE),
 ('ADMIN',        'System administrator',                   TRUE,  FALSE),
 ('AGENT',        'Decision-support agent (non-human)',     FALSE, FALSE);

-- Demo users (replace with your identity provider mapping)
INSERT INTO app_user (username, display_name, role_code) VALUES
 ('occ.dm',     'OCC Duty Manager',   'OCC'),
 ('dispatch.1', 'Dispatcher 1',       'DISPATCH'),
 ('crew.ctl.1', 'Crew Controller 1',  'CREW_CONTROL'),
 ('recovery.1', 'Recovery Coord 1',   'RECOVERY'),
 ('agent',      'FogOps Agent',       'AGENT'),
 ('admin',      'Admin',              'ADMIN');

INSERT INTO feed_source (source_code, description, stale_after_sec) VALUES
 ('OCC_ROTATION', 'OCC flight rotation snapshots (xls exports)', 900),
 ('SIM_FEED',     'Organizer simulated live flight feed',          300),
 ('MANUAL',       'Manual entries / decision side effects',        86400);

INSERT INTO scenario (name, kind, description)
VALUES ('LIVE', 'LIVE', 'Operational picture loaded from the provided files');
