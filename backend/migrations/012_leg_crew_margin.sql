-- 012: crew margin per LEG instead of per duty.
--
-- Until now v_flight_crew_legality copied the duty-level result onto every flight of the duty. That result is measured at the
-- duty's LAST leg, so leg 1 of a three-leg duty showed the margin of leg 3, and the "Crew at risk" tile counted every leg of an
-- at-risk duty.
--
-- Now, for each flight (leg):
--   crew_margin_min  = duty legal end - THIS leg's own projected on-blocks   (the legal end keeps the planned sector count,
--                                                                             so it is still the real FDP limit)
--   crew_status      = EXCEEDED / DISCRETION_REQUIRED / AT_RISK / LEGAL from that margin, using rule_set.at_risk_threshold_min
--                      VERIFICATION_REQUIRED from the duty is kept: missing or conflicting input never becomes a legality claim.
-- The duty values stay available as duty_status / duty_margin_min / duty_projected_end_utc.
--
-- v_flight_watch, /flights, the board filters, v_disruption_kpis and the "Crew at risk" tile read crew_status / crew_margin_min
-- from this view, so they follow without change. Existing columns keep their names, types and order; new ones are appended.

CREATE OR REPLACE VIEW v_flight_crew_legality AS
SELECT DISTINCT ON (x.scenario_id, x.flight_id)
       x.scenario_id, x.flight_id, x.duty_id, x.calc_id, x.binding_crew_id, x.binding_position,
       x.leg_status AS crew_status, x.leg_margin_min AS crew_margin_min,
       x.legal_end_utc, x.discretion_end_utc, x.projected_end_utc, x.legs_counted, x.max_fdp_min,
       x.reasons, x.calculated_at,
       x.duty_status, x.duty_margin_min, x.leg_projected_end_utc, x.leg_discretion_margin_min
  FROM (
    SELECT fc.scenario_id, l.flight_id, fc.duty_id, fc.calc_id,
           (fc.inputs->>'binding_crew_id')::int AS binding_crew_id,
           fc.position_code AS binding_position,
           fc.legal_end_utc, fc.discretion_end_utc, fc.projected_end_utc, fc.legs_counted, fc.max_fdp_min,
           fc.reasons, fc.calculated_at,
           fc.status AS duty_status, fc.margin_min AS duty_margin_min,
           pb.ts AS leg_projected_end_utc,
           CASE WHEN pb.ts IS NOT NULL AND fc.legal_end_utc IS NOT NULL
                THEN floor(extract(epoch FROM fc.legal_end_utc - pb.ts) / 60)::int END AS leg_margin_min,
           CASE WHEN pb.ts IS NOT NULL AND fc.discretion_end_utc IS NOT NULL
                THEN floor(extract(epoch FROM fc.discretion_end_utc - pb.ts) / 60)::int END AS leg_discretion_margin_min,
           CASE WHEN fc.status = 'VERIFICATION_REQUIRED'                         THEN fc.status
                WHEN pb.ts IS NULL OR fc.legal_end_utc IS NULL
                     OR fc.discretion_end_utc IS NULL                              THEN fc.status
                WHEN fc.discretion_end_utc < pb.ts                                THEN 'EXCEEDED'::legality_status
                WHEN fc.legal_end_utc < pb.ts                                     THEN 'DISCRETION_REQUIRED'::legality_status
                WHEN fc.legal_end_utc - pb.ts < make_interval(mins => rs.at_risk_threshold_min)
                                                                                   THEN 'AT_RISK'::legality_status
                ELSE 'LEGAL'::legality_status END AS leg_status
      FROM crew_duty_leg l
      JOIN fdp_calculation fc ON fc.duty_id = l.duty_id AND fc.scenario_id = l.scenario_id
                             AND fc.is_current AND fc.crew_id IS NULL
      JOIN rule_set rs ON rs.rule_set_id = fc.rule_set_id
      CROSS JOIN LATERAL projected_on_blocks(l.scenario_id, l.flight_id) pb
     WHERE l.is_active
  ) x
 ORDER BY x.scenario_id, x.flight_id, x.leg_margin_min ASC NULLS FIRST;
