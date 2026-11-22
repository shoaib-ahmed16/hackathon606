-- 027: fitted fog model, read by SQL (no ML runtime). scripts/train_fog_model.py fits it offline from weather_obs and writes these tables.
--   fog_clear_quantile   : P10/P50/P90 minutes until a fog episode at the hub ends, on a grid of conditions
--                          (visibility, minutes since onset, hour, month, temperature - dew point spread, wind)
--   alt_fog_conditional  : chance an alternate is below minima one hour later, given whether the hub is in fog, by season and hour
-- fog_clear_forecast() / alt_fog_risk() never guess: no fresh observation, not in fog, or no active model run = NULL columns.
-- Quality of everything here is ESTIMATED_MODEL (external data, fitted model); a person's entry always wins in the engine (migration 028).
SET search_path = fogops, hist, public;

CREATE TABLE IF NOT EXISTS fog_model_run (
    run_id        SERIAL PRIMARY KEY,
    trained_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    icao          CHAR(4) NOT NULL,
    train_from    DATE, train_to DATE, test_from DATE, test_to DATE,
    n_episodes_train INT, n_episodes_test INT, n_samples INT,
    params        JSONB NOT NULL DEFAULT '{}',
    metrics       JSONB NOT NULL DEFAULT '{}',
    is_active     BOOLEAN NOT NULL DEFAULT FALSE,
    notes         TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_fog_model_active ON fog_model_run (icao) WHERE is_active;

CREATE TABLE IF NOT EXISTS fog_clear_quantile (
    run_id   INT NOT NULL REFERENCES fog_model_run(run_id) ON DELETE CASCADE,
    vis_m    INT NOT NULL, age_min INT NOT NULL, hour_utc INT NOT NULL, month INT NOT NULL, spread_c INT NOT NULL, wind_kt INT NOT NULL,
    n        INT NOT NULL,                       -- training samples that support this cell (after the neighbour smoothing the trainer reports)
    p10 NUMERIC NOT NULL, p50 NUMERIC NOT NULL, p90 NUMERIC NOT NULL,
    PRIMARY KEY (run_id, vis_m, age_min, hour_utc, month, spread_c, wind_kt)
);

CREATE TABLE IF NOT EXISTS alt_fog_conditional (
    run_id   INT NOT NULL REFERENCES fog_model_run(run_id) ON DELETE CASCADE,
    icao     CHAR(4) NOT NULL, hub_fog BOOLEAN NOT NULL, season INT NOT NULL, hour_utc INT NOT NULL,
    n INT NOT NULL, n_below INT NOT NULL, p_below NUMERIC NOT NULL,     -- p_below is shrunk toward the station's overall rate (beta prior)
    PRIMARY KEY (run_id, icao, hub_fog, season, hour_utc)
);

CREATE OR REPLACE FUNCTION nearest_grid(v NUMERIC, grid NUMERIC[]) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT g FROM unnest(grid) g ORDER BY abs(g - v), g LIMIT 1 $$;

-- current fog state of a station from the stored observations as of p_at (the scenario clock for replays)
CREATE OR REPLACE FUNCTION fog_state(p_icao CHAR(4), p_at TIMESTAMPTZ)
RETURNS TABLE (obs_utc TIMESTAMPTZ, fresh BOOLEAN, vis_m INT, in_fog BOOLEAN, onset_utc TIMESTAMPTZ, age_min INT,
               spread_c NUMERIC, wind_kt NUMERIC)
LANGUAGE plpgsql STABLE SET search_path TO 'fogops', 'public' AS $$
DECLARE
    v_in    INT := coalesce((SELECT value FROM divert_policy WHERE key = 'fog_vis_in_m'), 800)::int;
    v_clear INT := coalesce((SELECT value FROM divert_policy WHERE key = 'fog_vis_clear_m'), 1500)::int;
    v_age   INT := coalesce((SELECT value FROM divert_policy WHERE key = 'weather_max_age_min'), 90)::int;
BEGIN
    RETURN QUERY
    WITH w AS (   -- last 36 h, oldest first; one reading per time (the archive wins over live when both exist)
        SELECT DISTINCT ON (o.obs_utc) o.obs_utc, o.vsby_m, o.temp_c, o.dewp_c, o.wind_kt
          FROM weather_obs o WHERE o.icao = p_icao AND o.obs_utc <= p_at AND o.obs_utc > p_at - interval '36 hours' AND o.vsby_m IS NOT NULL
         ORDER BY o.obs_utc, o.source),
    f AS (
        SELECT w.*, (w.vsby_m >= v_clear) AS clr,
               lag(w.vsby_m >= v_clear) OVER (ORDER BY w.obs_utc) AS prev_clr FROM w),
    e AS (   -- an episode ends at the second consecutive clear report: number the runs
        SELECT f.*, sum(CASE WHEN f.clr AND f.prev_clr THEN 1 ELSE 0 END) OVER (ORDER BY f.obs_utc) AS run FROM f),
    last AS (SELECT * FROM e ORDER BY e.obs_utc DESC LIMIT 1),
    cur AS (SELECT e.* FROM e, last WHERE e.run = last.run AND NOT (e.clr AND e.prev_clr))
    SELECT l.obs_utc, (p_at - l.obs_utc) <= make_interval(mins => v_age), l.vsby_m,
           (NOT (l.clr AND l.prev_clr)) AND EXISTS (SELECT 1 FROM cur c WHERE c.vsby_m < v_in),
           (SELECT min(c.obs_utc) FROM cur c WHERE c.vsby_m < v_in),
           (floor(extract(epoch FROM (l.obs_utc - (SELECT min(c.obs_utc) FROM cur c WHERE c.vsby_m < v_in))) / 60))::int,
           (l.temp_c - l.dewp_c), l.wind_kt
      FROM last l;
END $$;

-- the grid lookup shared by both sources of the hub's fog state (stored METAR, or the user's own status entries)
CREATE OR REPLACE FUNCTION fog_clear_lookup(p_icao CHAR(4), p_vis INT, p_age INT, p_ts TIMESTAMPTZ, p_spread NUMERIC, p_wind NUMERIC)
RETURNS TABLE (p10_min NUMERIC, p50_min NUMERIC, p90_min NUMERIC, n_support INT, run_id INT)
LANGUAGE sql STABLE SET search_path TO 'fogops', 'public' AS $$
    SELECT c.p10, c.p50, c.p90, c.n, c.run_id
      FROM fog_model_run m JOIN fog_clear_quantile c ON c.run_id = m.run_id
     WHERE m.icao = p_icao AND m.is_active
       AND c.vis_m    = nearest_grid(p_vis, ARRAY[50,100,200,300,400,500,600,800,1000,1200,1500])
       AND c.age_min  = nearest_grid(p_age, ARRAY[0,30,60,120,180,300,480])
       AND c.hour_utc = (round(extract(hour FROM p_ts AT TIME ZONE 'UTC') / 3.0)::int * 3) % 24
       AND c.month    = extract(month FROM p_ts AT TIME ZONE 'UTC')::int
       AND c.spread_c = nearest_grid(least(greatest(coalesce(p_spread, 3), 0), 3), ARRAY[0,1,2,3])
       AND c.wind_kt  = nearest_grid(least(greatest(coalesce(p_wind, 0), 0), 8), ARRAY[0,4,8])
$$;

CREATE OR REPLACE FUNCTION fog_clear_forecast(p_icao CHAR(4), p_at TIMESTAMPTZ)
RETURNS TABLE (in_fog BOOLEAN, fresh BOOLEAN, obs_utc TIMESTAMPTZ, vis_m INT, age_min INT,
               p10_min NUMERIC, p50_min NUMERIC, p90_min NUMERIC, n_support INT, run_id INT, quality TEXT, basis TEXT)
LANGUAGE plpgsql STABLE SET search_path TO 'fogops', 'public' AS $$
DECLARE s RECORD; r INT; q RECORD;
BEGIN
    SELECT * INTO s FROM fog_state(p_icao, p_at);
    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::boolean, NULL::boolean, NULL::timestamptz, NULL::int, NULL::int, NULL::numeric, NULL::numeric, NULL::numeric,
                            NULL::int, NULL::int, NULL::text, 'No weather observation stored for this station before the given time'::text;
        RETURN;
    END IF;
    SELECT m.run_id INTO r FROM fog_model_run m WHERE m.icao = p_icao AND m.is_active;
    IF NOT s.in_fog OR NOT s.fresh OR r IS NULL THEN
        RETURN QUERY SELECT s.in_fog, s.fresh, s.obs_utc, s.vis_m, s.age_min, NULL::numeric, NULL::numeric, NULL::numeric, NULL::int, r, NULL::text,
            CASE WHEN NOT s.fresh THEN 'Latest observation is too old to use (never guessed)'
                 WHEN NOT s.in_fog THEN 'Not in fog: nothing to forecast'
                 ELSE 'No active fog model run for this station' END;
        RETURN;
    END IF;
    SELECT * INTO q FROM fog_clear_lookup(p_icao, s.vis_m, s.age_min, s.obs_utc, s.spread_c, s.wind_kt);
    IF NOT FOUND THEN
        RETURN QUERY SELECT s.in_fog, s.fresh, s.obs_utc, s.vis_m, s.age_min, NULL::numeric, NULL::numeric, NULL::numeric, NULL::int, r, NULL::text,
                            'Active model has no cell for these conditions'::text;
        RETURN;
    END IF;
    RETURN QUERY SELECT s.in_fog, s.fresh, s.obs_utc, s.vis_m, s.age_min, q.p10_min, q.p50_min, q.p90_min, q.n_support, q.run_id, 'ESTIMATED_MODEL'::text,
        format('Fitted on METAR history (run %s): visibility %s m, fog for %s min, observed %s UTC', q.run_id, s.vis_m, s.age_min, to_char(s.obs_utc AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI'));
END $$;

-- the same forecast for a SIMULATION: the fog state comes from the user's own status entries at the hub (no real weather involved).
--   in fog   = the latest entry has visibility below fog_vis_clear_m (or no visibility but CLOSED/RESTRICTED) and the unbroken run of such entries
--              contains one below fog_vis_in_m; fog age = scenario clock minus the first such entry; visibility = the latest entry's.
--   unknown stays NULL: no visibility entered = no features = no forecast (the engine then uses the assumed spread). Dew-point spread and wind are not
--   entered in a status, so the neutral values (3 C, calm) are used.
CREATE OR REPLACE FUNCTION fog_clear_forecast_entered(p_scenario_id INT, p_iata CHAR(3), p_at TIMESTAMPTZ)
RETURNS TABLE (in_fog BOOLEAN, fresh BOOLEAN, obs_utc TIMESTAMPTZ, vis_m INT, age_min INT,
               p10_min NUMERIC, p50_min NUMERIC, p90_min NUMERIC, n_support INT, run_id INT, quality TEXT, basis TEXT)
LANGUAGE plpgsql STABLE SET search_path TO 'fogops', 'public' AS $$
DECLARE
    v_in    INT := coalesce((SELECT value FROM divert_policy WHERE key = 'fog_vis_in_m'), 800)::int;
    v_clear INT := coalesce((SELECT value FROM divert_policy WHERE key = 'fog_vis_clear_m'), 1500)::int;
    v_icao  CHAR(4); v_cur RECORD; v_onset TIMESTAMPTZ; v_age INT; q RECORD; r INT;
BEGIN
    SELECT icao INTO v_icao FROM airport WHERE iata = p_iata;
    WITH ev AS (
        SELECT e.effective_from_utc t, e.visibility_m v, e.op_status::text s,
               row_number() OVER (ORDER BY e.effective_from_utc DESC, e.status_event_id DESC) rn,
               (e.visibility_m < v_clear OR (e.visibility_m IS NULL AND e.op_status::text IN ('CLOSED','RESTRICTED'))) AS foggy
          FROM airport_status_event e WHERE e.scenario_id = p_scenario_id AND e.iata = p_iata AND e.effective_from_utc <= p_at),
    run AS (SELECT ev.*, bool_and(ev.foggy) OVER (ORDER BY ev.rn ROWS UNBOUNDED PRECEDING) AS in_run FROM ev)
    SELECT (SELECT t FROM run WHERE rn = 1) AS cur_t, (SELECT v FROM run WHERE rn = 1) AS cur_v, (SELECT foggy FROM run WHERE rn = 1) AS cur_foggy,
           (SELECT min(t) FROM run WHERE in_run AND v < v_in) AS onset
      INTO v_cur FROM (SELECT 1) one;
    IF v_cur.cur_t IS NULL THEN
        RETURN QUERY SELECT NULL::boolean, NULL::boolean, NULL::timestamptz, NULL::int, NULL::int, NULL::numeric, NULL::numeric, NULL::numeric,
                            NULL::int, NULL::int, NULL::text, 'No status entry for this airport yet'::text;
        RETURN;
    END IF;
    IF NOT v_cur.cur_foggy OR v_cur.onset IS NULL THEN
        RETURN QUERY SELECT FALSE, TRUE, v_cur.cur_t, v_cur.cur_v, NULL::int, NULL::numeric, NULL::numeric, NULL::numeric, NULL::int, NULL::int, NULL::text,
                            'The entered statuses do not describe fog (visibility not below the fog threshold)'::text;
        RETURN;
    END IF;
    IF v_cur.cur_v IS NULL THEN
        RETURN QUERY SELECT TRUE, TRUE, v_cur.cur_t, NULL::int, NULL::int, NULL::numeric, NULL::numeric, NULL::numeric, NULL::int, NULL::int, NULL::text,
                            'No visibility entered with the status: the fog model needs one (unknown stays unknown)'::text;
        RETURN;
    END IF;
    v_age := greatest(0, floor(extract(epoch FROM (p_at - v_cur.onset)) / 60))::int;
    SELECT m.run_id INTO r FROM fog_model_run m WHERE m.icao = v_icao AND m.is_active;
    SELECT * INTO q FROM fog_clear_lookup(v_icao, v_cur.cur_v, v_age, p_at, NULL, NULL);
    IF r IS NULL OR NOT FOUND THEN
        RETURN QUERY SELECT TRUE, TRUE, v_cur.cur_t, v_cur.cur_v, v_age, NULL::numeric, NULL::numeric, NULL::numeric, NULL::int, r, NULL::text,
                            CASE WHEN r IS NULL THEN 'No active fog model run for this station' ELSE 'Active model has no cell for these conditions' END;
        RETURN;
    END IF;
    RETURN QUERY SELECT TRUE, TRUE, v_cur.cur_t, v_cur.cur_v, v_age, q.p10_min, q.p50_min, q.p90_min, q.n_support, q.run_id, 'ESTIMATED_MODEL'::text,
        format('Fitted fog model (run %s) applied to YOUR ENTERED status: visibility %s m, fog since %s UTC (%s min); temperature and wind not entered, neutral values used',
               q.run_id, v_cur.cur_v, to_char(v_cur.onset AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI'), v_age);
END $$;

-- the switch (human only); a change re-ranks the scenario's open cases
CREATE OR REPLACE FUNCTION set_scenario_weather(p_scenario_id INT, p_on BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql SET search_path TO 'fogops', 'public' AS $$
DECLARE v_role TEXT;
BEGIN
    SELECT role_code INTO v_role FROM app_user WHERE user_id = actor_user_id();
    IF v_role IS NULL OR v_role = 'AGENT' THEN RAISE EXCEPTION 'Only a signed-in person can change whether real weather is used'; END IF;
    UPDATE scenario SET use_external_weather = p_on WHERE scenario_id = p_scenario_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown scenario %', p_scenario_id; END IF;
    PERFORM enqueue_reassessment(p_scenario_id, 'WEATHER_MODE', 'scenario', p_scenario_id::text, jsonb_build_object('use_external_weather', p_on));
    RETURN jsonb_build_object('scenario_id', p_scenario_id, 'use_external_weather', p_on);
END $$;

-- chance the alternate is below minima one hour from p_at, given the hub state (NULL = no active model or no cell)
CREATE OR REPLACE FUNCTION alt_fog_risk(p_alt_icao CHAR(4), p_hub_in_fog BOOLEAN, p_at TIMESTAMPTZ)
RETURNS TABLE (p_below NUMERIC, n INT, run_id INT, quality TEXT)
LANGUAGE sql STABLE SET search_path TO 'fogops', 'public' AS $$
    SELECT a.p_below, a.n, a.run_id, 'ESTIMATED_MODEL'::text
      FROM alt_fog_conditional a
      JOIN fog_model_run m ON m.run_id = a.run_id AND m.is_active
     WHERE a.icao = p_alt_icao AND a.hub_fog = p_hub_in_fog
       AND a.season = ((extract(month FROM p_at AT TIME ZONE 'UTC')::int % 12) / 3)
       AND a.hour_utc = (round(extract(hour FROM (p_at + interval '1 hour') AT TIME ZONE 'UTC') / 3.0)::int * 3) % 24
       AND a.n >= 10        -- a cell supported by fewer than 10 hours of history is not used (unknown stays NULL)
$$;
