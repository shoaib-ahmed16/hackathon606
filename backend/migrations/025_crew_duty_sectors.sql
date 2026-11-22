-- Crew Control: the sectors of a duty with their own hours, and whether a diversion is in play.
-- Display data only. Legality (sign-in based approved FDP) is untouched and still comes from fdp_calculation.
-- Per active leg: departure/arrival (actual > estimate > schedule, each labelled), block minutes, ground time to the
-- next leg, and totals over the duty. diversion_in_play is TRUE when any flight of the duty is diverting/diverted,
-- has an open diversion record, or the duty already carries a DIVERSION leg. Read-only, safe to re-run.
CREATE OR REPLACE FUNCTION crew_duty_sectors(p_scenario_id INT, p_duty_id BIGINT)
RETURNS TABLE (leg_seq SMALLINT, flight_id BIGINT, flight_no TEXT, leg_source TEXT, flight_status TEXT,
               dep_iata CHAR(3), arr_iata CHAR(3), planned_arr_iata CHAR(3),
               dep_utc TIMESTAMPTZ, dep_basis TEXT, arr_utc TIMESTAMPTZ, arr_basis TEXT,
               block_min INT, ground_after_min INT,
               sector_total_min INT, ground_total_min INT, diversion_in_play BOOLEAN)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE v_div BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM crew_duty_leg l
          JOIN flight f ON f.flight_id = l.flight_id
          LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = l.scenario_id
         WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
           AND (l.leg_source = 'DIVERSION'
                OR s.status = 'DIVERTING'
                OR (s.actual_arr_iata IS NOT NULL AND s.actual_arr_iata <> f.arr_iata)
                OR EXISTS (SELECT 1 FROM diversion dv
                            WHERE dv.scenario_id = l.scenario_id AND dv.original_flight_id = f.flight_id
                              AND dv.status <> 'CANCELLED')))
      INTO v_div;

    RETURN QUERY
    WITH legs AS (
        SELECT l.leg_seq, f.flight_id, f.flight_no, l.leg_source, s.status::text AS st,
               f.dep_iata, coalesce(s.actual_arr_iata, f.arr_iata) AS arr, f.arr_iata AS planned_arr,
               coalesce(s.atd_utc, s.etd_utc, f.std_utc) AS dep_ts,
               CASE WHEN s.atd_utc IS NOT NULL THEN 'ACTUAL' WHEN s.etd_utc IS NOT NULL THEN 'ESTIMATED' ELSE 'SCHEDULED' END AS dep_b,
               pb.ts AS arr_ts,
               CASE WHEN s.ata_utc IS NOT NULL THEN 'ACTUAL' WHEN s.eta_utc IS NOT NULL THEN 'ESTIMATED' ELSE 'SCHEDULED' END AS arr_b
          FROM crew_duty_leg l
          JOIN flight f ON f.flight_id = l.flight_id
          LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = l.scenario_id
          LEFT JOIN LATERAL projected_on_blocks(p_scenario_id, f.flight_id) pb ON TRUE
         WHERE l.scenario_id = p_scenario_id AND l.duty_id = p_duty_id AND l.is_active
    ), withg AS (
        SELECT g.*, floor(extract(epoch FROM g.arr_ts - g.dep_ts) / 60)::int AS blk,
               floor(extract(epoch FROM lead(g.dep_ts) OVER (ORDER BY g.leg_seq) - g.arr_ts) / 60)::int AS gnd
          FROM legs g
    )
    SELECT w.leg_seq, w.flight_id, w.flight_no, w.leg_source, w.st, w.dep_iata, w.arr, w.planned_arr,
           w.dep_ts, w.dep_b, w.arr_ts, w.arr_b, w.blk, w.gnd,
           (sum(w.blk) OVER ())::int, (sum(w.gnd) OVER ())::int, v_div
      FROM withg w ORDER BY w.leg_seq;
END $$;
