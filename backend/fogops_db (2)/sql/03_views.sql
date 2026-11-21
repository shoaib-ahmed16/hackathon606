-- =====================================================================
-- Read models for the frontend. All are plain views over the state tables.
-- Times are UTC; *_local columns use the relevant airport's timezone.
-- =====================================================================
SET search_path = fogops, public;

-- Current operating status of every airport per scenario (respects the scenario clock)
CREATE OR REPLACE VIEW v_airport_status_current AS
SELECT DISTINCT ON (e.scenario_id, e.iata)
       e.scenario_id, e.iata, a.name, e.op_status, e.reason, e.visibility_m, e.lvp_in_force,
       e.arrival_capacity_per_hr, e.departure_capacity_per_hr, e.parking_available,
       e.weather_above_minima, e.handling_ok, e.fuel_ok,
       e.effective_from_utc, e.expected_reopen_utc,
       e.expected_reopen_utc AT TIME ZONE a.tz AS expected_reopen_local,
       e.quality, e.entered_at, e.status_event_id
  FROM airport_status_event e JOIN airport a ON a.iata = e.iata
 WHERE e.effective_from_utc <= scenario_now(e.scenario_id)
 ORDER BY e.scenario_id, e.iata, e.effective_from_utc DESC, e.status_event_id DESC;

CREATE OR REPLACE VIEW v_feed_freshness AS
SELECT source_code, description, last_event_ts, last_received_at, stale_after_sec,
       floor(extract(epoch FROM now() - last_received_at))::int AS age_sec,
       (last_received_at IS NULL OR now() - last_received_at > make_interval(secs => stale_after_sec)) AS is_stale
  FROM feed_source;

-- Duty-level (binding) legality per flight: the worst/smallest-margin duty operating it
CREATE OR REPLACE VIEW v_flight_crew_legality AS
SELECT DISTINCT ON (fc.scenario_id, l.flight_id)
       fc.scenario_id, l.flight_id, fc.duty_id, fc.calc_id,
       (fc.inputs->>'binding_crew_id')::int AS binding_crew_id,
       fc.position_code AS binding_position, fc.status AS crew_status, fc.margin_min AS crew_margin_min,
       fc.legal_end_utc, fc.discretion_end_utc, fc.projected_end_utc, fc.legs_counted, fc.max_fdp_min,
       fc.reasons, fc.calculated_at
  FROM crew_duty_leg l
  JOIN fdp_calculation fc ON fc.duty_id = l.duty_id AND fc.scenario_id = l.scenario_id
                         AND fc.is_current AND fc.crew_id IS NULL
 WHERE l.is_active
 ORDER BY fc.scenario_id, l.flight_id, fc.margin_min ASC NULLS FIRST;

-- ---------------------------------------------------------------------
-- The single flight watch screen
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_flight_watch AS
SELECT cf.case_id, dc.scenario_id,
       f.flight_id, f.flight_no, f.flight_kind, f.dep_iata, f.arr_iata AS planned_arr_iata,
       coalesce(s.actual_arr_iata, f.arr_iata) AS current_dest_iata,
       coalesce(s.registration, f.registration_planned) AS registration,
       s.status,
       f.std_utc, f.sta_utc, s.etd_utc, s.eta_utc, s.atd_utc, s.ata_utc,
       coalesce(s.eta_utc, f.sta_utc) AT TIME ZONE ap.tz AS eta_local_dest,
       floor(extract(epoch FROM coalesce(s.ata_utc, s.eta_utc, f.sta_utc) - f.sta_utc)/60)::int AS arr_delay_min,
       s.is_holding, s.holding_since_utc,
       cf.fog_exposure,
       -- crew
       (SELECT cm.full_name FROM crew_duty_leg l
          JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id AND ca.valid_to IS NULL
          JOIN crew_member cm ON cm.crew_id = ca.crew_id
         WHERE l.scenario_id = dc.scenario_id AND l.flight_id = f.flight_id AND l.is_active
           AND ca.position_code = 'CP' LIMIT 1) AS captain,
       cl.duty_id, cl.crew_status, cl.crew_margin_min, fmt_min(cl.crew_margin_min) AS crew_margin_hhmm,
       lvp.lvp_required, lvp.lvp_ok AS lvp_crew_ok, lvp.not_qualified AS lvp_not_qualified,
       cl.legal_end_utc, cl.discretion_end_utc, cl.binding_position, cl.legs_counted, cl.reasons AS crew_reasons,
       -- agent recommendation
       rec.rec_id, rec.rec_type AS recommendation, rec.alternate_iata AS recommended_alternate,
       rec.confidence, rec.status AS recommendation_status, rec.required_approver_role,
       -- human decision
       dec.decision_id, dec.decision_type AS last_decision, dec.status AS decision_status,
       dec.decided_by_name, dec.decided_at,
       -- diversion / latest departure (onward leg if diverted)
       dv.alternate_iata AS diverted_to, dv.waiting_for, dv.status AS diversion_status,
       dv.recovery_flight_id,
       ld.latest_legal_offblocks_utc, ld.latest_with_discretion_utc, ld.operational_target_utc,
       -- evaluated against the scenario clock at read time, not frozen at calculation time
       CASE WHEN ld.calc_id IS NULL THEN NULL
            WHEN scenario_now(dc.scenario_id) > ld.latest_with_discretion_utc THEN 'EXCEEDED'
            WHEN scenario_now(dc.scenario_id) > ld.latest_legal_offblocks_utc THEN 'DISCRETION_REQUIRED'
            ELSE ld.status::text END AS departure_legality,
       floor(extract(epoch FROM ld.latest_legal_offblocks_utc - scenario_now(dc.scenario_id))/60)::int
            AS minutes_to_latest_legal_departure,
       ld.from_iata AS departure_from_iata,
       ld.latest_legal_offblocks_utc AT TIME ZONE dap.tz AS latest_legal_offblocks_local,
       -- ownership + freshness + exceptions
       ou.display_name AS owner, cf.owner_role,
       s.last_received_at AS last_update_utc,
       floor(extract(epoch FROM scenario_now(dc.scenario_id) - s.last_received_at)/60)::int AS data_age_min,
       (SELECT count(*) FROM data_exception x
         WHERE x.status <> 'RESOLVED'
           AND ((x.entity_type = 'flight' AND x.entity_id = f.flight_id::text)
             OR (x.entity_type = 'crew_duty' AND x.entity_id = cl.duty_id::text)
             OR (x.entity_type = 'crew_assignment' AND x.detail->>'duty_id' = cl.duty_id::text))) AS open_exceptions
  FROM case_flight cf
  JOIN disruption_case dc ON dc.case_id = cf.case_id
  JOIN flight f ON f.flight_id = cf.flight_id
  JOIN airport ap ON ap.iata = f.arr_iata
  LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = dc.scenario_id
  LEFT JOIN v_flight_crew_legality cl ON cl.flight_id = f.flight_id AND cl.scenario_id = dc.scenario_id
  LEFT JOIN LATERAL flight_lvp_check(dc.scenario_id, coalesce(
        (SELECT dv0.recovery_flight_id FROM diversion dv0
          WHERE dv0.original_flight_id = f.flight_id AND dv0.scenario_id = dc.scenario_id), f.flight_id)) lvp ON TRUE
  LEFT JOIN LATERAL (
        SELECT r.rec_id, r.rec_type, o.alternate_iata, r.confidence, r.status, r.required_approver_role
          FROM recommendation r
          LEFT JOIN recommendation_option o ON o.rec_id = r.rec_id AND o.rank = 1
         WHERE r.flight_id = f.flight_id AND r.scenario_id = dc.scenario_id
           AND r.status IN ('PROPOSED','ACCEPTED')
         ORDER BY r.generated_at DESC LIMIT 1) rec ON TRUE
  LEFT JOIN LATERAL (
        SELECT d.decision_id, d.decision_type, d.status, u.display_name AS decided_by_name, d.decided_at
          FROM decision d JOIN app_user u ON u.user_id = d.decided_by
         WHERE d.flight_id = f.flight_id AND d.scenario_id = dc.scenario_id
         ORDER BY d.decided_at DESC LIMIT 1) dec ON TRUE
  LEFT JOIN diversion dv ON dv.original_flight_id = f.flight_id AND dv.scenario_id = dc.scenario_id
  LEFT JOIN LATERAL (
        SELECT * FROM latest_departure_calc x
         WHERE x.scenario_id = dc.scenario_id AND x.is_current
           AND x.flight_id = coalesce(dv.recovery_flight_id, f.flight_id)
         ORDER BY x.calculated_at DESC LIMIT 1) ld ON TRUE
  LEFT JOIN airport dap ON dap.iata = ld.from_iata
  LEFT JOIN app_user ou ON ou.user_id = cf.owner_user_id;

-- ---------------------------------------------------------------------
-- Q1: Which crew runs out of legality next?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_crew_legality_ranking AS
SELECT fc.scenario_id, fc.crew_id, cm.full_name, fc.position_code, fc.duty_id,
       EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = fc.crew_id AND q.qual_code = 'LVP') AS lvp_qualified,
       (SELECT string_agg(fl.flight_no || ' ' || fl.dep_iata || '-' || fl.arr_iata, ' / ' ORDER BY l.leg_seq)
          FROM crew_duty_leg l JOIN flight fl ON fl.flight_id = l.flight_id
         WHERE l.scenario_id = fc.scenario_id AND l.duty_id = fc.duty_id AND l.is_active) AS duty_legs,
       fc.sign_in_utc, fc.band_tz, fc.sign_in_local_time, fc.legs_counted,
       fc.max_fdp_min, fmt_min(fc.max_fdp_min) AS max_fdp_hhmm,
       fc.legal_end_utc, fc.legal_end_utc AT TIME ZONE 'Asia/Dubai' AS legal_end_shj_local,
       fc.discretion_end_utc, fc.projected_end_utc,
       fc.margin_min, fmt_min(fc.margin_min) AS margin_hhmm,
       floor(extract(epoch FROM fc.legal_end_utc - scenario_now(fc.scenario_id))/60)::int AS minutes_until_legal_end,
       fc.status, fc.reasons, fc.inputs->>'rule_set' AS rule_set, fc.inputs->>'source_rule_id' AS rule_ref,
       fc.inputs->>'band' AS band, fc.calculated_at,
       -- TB-3: before sign-in the crew is not "using" time; show "duty starts HH:MMZ", not a countdown
       (fc.sign_in_utc <= scenario_now(fc.scenario_id)) AS duty_started
  FROM fdp_calculation fc JOIN crew_member cm ON cm.crew_id = fc.crew_id
 WHERE fc.is_current AND fc.crew_id IS NOT NULL
   AND coalesce(fc.inputs->>'projected_end_basis', '') <> 'ACTUAL';     -- duty still running

-- ---------------------------------------------------------------------
-- Q2: Where is aircraft X and what is it waiting for?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_aircraft_whereabouts AS
WITH fs AS (
    SELECT s.scenario_id, coalesce(s.registration, f.registration_planned) AS registration,
           f.flight_id, f.flight_no, f.dep_iata, f.arr_iata, s.actual_arr_iata, s.status,
           f.std_utc, s.etd_utc, s.eta_utc, s.atd_utc, s.ata_utc, s.is_holding,
           coalesce(s.atd_utc, s.etd_utc, f.std_utc) AS order_ts, s.last_received_at
      FROM flight_state s JOIN flight f ON f.flight_id = s.flight_id
     WHERE coalesce(s.registration, f.registration_planned) IS NOT NULL
       AND s.status <> 'CANCELLED'
), cur AS (
    -- in progress, otherwise the last completed flight
    SELECT DISTINCT ON (scenario_id, registration) *
      FROM fs
     WHERE status IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING','LANDED','ON_BLOCKS')
       AND order_ts <= scenario_now(scenario_id)
     ORDER BY scenario_id, registration, order_ts DESC
)
SELECT c.scenario_id, c.registration,
       CASE WHEN c.status IN ('AIRBORNE','HOLDING','DIVERTING')
                 THEN format('In the air on %s %s-%s%s', c.flight_no, c.dep_iata, coalesce(c.actual_arr_iata, c.arr_iata),
                             CASE WHEN c.status = 'HOLDING' THEN ' (holding)'
                                  WHEN c.status = 'DIVERTING' THEN ' (diverting)' ELSE '' END)
            WHEN c.status = 'TAXI_OUT' THEN format('Taxiing at %s for %s', c.dep_iata, c.flight_no)
            ELSE format('On ground at %s', coalesce(c.actual_arr_iata, c.arr_iata)) END AS position_text,
       CASE WHEN c.status IN ('ON_BLOCKS','LANDED') THEN coalesce(c.actual_arr_iata, c.arr_iata) END AS on_ground_at,
       c.flight_no AS current_or_last_flight, c.status AS last_status, c.eta_utc,
       floor(extract(epoch FROM scenario_now(c.scenario_id) - c.last_received_at)/60)::int AS data_age_min,
       (c.status IN ('TAXI_OUT','AIRBORNE','HOLDING','DIVERTING')
        AND scenario_now(c.scenario_id) > coalesce(c.eta_utc, c.order_ts) + interval '30 minutes') AS position_unverified,
       dv.diversion_id, dv.alternate_iata AS diverted_at, dv.recovery_flight_id,
       CASE WHEN dv.diversion_id IS NOT NULL AND dv.status NOT IN ('DEPARTED','CLOSED','CANCELLED')
                 THEN dv.waiting_for
            WHEN c.status = 'HOLDING' THEN 'HUB_REOPENING'
            WHEN c.status IN ('AIRBORNE','DIVERTING') THEN 'LANDING'
            WHEN nx.flight_id IS NOT NULL AND coalesce(nx.etd_utc, nx.std_utc) > nx.std_utc THEN 'DELAYED_DEPARTURE'
            WHEN nx.flight_id IS NOT NULL THEN 'NEXT_DEPARTURE'
            ELSE 'NOTHING' END AS waiting_for,
       nx.flight_no AS next_flight, nx.dep_iata AS next_dep, nx.arr_iata AS next_arr,
       coalesce(nx.etd_utc, nx.std_utc) AS next_departure_utc,
       ld.latest_legal_offblocks_utc AS next_latest_legal_departure_utc,
       ld.operational_target_utc AS next_operational_target_utc
  FROM cur c
  LEFT JOIN diversion dv ON dv.scenario_id = c.scenario_id AND dv.original_flight_id = c.flight_id
  LEFT JOIN LATERAL (
        SELECT f2.flight_id, f2.flight_no, f2.dep_iata, f2.arr_iata, f2.std_utc, s2.etd_utc
          FROM flight f2 JOIN flight_state s2 ON s2.flight_id = f2.flight_id AND s2.scenario_id = c.scenario_id
         WHERE coalesce(s2.registration, f2.registration_planned) = c.registration
           AND s2.status = 'SCHEDULED' AND f2.std_utc >= c.std_utc AND f2.flight_id <> c.flight_id
         ORDER BY coalesce(s2.etd_utc, f2.std_utc) LIMIT 1) nx ON TRUE
  LEFT JOIN latest_departure_calc ld ON ld.scenario_id = c.scenario_id AND ld.is_current
       AND ld.flight_id = nx.flight_id;

-- ---------------------------------------------------------------------
-- Decisions with approvals (shared decision record)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_decision_log AS
SELECT d.decision_id, d.scenario_id, d.case_id, d.flight_id, f.flight_no, d.decision_type, d.alternate_iata,
       d.target_time_utc, d.status, d.followed_recommendation, d.rec_id, d.rationale,
       u.display_name AS decided_by, d.decided_role, d.decided_at, d.executed_at,
       (SELECT jsonb_agg(jsonb_build_object('by', au.display_name, 'role', a.approver_role,
                                            'verdict', a.verdict, 'comment', a.comment, 'at', a.approved_at)
                         ORDER BY a.approved_at)
          FROM decision_approval a JOIN app_user au ON au.user_id = a.approver_id
         WHERE a.decision_id = d.decision_id) AS approvals,
       d.revoke_reason, d.details
  FROM decision d JOIN app_user u ON u.user_id = d.decided_by
  LEFT JOIN flight f ON f.flight_id = d.flight_id;

CREATE OR REPLACE VIEW v_recovery_plan_current AS
SELECT p.plan_id, p.scenario_id, p.case_id, p.reopening_utc, p.window_end_utc, p.capacity_per_hr,
       p.arrivals_in_window, p.status AS plan_status, i.rank, f.flight_no, f.dep_iata, f.arr_iata,
       i.current_location, i.earliest_arrival_utc, i.proposed_slot_utc,
       i.proposed_slot_utc AT TIME ZONE 'Asia/Dubai' AS proposed_slot_shj_local,
       i.within_window, i.is_feasible, i.priority_score, i.score_breakdown, i.reasons, i.infeasible_reason
  FROM recovery_plan p
  JOIN recovery_plan_item i ON i.plan_id = p.plan_id
  JOIN flight f ON f.flight_id = i.flight_id
 WHERE p.status IN ('PROPOSED','APPROVED');

-- ---------------------------------------------------------------------
-- One chronological, cross-team timeline per case
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_case_timeline AS
-- decisions, recommendations, diversions, comments, plans (audited with case_id)
SELECT al.case_id, coalesce(al.scenario_time_utc, al.occurred_at) AS occurred_at, 'AUDIT' AS stream, u.display_name AS actor, al.actor_role,
       al.entity_type, al.entity_id, al.action,
       CASE al.entity_type
         WHEN 'decision' THEN format('%s %s decision %s (%s)', al.action,
                                     al.after_data->>'decision_type', al.entity_id, al.after_data->>'status')
         WHEN 'recommendation' THEN format('Recommendation %s for flight %s: %s',
                                     al.after_data->>'rec_type', al.after_data->>'flight_id', al.after_data->>'status')
         WHEN 'diversion' THEN format('Diversion to %s: %s, waiting for %s', al.after_data->>'alternate_iata',
                                     al.after_data->>'status', al.after_data->>'waiting_for')
         WHEN 'case_comment' THEN 'Comment: ' || left(al.after_data->>'body', 140)
         WHEN 'recovery_plan' THEN format('Recovery plan %s %s%s', al.entity_id, al.after_data->>'status',
                                     coalesce(': ' || (al.after_data->>'arrivals_in_window') || ' arrivals fit the window', ''))
         WHEN 'case_flight' THEN format('Flight %s added to watch (%s exposure)', al.entity_id, al.after_data->>'fog_exposure')
         WHEN 'crew_replacement' THEN format('Crew replacement: %s out, %s in (%s)', al.after_data->>'outgoing_crew_id',
                                     al.after_data->>'incoming_crew_id', al.after_data->>'status')
         ELSE al.entity_type || ' ' || al.action END AS summary,
       al.changed_fields, al.audit_id AS ref_id
  FROM audit_log al LEFT JOIN app_user u ON u.user_id = al.actor_user_id
 WHERE al.case_id IS NOT NULL AND al.entity_type <> 'decision_approval'
   -- hide bookkeeping-only updates
   AND NOT (al.action = 'UPDATE' AND al.changed_fields <@ ARRAY['superseded_by','arrivals_in_window','updated_at'])
UNION ALL
-- decision approvals (no case_id on the row itself)
SELECT d.case_id, a.approved_at, 'APPROVAL', u.display_name, a.approver_role, 'decision_approval',
       a.approval_id::text, a.verdict,
       format('%s %s decision %s%s', a.verdict, d.decision_type, d.decision_id,
              coalesce(': ' || a.comment, '')), NULL, a.approval_id
  FROM decision_approval a JOIN decision d ON d.decision_id = a.decision_id
  JOIN app_user u ON u.user_id = a.approver_id
UNION ALL
-- feed events for flights on the case watch list
SELECT cf.case_id, fe.event_ts, 'FEED', fe.source_code, NULL, 'flight_event', fe.event_id::text,
       fe.event_type,
       format('%s %s: %s [%s]', f.flight_no, fe.event_type,
              (SELECT string_agg(k || '=' || (fe.payload->>k), ', ') FROM unnest(fe.fields_applied) k),
              fe.apply_result), fe.fields_applied, fe.event_id
  FROM flight_event fe
  JOIN case_flight cf ON cf.flight_id = fe.flight_id
  JOIN disruption_case dc ON dc.case_id = cf.case_id AND dc.scenario_id = fe.scenario_id
  JOIN flight f ON f.flight_id = fe.flight_id
 WHERE fe.event_type <> 'BASELINE'
UNION ALL
-- airport status changes in the case scenario
SELECT dc.case_id, ase.effective_from_utc, 'AIRPORT', u.display_name, NULL, 'airport_status_event',
       ase.status_event_id::text, ase.op_status::text,
       format('%s %s%s%s%s%s', ase.iata, ase.op_status, coalesce(' - ' || ase.reason, ''),
              CASE WHEN ase.lvp_in_force THEN ', LVP in force' ELSE '' END,
              coalesce(', arrivals ' || ase.arrival_capacity_per_hr || '/hr', ''),
              coalesce(', reopen ~' || to_char(ase.expected_reopen_utc AT TIME ZONE 'UTC', 'HH24:MI"Z"'), '')),
       NULL, ase.status_event_id
  FROM airport_status_event ase
  JOIN disruption_case dc ON dc.scenario_id = ase.scenario_id
  LEFT JOIN app_user u ON u.user_id = ase.entered_by
UNION ALL
-- crew changes on duties that operate case flights
SELECT DISTINCT cf.case_id, coalesce(al.scenario_time_utc, al.occurred_at), 'CREW', u.display_name, al.actor_role, 'crew_assignment',
       al.entity_id, al.action,
       format('Crew %s %s on duty %s%s', al.after_data->>'crew_id',
              CASE WHEN al.after_data->>'valid_to' IS NOT NULL THEN 'removed' ELSE 'assigned' END,
              al.after_data->>'duty_id', coalesce(' - ' || (al.after_data->>'change_reason'), '')),
       al.changed_fields, al.audit_id
  FROM audit_log al
  JOIN crew_duty_leg l ON l.duty_id = (al.after_data->>'duty_id')::bigint AND l.scenario_id = al.scenario_id
  JOIN case_flight cf ON cf.flight_id = l.flight_id
  JOIN disruption_case dc ON dc.case_id = cf.case_id AND dc.scenario_id = al.scenario_id
  LEFT JOIN app_user u ON u.user_id = al.actor_user_id
 WHERE al.entity_type = 'crew_assignment' AND al.actor_user_id IS NOT NULL
   AND (al.action <> 'INSERT' OR al.after_data->>'source' <> 'DUTY_SHEET');

-- Passenger connections at risk: projected connection time per scenario.
-- Minimum connection time 40 min = smallest scheduled connection in the supplied data (assumption).
CREATE OR REPLACE VIEW v_connection_risk AS
WITH c AS (
    SELECT si.scenario_id, pc.*, fi.flight_no AS inbound_flight, fi.dep_iata AS inbound_from,
           fo.flight_no AS outbound_flight, fo.arr_iata AS outbound_to,
           coalesce(si.ata_utc, si.eta_utc, fi.sta_utc) AS inbound_arrival_utc,
           coalesce(so.atd_utc, so.etd_utc, fo.std_utc) AS outbound_departure_utc,
           si.status AS inbound_status, si.actual_arr_iata, so.status AS outbound_status, so.atd_utc AS outbound_atd
      FROM pax_connection pc
      JOIN flight fi ON fi.flight_id = pc.inbound_flight_id
      JOIN flight fo ON fo.flight_id = pc.outbound_flight_id
      JOIN flight_state si ON si.flight_id = pc.inbound_flight_id
      LEFT JOIN flight_state so ON so.flight_id = pc.outbound_flight_id AND so.scenario_id = si.scenario_id
)
SELECT scenario_id, inbound_flight_id, inbound_flight, inbound_from, outbound_flight_id, outbound_flight, outbound_to,
       connection_iata, pax_count, source_view, sched_connection_min,
       inbound_arrival_utc, outbound_departure_utc,
       floor(extract(epoch FROM outbound_departure_utc - inbound_arrival_utc) / 60)::int AS projected_connection_min,
       CASE WHEN actual_arr_iata IS NOT NULL AND actual_arr_iata <> connection_iata THEN 'INBOUND_DIVERTED'
            WHEN inbound_status = 'CANCELLED' OR outbound_status = 'CANCELLED' THEN 'CANCELLED'
            WHEN outbound_atd IS NOT NULL AND outbound_atd < inbound_arrival_utc THEN 'MISSED'
            WHEN outbound_departure_utc - inbound_arrival_utc < interval '0 minutes' THEN 'MISSED'
            WHEN outbound_departure_utc - inbound_arrival_utc < interval '40 minutes' THEN 'AT_RISK'
            ELSE 'OK' END AS connection_status
  FROM c;

CREATE OR REPLACE VIEW v_open_exceptions AS
SELECT exception_id, scenario_id, entity_type, entity_id, code, severity, message, detail, status, raised_at
  FROM data_exception WHERE status <> 'RESOLVED'
 ORDER BY CASE severity WHEN 'BLOCKING' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, raised_at DESC;

-- Options panel: every ranked option of the open/accepted recommendation per flight
CREATE OR REPLACE VIEW v_recommendation_options AS
SELECT r.scenario_id, r.case_id, r.flight_id, f.flight_no, r.rec_id, r.rec_type, r.status AS rec_status,
       r.confidence, r.rationale, r.generated_by, r.generated_at,
       o.rank, o.action, o.alternate_iata, a.name AS alternate_name, o.is_executable, o.score,
       o.est_arrival_utc, o.hold_until_utc, o.fuel_margin_min, o.crew_margin_min,
       o.blocking_constraints, o.reasons,
       EXISTS (SELECT 1 FROM jsonb_array_elements(o.blocking_constraints) b WHERE (b->>'verify')::boolean)
           AS needs_verification
  FROM recommendation r
  JOIN recommendation_option o ON o.rec_id = r.rec_id
  JOIN flight f ON f.flight_id = r.flight_id
  LEFT JOIN airport a ON a.iata = o.alternate_iata
 WHERE r.status IN ('PROPOSED','ACCEPTED');
