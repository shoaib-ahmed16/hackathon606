-- 015: per-diversion recovery plan (read model, writes nothing).
--
-- For every active diversion (aircraft on the ground at the alternate, recovery leg ALT -> hub not yet departed):
--   * when the aircraft can leave and when it reaches the hub (ready time at the alternate, hub reopening,
--     and the arrival slot of the current recovery plan when there is one);
--   * whether the crew can legally fly the return leg at that time (latest legal / with-discretion off-blocks of the recovery
--     leg), and when they cannot: the best standby replacements (standby_candidates(), LVP, rest and roster included);
--   * which connecting passengers would miss their onward flight at the PROJECTED hub arrival. v_connection_risk measures a
--     diverted inbound from its landing at the alternate, which says nothing about SHJ, so it is recomputed here.
-- Risk figures only: no rebooking logic. The minimum connection time is an ASSUMPTION (parameter, default 30 min, as agreed
-- with the team; v_connection_risk still uses 40 for its own AT_RISK); no official minimum connection time was supplied.
-- Nothing is decided here: the suggested action is text for the humans, the decision flow is unchanged.

SET search_path = fogops, public;

CREATE OR REPLACE FUNCTION fogops.diversion_recovery_plan(p_scenario_id INT, p_case_id INT DEFAULT NULL,
                                                          p_min_connection_min INT DEFAULT 30)
RETURNS TABLE (diversion_id BIGINT, case_id INT, original_flight_id BIGINT, original_flight_no TEXT,
               recovery_flight_id BIGINT, recovery_flight_no TEXT, registration TEXT, diversion_status TEXT,
               alternate_iata CHAR(3), hub_iata CHAR(3), hub_status TEXT, hub_reopen_utc TIMESTAMPTZ,
               landed_alt_utc TIMESTAMPTZ, on_blocks_alt_utc TIMESTAMPTZ, turnaround_min INT, ready_at_alt_utc TIMESTAMPTZ,
               arrival_slot_utc TIMESTAMPTZ, block_min INT, projected_dep_utc TIMESTAMPTZ, projected_hub_arrival_utc TIMESTAMPTZ,
               latest_legal_dep_utc TIMESTAMPTZ, latest_dep_with_discretion_utc TIMESTAMPTZ,
               crew_margin_min INT, crew_outcome TEXT, standby JSONB,
               connections_total INT, pax_total INT, connections_missed INT, pax_missed INT,
               connections_at_risk INT, pax_at_risk INT, tightest_slack_min INT, min_connection_min INT,
               connections JSONB, suggested_action TEXT, reasons TEXT[], quality TEXT, basis TEXT)
LANGUAGE plpgsql STABLE
SET search_path TO 'fogops', 'public'
AS $$
#variable_conflict use_column
DECLARE
    v_now TIMESTAMPTZ := scenario_now(p_scenario_id);
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT dv.diversion_id, dv.case_id, dv.original_flight_id, fo.flight_no AS orig_no,
               dv.recovery_flight_id, rf.flight_no AS rec_no,
               coalesce(rs.registration, so.registration) AS reg, dv.status AS dv_status,
               dv.alternate_iata AS alt, c.hub_iata AS hub, dv.landed_alt_utc, dv.on_blocks_alt_utc,
               coalesce(dv.turnaround_min_assumed, 40) AS turn_min,
               greatest(v_now, coalesce(dv.on_blocks_alt_utc, dv.landed_alt_utc, v_now)
                               + make_interval(mins => coalesce(dv.turnaround_min_assumed, 40))) AS ready_alt,
               ld.latest_legal_offblocks_utc AS ll, ld.latest_with_discretion_utc AS ld_disc,
               ld.status::text AS ld_status, ld.duty_id, ld.binding_crew_id,
               floor(extract(epoch FROM (rf.sta_utc - rf.std_utc)) / 60)::int AS sched_blk,
               ld.block_time_min AS ld_blk,
               hs.op_status::text AS hub_status,
               CASE WHEN hs.op_status = 'OPEN' THEN v_now ELSE hs.expected_reopen_utc END AS reopen,
               it.proposed_slot_utc AS slot,
               (SELECT a.position_code FROM crew_assignment a
                 WHERE a.scenario_id = dv.scenario_id AND a.duty_id = ld.duty_id AND a.crew_id = ld.binding_crew_id
                   AND a.valid_to IS NULL LIMIT 1) AS bind_pos,
               (SELECT l.leg_seq FROM crew_duty_leg l
                 WHERE l.scenario_id = dv.scenario_id AND l.duty_id = ld.duty_id AND l.flight_id = dv.recovery_flight_id
                   AND l.is_active LIMIT 1) AS rec_leg_seq
          FROM diversion dv
          JOIN disruption_case c ON c.case_id = dv.case_id
          JOIN flight fo ON fo.flight_id = dv.original_flight_id
          JOIN flight rf ON rf.flight_id = dv.recovery_flight_id
          LEFT JOIN flight_state rs ON rs.flight_id = rf.flight_id AND rs.scenario_id = dv.scenario_id
          LEFT JOIN flight_state so ON so.flight_id = fo.flight_id AND so.scenario_id = dv.scenario_id
          LEFT JOIN latest_departure_calc ld ON ld.scenario_id = dv.scenario_id AND ld.flight_id = dv.recovery_flight_id AND ld.is_current
          LEFT JOIN LATERAL (SELECT x.op_status, x.expected_reopen_utc FROM airport_status_event x
                              WHERE x.scenario_id = dv.scenario_id AND x.iata = c.hub_iata AND x.effective_from_utc <= v_now
                              ORDER BY x.effective_from_utc DESC, x.status_event_id DESC LIMIT 1) hs ON TRUE
          LEFT JOIN LATERAL (SELECT i.proposed_slot_utc FROM recovery_plan_item i JOIN recovery_plan p USING (plan_id)
                              WHERE p.scenario_id = dv.scenario_id AND p.case_id = dv.case_id AND p.status IN ('PROPOSED', 'APPROVED')
                                AND i.flight_id = dv.recovery_flight_id AND i.proposed_slot_utc IS NOT NULL
                              ORDER BY p.generated_at DESC, p.plan_id DESC LIMIT 1) it ON TRUE
         WHERE dv.scenario_id = p_scenario_id AND (p_case_id IS NULL OR dv.case_id = p_case_id)
           AND dv.recovery_flight_id IS NOT NULL AND dv.status NOT IN ('DEPARTED', 'CLOSED', 'CANCELLED')
    ), t1 AS (
        SELECT b.*, coalesce(b.sched_blk, b.ld_blk) AS blk,   -- planned block of the recovery leg: same basis as the Recovery tab slots
               greatest(b.ready_alt, coalesce(b.reopen - make_interval(mins => coalesce(b.sched_blk, b.ld_blk)), b.ready_alt)) AS earliest_dep
          FROM base b
    ), t2 AS (
        SELECT t1.*, greatest(t1.earliest_dep, coalesce(t1.slot - make_interval(mins => t1.blk), t1.earliest_dep)) AS proj_dep
          FROM t1
    ), t3 AS (
        SELECT t2.*, t2.proj_dep + make_interval(mins => t2.blk) AS proj_arr,
               CASE WHEN t2.ll IS NULL OR t2.ld_status = 'VERIFICATION_REQUIRED' THEN NULL
                    ELSE floor(extract(epoch FROM (t2.ll - t2.proj_dep)) / 60)::int END AS margin,
               CASE WHEN t2.ll IS NULL OR t2.ld_status = 'VERIFICATION_REQUIRED' THEN 'VERIFY_CREW'
                    WHEN t2.ll >= t2.proj_dep THEN 'CREW_CAN_RETURN'
                    WHEN t2.ld_disc >= t2.proj_dep THEN 'NEEDS_COMMANDER_DISCRETION'
                    ELSE 'NEEDS_REPLACEMENT' END AS outcome
          FROM t2
    ), conn AS (
        SELECT t3.diversion_id,
               x.outbound_flight_id, x.outbound_flight, x.outbound_to, x.pax, x.out_dep, x.slack,
               CASE WHEN x.cancelled THEN 'CANCELLED'
                    WHEN x.departed_before OR x.slack < 0 THEN 'MISSED'
                    WHEN x.slack < p_min_connection_min THEN 'AT_RISK'
                    ELSE 'OK' END AS status
          FROM t3
          CROSS JOIN LATERAL (
              SELECT pc.outbound_flight_id, fx.flight_no AS outbound_flight, fx.arr_iata AS outbound_to,
                     sum(pc.pax_count)::int AS pax,
                     min(coalesce(sx.atd_utc, sx.etd_utc, fx.std_utc)) AS out_dep,
                     floor(extract(epoch FROM (min(coalesce(sx.atd_utc, sx.etd_utc, fx.std_utc)) - t3.proj_arr)) / 60)::int AS slack,
                     bool_or(coalesce(sx.is_cancelled, FALSE) OR sx.status::text = 'CANCELLED') AS cancelled,
                     bool_or(sx.atd_utc IS NOT NULL AND sx.atd_utc < t3.proj_arr) AS departed_before
                FROM pax_connection pc
                JOIN flight fx ON fx.flight_id = pc.outbound_flight_id
                LEFT JOIN flight_state sx ON sx.flight_id = pc.outbound_flight_id AND sx.scenario_id = p_scenario_id
               WHERE pc.inbound_flight_id IN (t3.original_flight_id, t3.recovery_flight_id)
               GROUP BY pc.outbound_flight_id, fx.flight_no, fx.arr_iata) x
    ), cagg AS (
        SELECT c.diversion_id, count(*)::int AS n, coalesce(sum(c.pax), 0)::int AS pax,
               count(*) FILTER (WHERE c.status IN ('MISSED', 'CANCELLED'))::int AS n_miss,
               coalesce(sum(c.pax) FILTER (WHERE c.status IN ('MISSED', 'CANCELLED')), 0)::int AS pax_miss,
               count(*) FILTER (WHERE c.status = 'AT_RISK')::int AS n_risk,
               coalesce(sum(c.pax) FILTER (WHERE c.status = 'AT_RISK'), 0)::int AS pax_risk,
               min(c.slack) AS tight,
               jsonb_agg(jsonb_build_object('outbound_flight_id', c.outbound_flight_id, 'outbound_flight', c.outbound_flight,
                                            'outbound_to', c.outbound_to, 'pax_count', c.pax,
                                            'outbound_departure_utc', c.out_dep, 'slack_min', c.slack, 'status', c.status)
                         ORDER BY c.slack, c.outbound_flight) AS items
          FROM conn c GROUP BY c.diversion_id
    )
    SELECT t3.diversion_id, t3.case_id, t3.original_flight_id, t3.orig_no, t3.recovery_flight_id, t3.rec_no, t3.reg,
           t3.dv_status, t3.alt, t3.hub, t3.hub_status, t3.reopen, t3.landed_alt_utc, t3.on_blocks_alt_utc, t3.turn_min,
           t3.ready_alt, t3.slot, t3.blk, t3.proj_dep, t3.proj_arr, t3.ll, t3.ld_disc, t3.margin, t3.outcome,
           CASE WHEN t3.outcome = 'NEEDS_REPLACEMENT' AND t3.bind_pos IS NOT NULL AND t3.rec_leg_seq IS NOT NULL THEN
                (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'crew_id', s.crew_id, 'full_name', s.full_name, 'position_code', s.position_code,
                            'lvp_qualified', s.lvp_qualified, 'positioning_min', s.positioning_min,
                            'new_sign_in_utc', s.new_sign_in_utc, 'margin_min', s.margin_min,
                            'roster_conflict', s.roster_conflict, 'verdict', s.verdict)
                         ORDER BY (s.verdict = 'CANDIDATE') DESC, s.lvp_qualified DESC, s.roster_conflict, s.margin_min DESC NULLS LAST, s.positioning_min NULLS LAST), '[]'::jsonb)
                   FROM (SELECT * FROM standby_candidates(p_scenario_id, t3.duty_id, t3.bind_pos, t3.alt, t3.rec_leg_seq::smallint)
                          ORDER BY (verdict = 'CANDIDATE') DESC, lvp_qualified DESC, roster_conflict, margin_min DESC NULLS LAST, positioning_min NULLS LAST LIMIT 3) s)
           END,
           coalesce(a.n, 0), coalesce(a.pax, 0), coalesce(a.n_miss, 0), coalesce(a.pax_miss, 0),
           coalesce(a.n_risk, 0), coalesce(a.pax_risk, 0), a.tight, p_min_connection_min,
           coalesce(a.items, '[]'::jsonb),
           CASE t3.outcome
                WHEN 'CREW_CAN_RETURN' THEN format('Suggested: depart %s with the current crew (%s min before their latest legal departure), arrive %s.',
                        to_char(t3.proj_dep AT TIME ZONE 'UTC', 'HH24:MI"Z"'), t3.margin, to_char(t3.proj_arr AT TIME ZONE 'UTC', 'HH24:MI"Z"'))
                WHEN 'NEEDS_COMMANDER_DISCRETION' THEN format('Departure %s is after the latest legal departure %s: commander discretion (until %s) or a crew change is needed.',
                        to_char(t3.proj_dep AT TIME ZONE 'UTC', 'HH24:MI"Z"'), to_char(t3.ll AT TIME ZONE 'UTC', 'HH24:MI"Z"'),
                        to_char(t3.ld_disc AT TIME ZONE 'UTC', 'HH24:MI"Z"'))
                WHEN 'NEEDS_REPLACEMENT' THEN format('The crew cannot legally fly the return (latest legal departure %s, projected %s): replace the crew%s.',
                        to_char(t3.ll AT TIME ZONE 'UTC', 'HH24:MI"Z"'), to_char(t3.proj_dep AT TIME ZONE 'UTC', 'HH24:MI"Z"'),
                        CASE WHEN t3.bind_pos IS NULL THEN '' ELSE ' (standby options listed)' END)
                ELSE 'Crew legality for the return leg needs verification before this plan can be relied on.'
           END,
           array_remove(ARRAY[
               CASE WHEN t3.reopen IS NULL THEN 'Hub reopening time unknown: the earliest return is limited by the aircraft only' END,
               CASE WHEN t3.slot IS NOT NULL THEN format('Arrival slot %s from the current recovery plan', to_char(t3.slot AT TIME ZONE 'UTC', 'HH24:MI"Z"')) END,
               CASE WHEN coalesce(a.pax_miss, 0) > 0 THEN format('%s connecting pax on %s flight(s) would miss their onward flight', a.pax_miss, a.n_miss) END,
               CASE WHEN coalesce(a.pax_risk, 0) > 0 THEN format('%s connecting pax on %s flight(s) have under %s min to connect', a.pax_risk, a.n_risk, p_min_connection_min) END,
               CASE WHEN t3.outcome = 'NEEDS_REPLACEMENT' AND t3.bind_pos IS NULL THEN 'Binding crew member position unknown: standby options not listed' END
           ], NULL),
           'ESTIMATED',
           format('Ready at %s = %s on blocks + %s min turnaround (ASSUMED %s min when none recorded); hub reopening %s; block %s min. '
                  'Minimum connection time %s min is ASSUMED (none supplied). Passenger counts are the loaded connections for the original and recovery flight.',
                  to_char(t3.ready_alt AT TIME ZONE 'UTC', 'HH24:MI"Z"'), t3.alt, t3.turn_min, 40,
                  coalesce(to_char(t3.reopen AT TIME ZONE 'UTC', 'HH24:MI"Z"'), 'unknown'), t3.blk, p_min_connection_min)
      FROM t3 LEFT JOIN cagg a ON a.diversion_id = t3.diversion_id
     ORDER BY t3.proj_dep, t3.diversion_id;
END $$;
