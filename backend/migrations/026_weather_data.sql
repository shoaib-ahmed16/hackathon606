-- 026: open weather data (METAR / TAF / model forecasts) as EXTERNAL evidence for the hold-vs-divert engine.
-- Nothing here is airline data and nothing here decides: the status of an airport (OPEN / CLOSED, reopening time) stays a human entry in
-- airport_status_event. These tables only feed (a) the offline fog model fitted by scripts/train_fog_model.py and (b) estimates labelled
-- EXTERNAL_OBSERVED / ESTIMATED_MODEL that the engine may use when no person has entered the value.
-- Sources: Iowa Environmental Mesonet METAR archive, aviationweather.gov (live METAR/TAF), Open-Meteo (model forecasts). Only public ICAO
-- station codes are sent to them. Unknown stays NULL.
SET search_path = fogops, hist, public;

CREATE TABLE IF NOT EXISTS weather_station (
    icao        CHAR(4) PRIMARY KEY,
    iata        CHAR(3) NOT NULL REFERENCES airport(iata),
    role        TEXT NOT NULL CHECK (role IN ('HUB', 'ALTERNATE')),
    UNIQUE (iata)
);
INSERT INTO weather_station (icao, iata, role)
SELECT a.icao, a.iata, CASE WHEN a.iata = 'SHJ' THEN 'HUB' ELSE 'ALTERNATE' END
  FROM airport a WHERE a.iata IN ('SHJ','RKT','FJR','AAN','MCT','DWC','AUH') AND a.icao IS NOT NULL
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS weather_obs (
    icao       CHAR(4) NOT NULL,
    obs_utc    TIMESTAMPTZ NOT NULL,
    vsby_m     INT,                      -- prevailing visibility in metres; 9999 = 10 km or more; NULL = not reported
    wind_dir   INT, wind_kt NUMERIC, temp_c NUMERIC, dewp_c NUMERIC, qnh_hpa NUMERIC,
    raw        TEXT,
    source     TEXT NOT NULL,            -- 'IEM' (archive) or 'AWC' (live)
    quality    TEXT NOT NULL DEFAULT 'EXTERNAL_OBSERVED',
    PRIMARY KEY (icao, obs_utc, source)
);
CREATE INDEX IF NOT EXISTS ix_weather_obs_time ON weather_obs (icao, obs_utc DESC);

CREATE TABLE IF NOT EXISTS weather_taf (
    icao        CHAR(4) NOT NULL,
    issued_utc  TIMESTAMPTZ NOT NULL,
    valid_from  TIMESTAMPTZ, valid_to TIMESTAMPTZ,
    min_vsby_m  INT,                     -- lowest visibility in any group of the TAF (NULL when not parseable)
    raw         TEXT,
    source      TEXT NOT NULL DEFAULT 'AWC',
    quality     TEXT NOT NULL DEFAULT 'EXTERNAL_FORECAST',
    PRIMARY KEY (icao, issued_utc, source)
);

CREATE TABLE IF NOT EXISTS weather_fcst (
    icao        CHAR(4) NOT NULL,
    valid_utc   TIMESTAMPTZ NOT NULL,
    visibility_m NUMERIC, rh_pct NUMERIC, temp_c NUMERIC, dewp_c NUMERIC, wind_kt NUMERIC,
    source      TEXT NOT NULL DEFAULT 'OPEN_METEO',
    quality     TEXT NOT NULL DEFAULT 'EXTERNAL_FORECAST',
    PRIMARY KEY (icao, valid_utc, source)
);

-- how fresh an observation must be for the engine to use it, and the visibility thresholds (metres). ASSUMED until checked against the
-- flight-history disruption episodes (scripts/train_fog_model.py reports the comparison).
INSERT INTO divert_policy (key, value, unit, basis) VALUES
 ('weather_max_age_min',   90,   'min', 'ASSUMED: METAR older than this is ignored by the engine (stale, never guessed)'),
 ('fog_vis_in_m',          800,  'm',   'ASSUMED: visibility below this counts as fog at the hub (start of an episode)'),
 ('fog_vis_clear_m',       1500, 'm',   'ASSUMED: visibility at or above this for 2 consecutive reports ends the episode'),
 ('alt_minima_vis_m',      800,  'm',   'ASSUMED: alternate visibility below this counts as below minima')
ON CONFLICT (key) DO NOTHING;

-- Per-scenario switch: may the engine use the stored real weather for this scenario?
--   ON  (LIVE default): METAR at the scenario clock feeds the fog model and the alternate weather checks (always labelled EXTERNAL / ESTIMATED).
--   OFF (REPLAY / what-if default): only what the user enters counts; the fog model then runs on the visibility and time of the user's own status
--       entries, and a real METAR can neither block nor fill in an alternate. A person's entries win in both modes.
-- Without this a simulation dated in the past would silently pick up whatever real weather was recorded at that time.
ALTER TABLE scenario ADD COLUMN IF NOT EXISTS use_external_weather BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE scenario SET use_external_weather = TRUE WHERE kind = 'LIVE';
