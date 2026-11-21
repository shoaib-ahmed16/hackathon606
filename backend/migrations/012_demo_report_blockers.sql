-- 012: fixes from the demo test report (blockers B1 to B4).
--  B3  Stale ETAs drove crew legality: an airborne flight whose ETA has passed was still "landing" in the past, so its crew looked
--      safer than they are. The projected landing is now never earlier than the scenario clock, the row is marked ESTIMATE_OVERDUE
--      and treated as stale (legality becomes VERIFICATION_REQUIRED unless the limit is already exceeded).
--  B4  "Flights affected" counted every scheduled flight even with no disruption at all (98 flights, 4,867 passengers). A flight
--      that has not left yet now counts as affected only while the hub it flies to is closed or under LVP.
--  (B1, B2 are API and screen fixes: options of the open recommendation only; deadline follows the recommended alternate.)

SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION projected_on_blocks(p_scenario_id INT, p_flight_id BIGINT,
                                               OUT ts TIMESTAMPTZ, OUT basis TEXT, OUT stale BOOLEAN)
LANGUAGE sql STABLE SET search_path = fogops, public AS $$
    WITH x AS (
        SELECT f.sta_utc, s.ata_utc, s.eta_utc, s.last_received_at, coalesce(s.status::text,'SCHEDULED') AS st,
               scenario_now(p_scenario_id) AS now_ts
          FROM flight f
          LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
         WHERE f.flight_id = p_flight_id
    )
    SELECT CASE WHEN ata_utc IS NOT NULL THEN ata_utc
                -- an estimate in the past for a flight still in the air is not a landing time: it cannot land before now
                WHEN eta_utc IS NOT NULL AND st IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING') AND eta_utc < now_ts THEN now_ts
                ELSE coalesce(eta_utc, sta_utc) END,
           CASE WHEN ata_utc IS NOT NULL THEN 'ACTUAL'
                WHEN eta_utc IS NOT NULL AND st IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING') AND eta_utc < now_ts THEN 'ESTIMATE_OVERDUE'
                WHEN eta_utc IS NOT NULL THEN 'ESTIMATE' ELSE 'SCHEDULE' END,
           (st IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING')
             AND (last_received_at IS NULL
                  OR now_ts - last_received_at > make_interval(secs => coalesce((SELECT max(stale_after_sec) FROM feed_source), 600))
                  OR (ata_utc IS NULL AND eta_utc IS NOT NULL AND eta_utc < now_ts)))
      FROM x
$$;

CREATE OR REPLACE VIEW v_disruption_kpis AS
SELECT w.case_id,
    w.scenario_id,
    count(*) AS flights_watched,
    count(*) FILTER (WHERE ((w.status = ANY (ARRAY['AIRBORNE'::flight_status, 'HOLDING'::flight_status, 'DIVERTING'::flight_status])) OR (w.diverted_to IS NOT NULL)
        -- a flight that has not left yet is only affected while the hub it flies to is restricted
        OR (w.status = 'SCHEDULED'::flight_status AND EXISTS (SELECT 1 FROM disruption_case dc JOIN v_airport_status_current a ON a.scenario_id = w.scenario_id AND a.iata = dc.hub_iata
                                                         WHERE dc.case_id = w.case_id AND (a.op_status <> 'OPEN' OR a.lvp_in_force))))) AS flights_affected,
    count(*) FILTER (WHERE (w.status = 'HOLDING'::flight_status)) AS holding,
    count(*) FILTER (WHERE (w.diverted_to IS NOT NULL)) AS diverted,
    count(*) FILTER (WHERE (w.crew_status = ANY (ARRAY['AT_RISK'::legality_status, 'DISCRETION_REQUIRED'::legality_status, 'EXCEEDED'::legality_status]))) AS crew_at_risk,
    count(*) FILTER (WHERE (w.lvp_required AND (w.lvp_crew_ok IS NOT TRUE))) AS lvp_blocked,
    count(*) FILTER (WHERE ((w.crew_status = 'VERIFICATION_REQUIRED'::legality_status) OR (w.open_exceptions > 0))) AS needs_verification,
    ( SELECT count(*) AS count
           FROM decision d
          WHERE ((d.case_id = w.case_id) AND (d.status = 'PROPOSED'::decision_status))) AS decisions_pending,
    sum(COALESCE(fs.pax, 0)) AS pax_on_board,
    sum(sv.connecting_pax) AS connecting_pax,
    min(w.minutes_to_latest_legal_departure) AS next_departure_deadline_min
   FROM ((v_flight_watch w
     LEFT JOIN flight_state fs ON (((fs.flight_id = w.flight_id) AND (fs.scenario_id = w.scenario_id))))
     LEFT JOIN v_flight_severity sv ON (((sv.case_id = w.case_id) AND (sv.flight_id = w.flight_id))))
  GROUP BY w.case_id, w.scenario_id;

-- recompute legality of the duties that are running now, so stored margins reflect the new projection
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT DISTINCT l.scenario_id, l.duty_id
               FROM crew_duty_leg l JOIN flight_state s ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
              WHERE l.is_active AND s.status IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING') AND s.ata_utc IS NULL LOOP
        BEGIN
            PERFORM compute_duty_legality(r.scenario_id, r.duty_id, 'migration_012');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'could not recompute duty %: %', r.duty_id, SQLERRM;
        END;
    END LOOP;
END $$;

-- keep search_path pinned on every function (same block as 010 and 011)
DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'fogops' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = fogops, public', f.sig);
    END LOOP;
END $$;
