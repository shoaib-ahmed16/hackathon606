-- 003: airport stand and arrival-slot capacity (WP-4).
--
-- Three independent dimensions, each with its source stated:
--   1. stands (parking)            : latest airport_status_event.parking_available  >  airport_capacity (assumed)  >  history  >  unknown
--   2. arrivals handled per hour   : latest airport_status_event.arrival_capacity_per_hr  >  airport_capacity  >  history  >  unknown
--   3. occupancy now / at an ETA   : derived from Air Arabia movements (flight, flight_state, diversion). It is NOT verified
--                                    real-time occupancy: other operators' aircraft and aircraft parked before the data starts are unknown.
--
-- HONESTY RULES
--   * No capacity numbers are seeded: nobody supplied real capacities. airport_capacity starts empty and is filled by OCC/ADMIN.
--   * A historical peak is a LOWER BOUND of what an airport has handled. It is never presented as a limit.
--   * Unknown stays NULL (never 0). Quality labels: MANUAL / stored status quality, ASSUMED, ESTIMATED_FROM_HISTORY, NULL.
--   * Nothing here changes rank_alternates (WP-7 wires alt_stand_capacity into it) and nothing writes to flight data.

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. Configured assumptions (a person says "assume x stands / y arrivals per hour here")
-- ---------------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fogops.airport_capacity (
    iata                     CHAR(3) PRIMARY KEY REFERENCES fogops.airport,
    stands_assumed           INT CHECK (stands_assumed >= 0),
    arrivals_per_hr_assumed  INT CHECK (arrivals_per_hr_assumed >= 0),
    basis                    TEXT NOT NULL,                      -- who or what says so
    updated_by               INT REFERENCES fogops.app_user,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS audit_airport_capacity ON fogops.airport_capacity;
CREATE TRIGGER audit_airport_capacity AFTER INSERT OR UPDATE OR DELETE ON fogops.airport_capacity
    FOR EACH ROW EXECUTE FUNCTION fogops.trg_audit('iata');

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. Policy keys (same table as the diversion policy; basis starts with ASSUMED where it is our choice)
-- ---------------------------------------------------------------------------------------------------------------------
INSERT INTO fogops.divert_policy (key, value, unit, basis) VALUES
    ('min_capacity_sample_hours', 100, 'hours',
     'ASSUMED: hours with at least one recorded arrival (hist.flight, actual ATA) needed before a history estimate may stand in for a missing capacity. Today RKT (817) and MCT (512) pass; FJR (11), AUH (8), AAN (4), DWC (1) do not, and nothing lies between 12 and 511, so any value in that range gives the same result.'),
    ('history_max_stay_hours', 48, 'hours',
     'ASSUMED: a stay longer than this between an arrival and the same aircraft''s next departure is treated as parked or in maintenance and is left out of ground-occupancy figures (no aircraft is assumed to stay indefinitely).'),
    ('capacity_constrained_margin', 1, 'slots',
     'ASSUMED: after adding the proposed flight(s), a remaining stand or arrival slot count at or below this is CAPACITY_CONSTRAINED; below zero is CAPACITY_EXCEEDED.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. History estimate from hist.flight (ACTUALS ONLY: rows with an actual arrival time ata_utc; scheduled future rows are ignored)
--
--    sample_n              = number of distinct clock hours (UTC) with at least one arrival  (hours WITH traffic, not hours observed)
--    peak_arrivals_per_hr  = the most arrivals in any one clock hour
--    avg_arrivals_per_active_hr = arrivals / sample_n   (over hours with traffic only, so it overstates the true hourly rate)
--    peak_ground / avg_ground   = aircraft on the ground at once: each arrival is paired with the SAME registration's next
--                            departure FROM THIS AIRPORT (atd, else std). Unpaired arrivals (broken rotation, no registration) and
--                            stays longer than history_max_stay_hours are left out. Sweep line over +1 (arrival) / -1 (departure).
--
--    Reproduce by hand:  SELECT * FROM fogops.airport_history_capacity('RKT');
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fogops.airport_history_capacity(p_iata CHAR(3))
RETURNS TABLE (sample_n INT, arrivals_total INT, avg_arrivals_per_active_hr NUMERIC, peak_arrivals_per_hr INT,
               peak_ground INT, avg_ground NUMERIC, paired_stays INT,
               first_arrival_utc TIMESTAMPTZ, last_arrival_utc TIMESTAMPTZ, basis TEXT)
LANGUAGE sql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
WITH cap AS (
    SELECT make_interval(hours => coalesce((SELECT value FROM divert_policy WHERE key = 'history_max_stay_hours'), 48)::int) AS max_stay,
           (SELECT max(ata_utc) FROM hist.flight) AS data_end
), arr AS (
    SELECT registration, ata_utc, date_trunc('hour', ata_utc AT TIME ZONE 'UTC') AS hr
      FROM hist.flight WHERE arr_iata = p_iata AND ata_utc IS NOT NULL
), per_hr AS (
    SELECT hr, count(*) AS c FROM arr GROUP BY hr
), regs AS (
    SELECT DISTINCT registration FROM arr WHERE registration IS NOT NULL
), mv AS (
    SELECT f.arr_iata, f.ata_utc,
           lead(f.dep_iata) OVER w AS nd, lead(coalesce(f.atd_utc, f.std_utc)) OVER w AS nd_t
      FROM hist.flight f JOIN regs r ON r.registration = f.registration, cap
     WHERE coalesce(f.atd_utc, f.std_utc) IS NOT NULL AND coalesce(f.atd_utc, f.std_utc) <= cap.data_end
    WINDOW w AS (PARTITION BY f.registration ORDER BY coalesce(f.atd_utc, f.std_utc), f.hist_id)
), stay AS (
    SELECT mv.ata_utc AS a, mv.nd_t AS d FROM mv, cap
     WHERE mv.arr_iata = p_iata AND mv.ata_utc IS NOT NULL AND mv.nd = p_iata
       AND mv.nd_t > mv.ata_utc AND mv.nd_t - mv.ata_utc <= cap.max_stay
), ev AS (
    SELECT a AS t, 1 AS x FROM stay UNION ALL SELECT d, -1 FROM stay
), run AS (
    SELECT sum(x) OVER (ORDER BY t, x ROWS UNBOUNDED PRECEDING) AS occ FROM ev
), g AS (
    SELECT (SELECT max(occ) FROM run) AS peak_ground,
           (SELECT count(*) FROM stay) AS n_stay,
           (SELECT extract(epoch FROM sum(d - a)) FROM stay) AS stay_sec,
           (SELECT min(ata_utc) FROM arr) AS t0, (SELECT max(ata_utc) FROM arr) AS t1
)
SELECT (SELECT count(*) FROM per_hr)::int,
       (SELECT count(*) FROM arr)::int,
       (SELECT round(sum(c)::numeric / nullif(count(*), 0), 2) FROM per_hr),
       (SELECT max(c) FROM per_hr)::int,
       g.peak_ground::int,
       CASE WHEN g.t1 - g.t0 >= interval '7 days' AND g.stay_sec IS NOT NULL THEN round((g.stay_sec / extract(epoch FROM g.t1 - g.t0))::numeric, 2) END,
       g.n_stay::int, g.t0, g.t1,
       format('hist.flight actual arrivals (ATA) %s to %s. A historical peak is a LOWER BOUND of what this airport handled, not its limit. '
              'Hours counted are hours with traffic. Ground occupancy pairs each arrival with the same aircraft''s next departure from here (%s of %s arrivals paired).',
              coalesce(to_char(g.t0 AT TIME ZONE 'UTC', 'YYYY-MM-DD'), 'n/a'), coalesce(to_char(g.t1 AT TIME ZONE 'UTC', 'YYYY-MM-DD'), 'n/a'),
              g.n_stay, (SELECT count(*) FROM arr))
  FROM g
$$;

-- Hour-of-day (UTC) and per-month profile for the charts: where the arrivals fall, and how busy the busiest hour was.
CREATE OR REPLACE FUNCTION fogops.airport_history_profile(p_iata CHAR(3)) RETURNS JSONB
LANGUAGE sql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
WITH arr AS (
    SELECT ata_utc AT TIME ZONE 'UTC' AS t FROM hist.flight WHERE arr_iata = p_iata AND ata_utc IS NOT NULL
), per_hr AS (
    SELECT date_trunc('hour', t) AS hr, count(*) AS c FROM arr GROUP BY 1
)
SELECT jsonb_build_object(
    'by_hour_utc', (SELECT coalesce(jsonb_agg(jsonb_build_object('hour', h, 'arrivals', coalesce(x.n, 0), 'peak_per_hr', coalesce(x.pk, 0)) ORDER BY h), '[]'::jsonb)
                      FROM generate_series(0, 23) h
                      LEFT JOIN (SELECT extract(hour FROM hr)::int AS hh, sum(c) AS n, max(c) AS pk FROM per_hr GROUP BY 1) x ON x.hh = h),
    'by_month',    (SELECT coalesce(jsonb_agg(jsonb_build_object('month', to_char(m, 'YYYY-MM'), 'arrivals', n, 'active_hours', ah, 'peak_per_hr', pk) ORDER BY m), '[]'::jsonb)
                      FROM (SELECT date_trunc('month', hr) AS m, sum(c) AS n, count(*) AS ah, max(c) AS pk FROM per_hr GROUP BY 1) q));
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. Effective capacity with the source of every number.
--    Precedence, per dimension:  status entry  >  configured assumption  >  history (only with enough hours)  >  unknown
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fogops.airport_capacity_resolve(p_scenario_id INT, p_iata CHAR(3), p_at TIMESTAMPTZ)
RETURNS TABLE (stands_total INT, stands_source TEXT, stands_quality TEXT, stands_basis TEXT, stands_as_of TIMESTAMPTZ,
               arrivals_per_hr INT, arrivals_source TEXT, arrivals_quality TEXT, arrivals_basis TEXT, arrivals_as_of TIMESTAMPTZ,
               sample_n INT, hist_peak_arrivals INT, hist_peak_ground INT, min_sample_hours INT,
               status_event_id BIGINT, status_effective_from TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
DECLARE
    ev  airport_status_event%ROWTYPE;
    cfg airport_capacity%ROWTYPE;
    h   RECORD;
    v_min INT := coalesce((SELECT value FROM divert_policy WHERE key = 'min_capacity_sample_hours'), 100)::int;
    v_ok  BOOLEAN;
    r_st INT; r_st_src TEXT; r_st_q TEXT; r_st_b TEXT; r_st_t TIMESTAMPTZ;
    r_ar INT; r_ar_src TEXT; r_ar_q TEXT; r_ar_b TEXT; r_ar_t TIMESTAMPTZ;
BEGIN
    SELECT * INTO ev FROM airport_status_event x
     WHERE x.scenario_id = p_scenario_id AND x.iata = p_iata AND x.effective_from_utc <= p_at
     ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1;
    SELECT * INTO cfg FROM airport_capacity c WHERE c.iata = p_iata;
    SELECT * INTO h FROM airport_history_capacity(p_iata);
    v_ok := coalesce(h.sample_n, 0) >= v_min;

    IF ev.parking_available IS NOT NULL THEN
        r_st := ev.parking_available; r_st_src := 'STATUS_EVENT'; r_st_q := ev.quality::text; r_st_t := ev.effective_from_utc;
        r_st_b := format('Latest airport status entry (effective %s UTC): %s stand(s) FREE at that time, as entered by a person', to_char(ev.effective_from_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), ev.parking_available);
    ELSIF cfg.stands_assumed IS NOT NULL THEN
        r_st := cfg.stands_assumed; r_st_src := 'CONFIGURED'; r_st_q := 'ASSUMED'; r_st_b := cfg.basis; r_st_t := cfg.updated_at;
    ELSIF v_ok AND h.peak_ground IS NOT NULL THEN
        r_st := h.peak_ground; r_st_src := 'HISTORY'; r_st_q := 'ESTIMATED_FROM_HISTORY'; r_st_t := h.last_arrival_utc;
        r_st_b := format('Peak %s aircraft on the ground at once over %s hours of history: a LOWER BOUND of what the airport handled, not its limit', h.peak_ground, h.sample_n);
    ELSE
        r_st_src := 'UNKNOWN';
        r_st_b := format('Unknown: no status entry, no configured assumption, history sample %s of %s hours needed', coalesce(h.sample_n, 0), v_min);
    END IF;

    IF ev.arrival_capacity_per_hr IS NOT NULL THEN
        r_ar := ev.arrival_capacity_per_hr; r_ar_src := 'STATUS_EVENT'; r_ar_q := ev.quality::text; r_ar_t := ev.effective_from_utc;
        r_ar_b := format('Latest airport status entry (effective %s UTC): %s arrivals per hour', to_char(ev.effective_from_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), ev.arrival_capacity_per_hr);
    ELSIF cfg.arrivals_per_hr_assumed IS NOT NULL THEN
        r_ar := cfg.arrivals_per_hr_assumed; r_ar_src := 'CONFIGURED'; r_ar_q := 'ASSUMED'; r_ar_b := cfg.basis; r_ar_t := cfg.updated_at;
    ELSIF v_ok AND h.peak_arrivals_per_hr IS NOT NULL THEN
        r_ar := h.peak_arrivals_per_hr; r_ar_src := 'HISTORY'; r_ar_q := 'ESTIMATED_FROM_HISTORY'; r_ar_t := h.last_arrival_utc;
        r_ar_b := format('Peak %s arrivals in one hour over %s hours of history: a LOWER BOUND of what the airport handled, not its limit', h.peak_arrivals_per_hr, h.sample_n);
    ELSE
        r_ar_src := 'UNKNOWN';
        r_ar_b := format('Unknown: no status entry, no configured assumption, history sample %s of %s hours needed', coalesce(h.sample_n, 0), v_min);
    END IF;

    RETURN QUERY SELECT r_st, r_st_src, r_st_q, r_st_b, r_st_t, r_ar, r_ar_src, r_ar_q, r_ar_b, r_ar_t,
                        coalesce(h.sample_n, 0), h.peak_arrivals_per_hr, h.peak_ground, v_min, ev.status_event_id, ev.effective_from_utc;
END $$;

-- The FIXED helper contract (README): one row, never raises. WP-7 will call this from the engine.
CREATE OR REPLACE FUNCTION fogops.alt_stand_capacity(p_scenario_id INT, p_iata CHAR(3), p_at TIMESTAMPTZ)
RETURNS TABLE (stands_total INT, arrivals_per_hr INT, quality TEXT, basis TEXT, sample_n INT)
LANGUAGE sql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
SELECT r.stands_total, r.arrivals_per_hr,
       CASE WHEN r.stands_total IS NOT NULL THEN r.stands_quality ELSE r.arrivals_quality END,
       CASE WHEN r.stands_total IS NOT NULL AND r.arrivals_per_hr IS NOT NULL AND r.stands_source <> r.arrivals_source
                 THEN 'Stands: ' || r.stands_basis || ' | Arrivals per hour: ' || r.arrivals_basis
            WHEN r.stands_total IS NOT NULL THEN r.stands_basis
            ELSE r.arrivals_basis END,
       r.sample_n
  FROM airport_capacity_resolve(p_scenario_id, p_iata, p_at) r
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. Aircraft stays at an airport, derived from Air Arabia movements in one scenario.
--    One row per flight (keyed by flight_id), so a diverted flight that appears in BOTH flight_state.actual_arr_iata and
--    diversion is counted once. Cancelled flights, and flights diverted AWAY from the airport, are excluded.
--    ta = arrival: diversion.landed_alt_utc, else actual ATA, else updated ETA, else STA (ta_actual says which).
--    td = departure: diversion actual/planned departure, else the same registration's next departure from here
--         (actual, else updated ETD, else STD). NULL td = no onward movement known.
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fogops.airport_stays(p_scenario_id INT, p_iata CHAR(3), p_exclude_flight BIGINT DEFAULT NULL)
RETURNS TABLE (flight_id BIGINT, flight_no TEXT, registration TEXT, ta TIMESTAMPTZ, ta_actual BOOLEAN,
               td TIMESTAMPTZ, td_actual BOOLEAN, diverted BOOLEAN)
LANGUAGE sql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
WITH arr AS (
    SELECT f.flight_id, f.flight_no, coalesce(fs.registration, f.registration_planned) AS reg,
           coalesce(d.landed_alt_utc, fs.ata_utc, fs.eta_utc, f.sta_utc) AS ta,
           (d.landed_alt_utc IS NOT NULL OR fs.ata_utc IS NOT NULL) AS ta_actual,
           (d.diversion_id IS NOT NULL OR coalesce(fs.actual_arr_iata, f.arr_iata) <> f.arr_iata) AS diverted,
           d.actual_departure_utc AS d_act, d.planned_departure_utc AS d_plan
      FROM flight f
      LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = p_scenario_id
      LEFT JOIN diversion d ON d.original_flight_id = f.flight_id AND d.scenario_id = p_scenario_id
                           AND d.alternate_iata = p_iata AND d.status <> 'CANCELLED'
     WHERE (coalesce(fs.actual_arr_iata, f.arr_iata) = p_iata OR d.diversion_id IS NOT NULL)
       AND NOT coalesce(fs.is_cancelled, FALSE)
       AND f.flight_id IS DISTINCT FROM p_exclude_flight
), dep AS (
    SELECT f.flight_id AS dep_flight, coalesce(fs.registration, f.registration_planned) AS reg,
           coalesce(fs.atd_utc, fs.etd_utc, f.std_utc) AS td, (fs.atd_utc IS NOT NULL) AS td_actual
      FROM flight f LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = p_scenario_id
     WHERE f.dep_iata = p_iata AND NOT coalesce(fs.is_cancelled, FALSE)
)
SELECT x.flight_id, x.flight_no, x.reg, x.ta, x.ta_actual,
       -- only an ACTUAL departure, or a planned/estimated one that is still in the future, closes a stay; a planned departure
       -- that has already passed without an actual one means the aircraft is late, so no departure is known
       CASE WHEN x.td_actual OR x.td > scenario_now(p_scenario_id) THEN x.td END,
       CASE WHEN x.td_actual OR x.td > scenario_now(p_scenario_id) THEN x.td_actual ELSE FALSE END,
       x.diverted
  FROM (
    SELECT a.flight_id, a.flight_no, a.reg, a.ta, a.ta_actual, a.diverted,
           CASE WHEN a.d_act IS NOT NULL THEN a.d_act WHEN a.d_plan IS NOT NULL THEN a.d_plan ELSE nd.td END AS td,
           CASE WHEN a.d_act IS NOT NULL THEN TRUE WHEN a.d_plan IS NOT NULL THEN FALSE ELSE coalesce(nd.td_actual, FALSE) END AS td_actual
      FROM arr a
      LEFT JOIN LATERAL (SELECT y.td, y.td_actual FROM dep y
                          WHERE y.reg = a.reg AND y.td > a.ta AND y.dep_flight <> a.flight_id
                          ORDER BY y.td LIMIT 1) nd ON TRUE
  ) x
$$;

-- Helper: outcome of one dimension. NULL remaining = the capacity or the occupancy is unknown.
CREATE OR REPLACE FUNCTION fogops.capacity_class(p_remaining INT, p_margin INT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
SELECT CASE WHEN p_remaining IS NULL THEN 'UNKNOWN' WHEN p_remaining < 0 THEN 'EXCEEDED'
            WHEN p_remaining <= p_margin THEN 'CONSTRAINED' ELSE 'AVAILABLE' END
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. Assessment and what-if. READ-ONLY: it never writes, so a what-if cannot touch baseline or scenario data.
--    p_flight_id : the flight being assessed (it is removed from the existing picture and counted once as proposed)
--    p_extra     : further hypothetical flights arriving in the same hour
--    p_delay_min : shifts the arrival of the assessed flight
--    p_arrival   : explicit arrival instant; default = the flight's own ETA if it already lands here, else now + historical
--                  airborne P50 from the flight's planned destination to this airport (+ delay)
--    Returns one jsonb document (numbers, sources, per-hour outlook, plain-language reasons).
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fogops.airport_capacity_assess(p_scenario_id INT, p_iata CHAR(3), p_arrival TIMESTAMPTZ DEFAULT NULL,
        p_extra INT DEFAULT 0, p_flight_id BIGINT DEFAULT NULL, p_delay_min INT DEFAULT 0, p_window_h INT DEFAULT 12)
RETURNS JSONB LANGUAGE plpgsql STABLE SET search_path TO 'fogops', 'hist', 'public' AS $$
DECLARE
    v_now    TIMESTAMPTZ := scenario_now(p_scenario_id);
    v_cap    RECORD;
    v_max    INTERVAL := make_interval(hours => coalesce((SELECT value FROM divert_policy WHERE key = 'history_max_stay_hours'), 48)::int);
    v_margin INT := coalesce((SELECT value FROM divert_policy WHERE key = 'capacity_constrained_margin'), 1)::int;
    v_arr    TIMESTAMPTZ := p_arrival;
    v_arr_basis TEXT := CASE WHEN p_arrival IS NOT NULL THEN 'Arrival time supplied by the caller' END;
    v_prop   INT := greatest(coalesce(p_extra, 0), 0) + CASE WHEN p_flight_id IS NOT NULL THEN 1 ELSE 0 END;
    v_flight RECORD;
    v_leg    INT;
    v_hr     TIMESTAMPTZ;
    v_ex     INT; v_dep_hr INT;
    v_occ_k  INT; v_occ_u INT; v_occ_now_k INT; v_occ_now_u INT;
    v_net    INT;
    v_av_b   INT; v_av_a INT; v_ar_b INT; v_ar_a INT;
    v_c_st   TEXT; v_c_ar TEXT; v_out TEXT;
    v_hourly JSONB; v_reasons JSONB := '[]'::jsonb; v_op TEXT; v_lb BOOLEAN; v_verify BOOLEAN := FALSE;
    v_unpaired INT; v_inbound_unpaired INT; v_evid INT;
BEGIN
    SELECT * INTO v_cap FROM airport_capacity_resolve(p_scenario_id, p_iata, v_now);
    SELECT op_status::text INTO v_op FROM v_airport_status_current WHERE scenario_id = p_scenario_id AND iata = p_iata;

    -- when does the assessed flight arrive here
    IF v_arr IS NULL AND p_flight_id IS NOT NULL THEN
        SELECT f.arr_iata AS plan_arr, coalesce(fs.actual_arr_iata, f.arr_iata) AS eff, fs.ata_utc, fs.eta_utc, f.sta_utc INTO v_flight
          FROM flight f LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = p_scenario_id
         WHERE f.flight_id = p_flight_id;
        IF FOUND AND v_flight.eff = p_iata THEN
            v_arr := coalesce(v_flight.ata_utc, v_flight.eta_utc, v_flight.sta_utc) + make_interval(mins => coalesce(p_delay_min, 0));
            v_arr_basis := 'The flight already lands here: its own ' || CASE WHEN v_flight.ata_utc IS NOT NULL THEN 'actual arrival' WHEN v_flight.eta_utc IS NOT NULL THEN 'updated ETA' ELSE 'scheduled arrival' END;
        ELSIF FOUND THEN
            SELECT airborne_p50_min INTO v_leg FROM leg_time_reference WHERE from_iata = v_flight.plan_arr AND to_iata = p_iata;
            IF v_leg IS NOT NULL THEN
                v_arr := v_now + make_interval(mins => v_leg + coalesce(p_delay_min, 0));
                v_arr_basis := format('ESTIMATED: now + %s min historical airborne P50 from %s%s', v_leg, v_flight.plan_arr,
                                      CASE WHEN coalesce(p_delay_min, 0) <> 0 THEN format(' + %s min delay', p_delay_min) ELSE '' END);
            END IF;
        END IF;
    END IF;
    IF v_arr IS NULL THEN
        v_arr := v_now + make_interval(mins => coalesce(p_delay_min, 0));
        v_arr_basis := CASE WHEN p_flight_id IS NULL THEN 'No flight given: assessed at the scenario clock' ELSE 'ASSUMED: no leg-time reference, assessed at the scenario clock' END;
    END IF;
    v_hr := date_trunc('hour', v_arr);

    -- occupancy now and at the arrival instant (the assessed flight is removed from the existing picture)
    WITH st AS MATERIALIZED (SELECT * FROM airport_stays(p_scenario_id, p_iata, p_flight_id))
    SELECT
        count(*) FILTER (WHERE s.ta <= v_arr AND s.td IS NOT NULL AND v_arr < s.td),
        count(*) FILTER (WHERE s.ta <= v_arr AND s.td IS NULL AND s.ta_actual AND v_arr - s.ta <= v_max),
        count(*) FILTER (WHERE s.ta <= v_now AND s.td IS NOT NULL AND v_now < s.td),
        count(*) FILTER (WHERE s.ta <= v_now AND s.td IS NULL AND s.ta_actual AND v_now - s.ta <= v_max),
        count(*) FILTER (WHERE s.ta >= v_hr AND s.ta < v_hr + interval '1 hour'),
        count(*) FILTER (WHERE s.td >= v_hr AND s.td < v_hr + interval '1 hour'),
        count(*) FILTER (WHERE s.td IS NULL AND s.ta_actual AND v_now - s.ta <= v_max),
        count(*) FILTER (WHERE s.td IS NULL AND NOT s.ta_actual AND s.ta > v_now),
        -- net change in free stands since the latest status entry: arrivals after it minus departures after it
        coalesce(count(*) FILTER (WHERE s.ta > v_cap.status_effective_from AND s.ta <= v_arr), 0)
          - coalesce(count(*) FILTER (WHERE s.td IS NOT NULL AND s.td > v_cap.status_effective_from AND s.td <= v_arr AND s.ta <= v_arr), 0),
        count(*)
      INTO v_occ_k, v_occ_u, v_occ_now_k, v_occ_now_u, v_ex, v_dep_hr, v_unpaired, v_inbound_unpaired, v_net, v_evid
      FROM st s;

    -- stands: a status entry says FREE stands at entry time, so later movements move it; any other source is a total
    IF v_cap.stands_total IS NULL THEN
        v_av_b := NULL;
    ELSIF v_cap.stands_source = 'STATUS_EVENT' THEN
        v_av_b := v_cap.stands_total - v_net;
    ELSE
        v_av_b := v_cap.stands_total - v_occ_k - v_occ_u;
    END IF;
    v_av_a := v_av_b - v_prop;
    v_ar_b := CASE WHEN v_cap.arrivals_per_hr IS NULL THEN NULL ELSE v_cap.arrivals_per_hr - v_ex END;
    v_ar_a := v_ar_b - v_prop;

    v_c_st := capacity_class(v_av_a, v_margin);
    v_c_ar := capacity_class(v_ar_a, v_margin);
    v_lb := (v_cap.stands_source = 'HISTORY' OR v_cap.arrivals_source = 'HISTORY');
    -- a shortfall against a history figure only means "beyond what we have seen handled", never "over the limit"
    IF v_cap.stands_source = 'HISTORY' AND v_c_st = 'EXCEEDED' THEN v_c_st := 'CONSTRAINED'; END IF;
    IF v_cap.arrivals_source = 'HISTORY' AND v_c_ar = 'EXCEEDED' THEN v_c_ar := 'CONSTRAINED'; END IF;
    v_out := CASE WHEN 'EXCEEDED' IN (v_c_st, v_c_ar) THEN 'CAPACITY_EXCEEDED'
                  WHEN 'CONSTRAINED' IN (v_c_st, v_c_ar) THEN 'CAPACITY_CONSTRAINED'
                  WHEN 'UNKNOWN' IN (v_c_st, v_c_ar) THEN 'UNKNOWN_VERIFICATION_REQUIRED'
                  ELSE 'CAPACITY_AVAILABLE' END;
    v_verify := v_out = 'UNKNOWN_VERIFICATION_REQUIRED' OR v_lb OR 'UNKNOWN' IN (v_c_st, v_c_ar) OR v_cap.stands_source = 'UNKNOWN'
                OR (v_evid = 0 AND v_cap.stands_source IS DISTINCT FROM 'STATUS_EVENT');

    -- plain-language reasons
    v_reasons := v_reasons || to_jsonb(CASE
        WHEN v_cap.stands_total IS NULL THEN 'Stands: unknown (' || v_cap.stands_basis || ')'
        WHEN v_cap.stands_source = 'STATUS_EVENT' THEN format('Stands: %s free at the last status entry %s %s since (arrivals minus departures after it) = %s free at the arrival, %s after the proposed flight(s)',
                                                              v_cap.stands_total, CASE WHEN v_net >= 0 THEN '-' ELSE '+' END, abs(v_net), v_av_b, v_av_a)
        ELSE format('Stands: %s total (%s) - %s on the ground at the arrival (%s with a known departure, %s with none known) - %s proposed = %s',
                    v_cap.stands_total, v_cap.stands_source, v_occ_k + v_occ_u, v_occ_k, v_occ_u, v_prop, v_av_a) END);
    v_reasons := v_reasons || to_jsonb(CASE
        WHEN v_cap.arrivals_per_hr IS NULL THEN 'Arrivals per hour: unknown (' || v_cap.arrivals_basis || ')'
        ELSE format('Arrivals in the hour of %s UTC: %s per hour (%s) - %s already scheduled - %s proposed = %s remaining',
                    to_char(v_hr AT TIME ZONE 'UTC', 'HH24:MI'), v_cap.arrivals_per_hr, v_cap.arrivals_source, v_ex, v_prop, v_ar_a) END);
    IF v_lb THEN v_reasons := v_reasons || to_jsonb('A history figure is a lower bound of what the airport has handled, not its limit: confirm a real capacity (Set capacity).'::text); END IF;
    IF v_op IN ('CLOSED', 'RESTRICTED') THEN v_reasons := v_reasons || to_jsonb(format('Airport status is %s: capacity alone does not make a diversion acceptable.', v_op)); END IF;
    IF v_evid = 0 THEN v_reasons := v_reasons || to_jsonb('No Air Arabia movement to this airport is in the data: its occupancy is unknown, not zero.'::text); END IF;
    v_reasons := v_reasons || to_jsonb('Occupancy counts Air Arabia movements only: other operators and aircraft parked before the data starts are not known. It is derived from the schedule, not verified real-time occupancy.'::text);

    -- hour-by-hour outlook from the scenario clock; the proposed extra flights are added to every hour ("if they arrived in this hour")
    SELECT coalesce(jsonb_agg(row_to_json(q)::jsonb ORDER BY q.hour_utc), '[]'::jsonb) INTO v_hourly FROM (
        WITH st AS MATERIALIZED (SELECT * FROM airport_stays(p_scenario_id, p_iata, p_flight_id)),
        hrs AS (SELECT date_trunc('hour', v_now) + make_interval(hours => g) AS h FROM generate_series(0, greatest(least(p_window_h, 48), 1) - 1) g),
        calc AS (
            SELECT h.h AS hr,
                   (SELECT count(*) FROM st s WHERE s.ta >= h.h AND s.ta < h.h + interval '1 hour') AS arrs,
                   (SELECT count(*) FROM st s WHERE s.td >= h.h AND s.td < h.h + interval '1 hour') AS deps,
                   (SELECT count(*) FROM st s WHERE s.ta <= h.h + interval '1 hour' AND ((s.td IS NOT NULL AND h.h + interval '1 hour' < s.td) OR (s.td IS NULL AND s.ta_actual AND h.h + interval '1 hour' - s.ta <= v_max))) AS occ,
                   (SELECT count(*) FROM st s WHERE s.ta > v_cap.status_effective_from AND s.ta <= h.h + interval '1 hour')
                     - (SELECT count(*) FROM st s WHERE s.td IS NOT NULL AND s.td > v_cap.status_effective_from AND s.td <= h.h + interval '1 hour' AND s.ta <= h.h + interval '1 hour') AS net
              FROM hrs h)
        SELECT c.hr AS hour_utc, c.arrs AS arrivals_scheduled, c.deps AS departures_scheduled, c.occ AS on_ground,
               CASE WHEN v_cap.arrivals_per_hr IS NULL THEN NULL ELSE v_cap.arrivals_per_hr - c.arrs END AS arrival_slots_left,
               CASE WHEN v_cap.stands_total IS NULL THEN NULL WHEN v_cap.stands_source = 'STATUS_EVENT' THEN v_cap.stands_total - c.net ELSE v_cap.stands_total - c.occ END AS stands_free,
               CASE WHEN v_cap.arrivals_per_hr IS NULL THEN NULL ELSE v_cap.arrivals_per_hr - c.arrs - v_prop END AS arrival_slots_left_with_proposed,
               CASE WHEN v_cap.stands_total IS NULL THEN NULL WHEN v_cap.stands_source = 'STATUS_EVENT' THEN v_cap.stands_total - c.net - v_prop ELSE v_cap.stands_total - c.occ - v_prop END AS stands_free_with_proposed
          FROM calc c) q;

    RETURN jsonb_build_object(
        'iata', p_iata, 'scenario_id', p_scenario_id, 'scenario_now_utc', v_now,
        'arrival_utc', v_arr, 'arrival_basis', v_arr_basis, 'arrival_hour_utc', v_hr,
        'airport_op_status', v_op,
        'outcome', v_out, 'verification_required', v_verify, 'stands_outcome', v_c_st, 'arrivals_outcome', v_c_ar,
        'proposed_flights', v_prop, 'flight_id', p_flight_id, 'extra_flights', coalesce(p_extra, 0), 'delay_min', coalesce(p_delay_min, 0),
        'stands', jsonb_build_object('total', v_cap.stands_total, 'source', v_cap.stands_source, 'quality', v_cap.stands_quality,
                                     'basis', v_cap.stands_basis, 'as_of_utc', v_cap.stands_as_of,
                                     'free_before', v_av_b, 'free_after', v_av_a),
        'arrivals_per_hr', jsonb_build_object('capacity', v_cap.arrivals_per_hr, 'source', v_cap.arrivals_source, 'quality', v_cap.arrivals_quality,
                                              'basis', v_cap.arrivals_basis, 'as_of_utc', v_cap.arrivals_as_of,
                                              'scheduled_in_hour', v_ex, 'projected_in_hour', v_ex + v_prop,
                                              'remaining_before', v_ar_b, 'remaining_after', v_ar_a),
        'occupancy', jsonb_build_object('verified_real_time', FALSE, 'stays_in_data', v_evid, 'movement_evidence', v_evid > 0, 'basis', 'Derived from Air Arabia movements (flight_state, diversion); not verified real-time occupancy',
                                        'on_ground_now_known_departure', v_occ_now_k, 'on_ground_now_no_known_departure', v_occ_now_u,
                                        'on_ground_at_arrival_known_departure', v_occ_k, 'on_ground_at_arrival_no_known_departure', v_occ_u,
                                        'arrived_without_known_departure', v_unpaired, 'inbound_without_known_departure', v_inbound_unpaired,
                                        'departures_in_arrival_hour', v_dep_hr),
        'history', jsonb_build_object('sample_n', v_cap.sample_n, 'min_sample_hours', v_cap.min_sample_hours,
                                      'peak_arrivals_per_hr', v_cap.hist_peak_arrivals, 'peak_ground', v_cap.hist_peak_ground,
                                      'lower_bound_note', 'A historical peak is a lower bound of what the airport handled, not its limit'),
        'reasons', v_reasons, 'hourly', v_hourly);
END $$;
