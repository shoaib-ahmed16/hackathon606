-- =====================================================================
-- Final-challenge replay on real 21 Nov flights (run after the loader)
--   psql -d fogops -f 05_demo_fog_replay.sql
-- Every step uses the same functions/tables the API would call, so this
-- doubles as an end-to-end test and as a reference for the backend.
-- Fog is SIMULATED; all flight/crew data comes from the supplied files.
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path = fogops, public;
\pset pager off

-- user ids
SELECT user_id AS occ      FROM app_user WHERE username = 'occ.dm'      \gset
SELECT user_id AS disp     FROM app_user WHERE username = 'dispatch.1'  \gset
SELECT user_id AS crewctl  FROM app_user WHERE username = 'crew.ctl.1'  \gset
SELECT user_id AS rkt      FROM app_user WHERE username = 'station.rkt' \gset
SELECT user_id AS agent    FROM app_user WHERE username = 'agent'       \gset

\echo '=== 1. Replay scenario cloned from LIVE, clock 21 Nov 01:15Z (05:15 SHJ local)'
BEGIN;
SELECT set_actor(:occ);
SELECT clone_scenario(1, 'FOG_REPLAY_21NOV_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS'), 'REPLAY') AS scn \gset
UPDATE scenario SET sim_clock_utc = '2026-11-21 01:15Z' WHERE scenario_id = :scn;
INSERT INTO disruption_case (scenario_id, title, hub_iata, phase, opened_by)
VALUES (:scn, 'SHJ fog 21 Nov 2026 (replay)', 'SHJ', 'RESTRICTED', :occ) RETURNING case_id AS cid \gset
COMMIT;

-- flights under watch
SELECT flight_id AS f588 FROM flight WHERE flight_no = 'G9588' AND flight_date = '2026-11-20' AND dep_iata = 'CMB' \gset
SELECT flight_id AS f464 FROM flight WHERE flight_no = 'G9464' AND flight_date = '2026-11-20' AND dep_iata = 'DEL' \gset
SELECT flight_id AS f455 FROM flight WHERE flight_no = 'G9455' AND flight_date = '2026-11-20' AND dep_iata = 'CCJ' \gset
SELECT flight_id AS f621 FROM flight WHERE flight_no = 'G9621' AND flight_date = '2026-11-20' AND dep_iata = 'CAI' \gset
SELECT flight_id AS f472 FROM flight WHERE flight_no = 'G9472' AND flight_date = '2026-11-20' AND dep_iata = 'MAA' \gset

BEGIN;
SELECT set_actor(:occ);
INSERT INTO case_flight (case_id, flight_id, fog_exposure, owner_user_id, owner_role) VALUES
 (:cid, :f588, 'HIGH',   :disp, 'DISPATCH'),
 (:cid, :f464, 'HIGH',   :disp, 'DISPATCH'),
 (:cid, :f455, 'HIGH',   :disp, 'DISPATCH'),
 (:cid, :f621, 'MEDIUM', :disp, 'DISPATCH'),
 (:cid, :f472, 'MEDIUM', :disp, 'DISPATCH');
COMMIT;

\echo '=== 2. Simulated live feed: airborne + ETAs (incl. a duplicate and an out-of-order message)'
SELECT ingest_flight_event(:scn,'SIM_FEED','m-001',:f588,'POSITION','2026-11-21 01:10Z',
       '{"toff":"2026-11-20T21:30:00Z","atd":"2026-11-20T21:15:00Z","eta":"2026-11-21T01:55:00Z"}') AS r1,
       ingest_flight_event(:scn,'SIM_FEED','m-002',:f464,'POSITION','2026-11-21 01:10Z',
       '{"toff":"2026-11-20T22:05:00Z","atd":"2026-11-20T21:55:00Z","eta":"2026-11-21T01:55:00Z"}') AS r2,
       ingest_flight_event(:scn,'SIM_FEED','m-003',:f455,'POSITION','2026-11-21 01:10Z',
       '{"toff":"2026-11-20T22:25:00Z","atd":"2026-11-20T22:12:00Z","eta":"2026-11-21T02:10:00Z"}') AS r3,
       ingest_flight_event(:scn,'SIM_FEED','m-004',:f621,'POSITION','2026-11-21 01:10Z',
       '{"toff":"2026-11-20T23:20:00Z","atd":"2026-11-20T23:08:00Z","eta":"2026-11-21T02:15:00Z"}') AS r4,
       ingest_flight_event(:scn,'SIM_FEED','m-005',:f472,'POSITION','2026-11-21 01:10Z',
       '{"toff":"2026-11-20T22:30:00Z","atd":"2026-11-20T22:14:00Z","eta":"2026-11-21T02:30:00Z"}') AS r5;
SELECT ingest_flight_event(:scn,'SIM_FEED','m-005',:f472,'POSITION','2026-11-21 01:10Z','{}') AS duplicate_resend;
SELECT ingest_flight_event(:scn,'SIM_FEED','m-006',:f472,'POSITION','2026-11-21 01:05Z',
       '{"eta":"2026-11-21T02:20:00Z"}') AS older_eta_arrives_late;

\echo '=== 3. SHJ fog: restricted then closed (forecast reopening 02:30Z); alternates open'
BEGIN;
SELECT set_actor(:occ);
INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
       effective_from_utc, expected_reopen_utc, quality, entered_by, note) VALUES
 (:scn,'SHJ','RESTRICTED','FOG',300,TRUE,8,'2026-11-21 00:50Z','2026-11-21 02:30Z','MEASURED',:occ,'RVR dropping'),
 (:scn,'SHJ','CLOSED','FOG below CAT III minima',50,TRUE,0,'2026-11-21 01:12Z','2026-11-21 02:30Z','FORECAST',:occ,'Met forecast clearance 02:30Z');
INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, weather_above_minima,
       handling_ok, fuel_ok, effective_from_utc, quality, entered_by) VALUES
 (:scn,'RKT','OPEN',4,TRUE,TRUE,TRUE,'2026-11-21 01:00Z','MANUAL',:occ),
 (:scn,'FJR','OPEN',6,TRUE,TRUE,TRUE,'2026-11-21 01:00Z','MANUAL',:occ),
 (:scn,'AAN','OPEN',3,TRUE,TRUE,FALSE,'2026-11-21 01:00Z','MANUAL',:occ);
-- holding endurance (ESTIMATED: no live fuel feed is supplied). Long-haul flights carried extra fog fuel.
INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg,
       burn_rate_hold_kg_per_hr, est_holding_endurance_min, quality, basis, entered_by) VALUES
 (:scn,:f588,'2026-11-21 01:15Z',3300,2300,2400, 25,'ESTIMATED','{"from":"hist.fuel landing fuel CMB-SHJ; hold burn assumed"}',:disp),
 (:scn,:f464,'2026-11-21 01:15Z',4100,2300,2400, 45,'ESTIMATED','{"from":"hist.fuel landing fuel DEL-SHJ; hold burn assumed"}',:disp),
 (:scn,:f455,'2026-11-21 01:15Z',7100,2300,2400,120,'ESTIMATED','{"from":"flight plan extra fog fuel; hold burn assumed"}',:disp),
 (:scn,:f621,'2026-11-21 01:15Z',8300,2300,2400,150,'ESTIMATED','{"from":"flight plan extra fog fuel; hold burn assumed"}',:disp),
 (:scn,:f472,'2026-11-21 01:15Z',6700,2300,2400,110,'ESTIMATED','{"from":"flight plan extra fog fuel; hold burn assumed"}',:disp);
COMMIT;
SELECT ingest_flight_event(:scn,'SIM_FEED','m-007',:f464,'HOLD','2026-11-21 01:14Z','{"holding":true}') AS hold_464;

\echo '=== 4. Crew legality + LVP qualification for the watched flights (LVP in force at SHJ)'
SELECT compute_flight_legality(:scn, flight_id, 'fog_onset') FROM case_flight WHERE case_id = :cid;
SELECT flight_no, status, to_char(eta_utc,'HH24:MI"Z"') eta, crew_status, crew_margin_hhmm,
       to_char(legal_end_utc,'HH24:MI"Z"') legal_end, legs_counted, lvp_required, lvp_crew_ok,
       lvp_not_qualified->0->>'position' AS non_lvp_position
  FROM v_flight_watch WHERE case_id = :cid ORDER BY eta_utc;

\echo '=== 5. Engine-generated hold/divert recommendations (HOLD + every alternate, ranked)'
BEGIN;
SELECT set_actor(:agent);
SELECT propose_hold_or_divert(:scn, :cid, flight_id) FROM case_flight WHERE case_id = :cid ORDER BY flight_id;
COMMIT;
SELECT flight_no, rec_type, confidence, left(rationale, 110) AS rationale
  FROM v_recommendation_options WHERE case_id = :cid AND rank = 1 ORDER BY flight_no;
\echo '--- Ranked alternates for G9588 (CMB-SHJ): constraints, fuel, crew return legality'
SELECT rank, alt_iata, is_executable AS exec, score, op_status, stands_left, distance_km::int AS km, est_flight_min AS fl_min,
       fuel_margin_min AS fuel_m, return_block_min AS ret_blk, crew_outcome,
       (SELECT string_agg(x->>'code', ',') FROM jsonb_array_elements(blocking_constraints) x) AS blocking
  FROM rank_alternates(:scn, :f588) ORDER BY rank;
\echo '--- Options panel for G9455 (captain not LVP-qualified)'
SELECT rank, action, alternate_iata AS alt, is_executable AS exec, score, needs_verification AS verify,
       (SELECT string_agg(x->>'code', ',') FROM jsonb_array_elements(blocking_constraints) x) AS blocking
  FROM v_recommendation_options WHERE case_id = :cid AND flight_no = 'G9455' ORDER BY rank LIMIT 4;
SELECT rec_id AS rec588 FROM recommendation WHERE scenario_id = :scn AND flight_id = :f588 AND status = 'PROPOSED' \gset
SELECT rec_id AS rec464 FROM recommendation WHERE scenario_id = :scn AND flight_id = :f464 AND status = 'PROPOSED' \gset
SELECT alternate_iata AS alt588 FROM recommendation_option WHERE rec_id = :rec588 AND rank = 1 \gset
SELECT alternate_iata AS alt464 FROM recommendation_option WHERE rec_id = :rec464 AND rank = 1 \gset

\echo '=== 6. Guardrail check: the agent tries to record a decision (must fail)'
DO $$
BEGIN
    INSERT INTO fogops.decision (scenario_id, case_id, flight_id, decision_type, rationale, decided_by, decided_role)
    SELECT s.scenario_id, c.case_id, cf.flight_id, 'DIVERT', 'agent auto-divert', u.user_id, 'AGENT'
      FROM fogops.scenario s JOIN fogops.disruption_case c ON c.scenario_id = s.scenario_id
      JOIN fogops.case_flight cf ON cf.case_id = c.case_id, fogops.app_user u
     WHERE s.name LIKE 'FOG_REPLAY_21NOV%' AND u.username = 'agent' ORDER BY s.scenario_id DESC LIMIT 1;
    RAISE NOTICE 'UNEXPECTED: agent decision accepted';
EXCEPTION WHEN others THEN
    RAISE NOTICE 'Blocked as expected -> %', SQLERRM;
END $$;

\echo '=== 7. Dispatch accepts the engine''s top option for G9588 and G9464; OCC approves; both executed'
UPDATE scenario SET sim_clock_utc = '2026-11-21 01:20Z' WHERE scenario_id = :scn;
BEGIN;
SELECT set_actor(:disp);
INSERT INTO decision (scenario_id, case_id, flight_id, rec_id, option_id, decision_type, alternate_iata,
       followed_recommendation, rationale, decided_by, decided_role)
SELECT :scn, :cid, :f588, :rec588, option_id, 'DIVERT', alternate_iata, TRUE,
       'Agree with ranked option 1: holding fuel insufficient, SHJ closed; alternate stands confirmed by station.', :disp, 'DISPATCH'
  FROM recommendation_option WHERE rec_id = :rec588 AND rank = 1
RETURNING decision_id AS dec588 \gset
INSERT INTO decision (scenario_id, case_id, flight_id, rec_id, option_id, decision_type, alternate_iata,
       followed_recommendation, rationale, decided_by, decided_role)
SELECT :scn, :cid, :f464, :rec464, option_id, 'DIVERT', alternate_iata, TRUE,
       'Agree with ranked option 1: holding fuel runs out before forecast reopening.', :disp, 'DISPATCH'
  FROM recommendation_option WHERE rec_id = :rec464 AND rank = 1
RETURNING decision_id AS dec464 \gset
COMMIT;
BEGIN;
SELECT set_actor(:occ);
INSERT INTO decision_approval (decision_id, approver_id, approver_role, verdict, comment) VALUES
 (:dec588, :occ, 'OCC', 'APPROVED', 'Approved. Crew Control: check RKT-SHJ legality.'),
 (:dec464, :occ, 'OCC', 'APPROVED', 'Approved.');
SELECT execute_diversion(:dec588) AS div588 \gset
SELECT execute_diversion(:dec464) AS div464 \gset
COMMIT;
SELECT decision_id, flight_no, decision_type, alternate_iata, status, decided_by, approvals->0->>'by' AS approved_by
  FROM v_decision_log WHERE decision_id IN (:dec588, :dec464);

\echo '=== 8. Diversion adds a sector: crew limits shrink; latest legal departure from the alternates'
SELECT recovery_flight_id AS rf588 FROM diversion WHERE diversion_id = :div588 \gset
SELECT recovery_flight_id AS rf464 FROM diversion WHERE diversion_id = :div464 \gset
SELECT position_code, duty_legs, legs_counted, max_fdp_hhmm, to_char(legal_end_utc,'HH24:MI"Z"') legal_end,
       to_char(discretion_end_utc,'HH24:MI"Z"') with_discretion, margin_hhmm, status
  FROM v_crew_legality_ranking
 WHERE scenario_id = :scn AND (duty_legs LIKE '%G9588D%' OR duty_legs LIKE '%G9464D%') AND position_code IN ('CP','CS')
 ORDER BY duty_legs, position_code;
SELECT f.flight_no, ld.from_iata || '-' || ld.to_iata AS leg, ld.block_time_min, ld.block_time_basis,
       to_char(ld.latest_legal_offblocks_utc,'HH24:MI"Z"') latest_legal,
       to_char(ld.latest_with_discretion_utc,'HH24:MI"Z"') latest_w_discretion,
       to_char(ld.operational_target_utc,'HH24:MI"Z"') ops_target, ld.status
  FROM latest_departure_calc ld JOIN flight f ON f.flight_id = ld.flight_id
 WHERE ld.scenario_id = :scn AND ld.flight_id IN (:rf588, :rf464) AND ld.is_current;

\echo '=== 9. Stations report arrivals at the alternates'
SELECT user_id AS st588 FROM app_user WHERE station_iata = :'alt588' AND role_code = 'STATION' LIMIT 1 \gset
SELECT user_id AS st464 FROM app_user WHERE station_iata = :'alt464' AND role_code = 'STATION' LIMIT 1 \gset
UPDATE scenario SET sim_clock_utc = '2026-11-21 02:05Z' WHERE scenario_id = :scn;
SELECT ingest_flight_event(:scn,'SIM_FEED','m-008',:f588,'IN','2026-11-21 01:52Z',
       '{"tdown":"2026-11-21T01:47:00Z","ata":"2026-11-21T01:52:00Z"}') AS landed_rkt,
       ingest_flight_event(:scn,'SIM_FEED','m-009',:f464,'IN','2026-11-21 02:04Z',
       '{"holding":false,"tdown":"2026-11-21T01:59:00Z","ata":"2026-11-21T02:04:00Z"}') AS landed_fjr;
BEGIN;
SELECT set_actor(:st588);
UPDATE diversion SET landed_alt_utc = '2026-11-21 01:47Z', on_blocks_alt_utc = '2026-11-21 01:52Z',
       status = 'ON_GROUND_ALT', refuel_status = 'IN_PROGRESS', handling_status = 'DONE',
       waiting_for = 'FUEL', updated_by = :st588
 WHERE diversion_id = :div588;
INSERT INTO case_comment (case_id, flight_id, author_id, author_role, body)
VALUES (:cid, :f588, :st588, 'STATION', 'G9588 on blocks 01:52Z, refuelling, pax remain on board.');
COMMIT;
BEGIN;
SELECT set_actor(:st464);
UPDATE diversion SET landed_alt_utc = '2026-11-21 01:59Z', on_blocks_alt_utc = '2026-11-21 02:04Z',
       status = 'ON_GROUND_ALT', refuel_status = 'DONE', handling_status = 'DONE',
       waiting_for = 'HUB_REOPENING', updated_by = :st464
 WHERE diversion_id = :div464;
COMMIT;

\echo '=== 10. JUDGE CHANGE #1 - one inbound ETA changes (G9472 re-sequenced)'
UPDATE scenario SET sim_clock_utc = '2026-11-21 02:10Z' WHERE scenario_id = :scn;
SELECT ingest_flight_event(:scn,'SIM_FEED','m-010',:f472,'ETA_UPDATE','2026-11-21 02:10Z',
       '{"eta":"2026-11-21T02:55:00Z","holding":true}') AS eta_change;
SELECT job_id, reason, entity_id, detail->>'eta_before' eta_before, detail->>'eta_after' eta_after
  FROM reassessment_queue WHERE scenario_id = :scn AND reason = 'FLIGHT_CHANGED' ORDER BY job_id DESC LIMIT 1;
SELECT compute_flight_legality(:scn, :f472, 'eta_change') AS duties_recomputed;
SELECT flight_no, to_char(eta_utc,'HH24:MI"Z"') eta, crew_status, crew_margin_hhmm
  FROM v_flight_watch WHERE case_id = :cid AND flight_id = :f472;

\echo '=== 11. JUDGE CHANGE #2 - SHJ reopening revised 02:30Z -> 02:45Z; engine re-ranks the airborne flights'
BEGIN;
SELECT set_actor(:occ);
INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
       effective_from_utc, expected_reopen_utc, quality, entered_by, note)
VALUES (:scn,'SHJ','CLOSED','FOG',50,TRUE,0,'2026-11-21 02:10Z','2026-11-21 02:45Z','FORECAST',:occ,'Clearance revised by Met');
SELECT set_actor(:agent);
SELECT propose_hold_or_divert(:scn, :cid, cf.flight_id) FROM case_flight cf
  JOIN flight_state fs ON fs.flight_id = cf.flight_id AND fs.scenario_id = :scn
 WHERE cf.case_id = :cid AND fs.status IN ('AIRBORNE','HOLDING');
COMMIT;
SELECT f.flight_no, r.rec_id, r.rec_type, r.status, r.superseded_by, left(r.rationale, 90) AS rationale
  FROM recommendation r JOIN flight f ON f.flight_id = r.flight_id
 WHERE r.scenario_id = :scn AND r.flight_id IN (:f455, :f472, :f621) ORDER BY f.flight_no, r.rec_id;

\echo '=== 12. JUDGE CHANGE #3 - crew pairing: G9588 crew time out at RKT -> standby replacements (Q4)'
UPDATE scenario SET sim_clock_utc = '2026-11-21 02:20Z' WHERE scenario_id = :scn;
SELECT duty_id AS d588 FROM crew_duty_leg WHERE scenario_id = :scn AND flight_id = :f588 LIMIT 1 \gset
SELECT leg_seq AS rseq FROM crew_duty_leg WHERE scenario_id = :scn AND duty_id = :d588 AND flight_id = :rf588 \gset
\echo '--- Q4 candidates for the captain position at RKT (G9588D lands at SHJ under LVP -> LVP required)'
SELECT crew_id, pattern_name, lvp_qualified, positioning_min, legs_to_operate, fmt_min(max_fdp_min) max_fdp,
       to_char(legal_end_utc,'HH24:MI"Z"') legal_end, fmt_min(margin_min) margin, roster_conflict, verdict
  FROM standby_candidates(:scn, :d588, 'CP', :'alt588', :rseq::smallint) ORDER BY verdict <> 'CANDIDATE', crew_id LIMIT 3;
SELECT crew_id, pattern_name, lvp_qualified, verdict
  FROM standby_candidates(:scn, :d588, 'CP', :'alt588', :rseq::smallint) WHERE NOT lvp_qualified LIMIT 2;
BEGIN;
SELECT set_actor(:crewctl);
INSERT INTO decision (scenario_id, case_id, flight_id, decision_type, rationale, decided_by, decided_role)
VALUES (:scn,:cid,:rf588,'CREW_REPLACE',
        'Operating crew exceed FDP before SHJ reopens; replace with standby crew positioned SHJ->RKT by road.',
        :crewctl,'CREW_CONTROL') RETURNING decision_id AS dec_crew \gset
INSERT INTO decision_approval (decision_id, approver_id, approver_role, verdict)
VALUES (:dec_crew, :crewctl, 'CREW_CONTROL', 'APPROVED');
-- replace every operating crew member who is no longer legal, with the best roster-safe candidate
DO $$
DECLARE
    v_scn INT := (SELECT max(scenario_id) FROM fogops.scenario WHERE name LIKE 'FOG_REPLAY_21NOV%');
    v_duty BIGINT; v_seq SMALLINT; v_dec BIGINT; v_case INT; a RECORD; c RECORD; v_alt CHAR(3);
BEGIN
    SELECT dv.alternate_iata INTO v_alt FROM fogops.diversion dv JOIN fogops.flight f ON f.flight_id = dv.original_flight_id
     WHERE dv.scenario_id = v_scn AND f.flight_no = 'G9588';
    SELECT l.duty_id INTO v_duty FROM fogops.crew_duty_leg l JOIN fogops.flight f ON f.flight_id = l.flight_id
     WHERE l.scenario_id = v_scn AND f.flight_no = 'G9588D' LIMIT 1;
    SELECT l.leg_seq INTO v_seq FROM fogops.crew_duty_leg l JOIN fogops.flight f ON f.flight_id = l.flight_id
     WHERE l.scenario_id = v_scn AND l.duty_id = v_duty AND f.flight_no = 'G9588D';
    SELECT decision_id, case_id INTO v_dec, v_case FROM fogops.decision
     WHERE scenario_id = v_scn AND decision_type = 'CREW_REPLACE' ORDER BY decision_id DESC LIMIT 1;
    FOR a IN SELECT fc.crew_id, fc.position_code FROM fogops.fdp_calculation fc
               JOIN fogops.crew_type ct ON ct.code = fc.position_code AND ct.gates_flight_legality
              WHERE fc.scenario_id = v_scn AND fc.duty_id = v_duty AND fc.is_current AND fc.crew_id IS NOT NULL
                AND fc.status IN ('DISCRETION_REQUIRED','EXCEEDED')
    LOOP
        SELECT * INTO c FROM fogops.standby_candidates(v_scn, v_duty, a.position_code, v_alt, v_seq)
         WHERE verdict = 'CANDIDATE' LIMIT 1;
        IF c.crew_id IS NULL THEN
            RAISE NOTICE 'No roster-safe standby for % % - stays flagged', a.position_code, a.crew_id;
            CONTINUE;
        END IF;
        PERFORM fogops.swap_crew(v_scn, v_duty, a.crew_id, c.crew_id,
                                 'Replacement at ' || v_alt || ' after diversion (decision ' || v_dec || ')',
                                 '2026-11-21 02:20Z', 'SHJ', v_seq, 'REPLACEMENT');
        INSERT INTO fogops.crew_replacement (scenario_id, case_id, duty_id, outgoing_crew_id, incoming_crew_id,
               standby_id, positioning_from_iata, positioning_to_iata, positioning_mode, positioning_min,
               new_sign_in_utc, decision_id, status)
        VALUES (v_scn, v_case, v_duty, a.crew_id, c.crew_id, c.standby_id, 'SHJ', v_alt, 'ROAD', c.positioning_min,
                '2026-11-21 02:20Z', v_dec, 'APPROVED');
    END LOOP;
END $$;
UPDATE diversion SET waiting_for = 'REPLACEMENT_CREW', updated_by = :crewctl WHERE diversion_id = :div588;
UPDATE decision SET status = 'EXECUTED' WHERE decision_id = :dec_crew;
COMMIT;
SELECT count(*) AS crew_replaced FROM crew_replacement WHERE scenario_id = :scn;
SELECT compute_latest_departure(:scn, :rf588) IS NOT NULL AS recalculated;

\echo '=== 13. The duty manager''s questions at 02:30Z (from the screen views alone)'
UPDATE scenario SET sim_clock_utc = '2026-11-21 02:30Z' WHERE scenario_id = :scn;
\echo '--- Q1 Which crew runs out of legality next?'
SELECT full_name, position_code, duty_legs, to_char(legal_end_utc,'HH24:MI"Z"') legal_end,
       minutes_until_legal_end, margin_hhmm, status
  FROM v_crew_legality_ranking WHERE scenario_id = :scn
   AND duty_id IN (SELECT l.duty_id FROM crew_duty_leg l JOIN case_flight cf ON cf.flight_id = l.flight_id
                    WHERE cf.case_id = :cid AND l.scenario_id = :scn)
   AND position_code IN ('CP','FO')
 ORDER BY minutes_until_legal_end NULLS FIRST LIMIT 5;
\echo '--- Q2 Where is the G9588 aircraft and what is it waiting for?'
SELECT registration, position_text, waiting_for, next_flight, to_char(next_latest_legal_departure_utc,'HH24:MI"Z"') next_latest_legal
  FROM v_aircraft_whereabouts WHERE scenario_id = :scn
   AND registration = (SELECT registration FROM flight_state WHERE scenario_id = :scn AND flight_id = :f588);
\echo '--- Q3 What time must it leave to still land legal?'
SELECT flight_no, diverted_to, lvp_crew_ok, to_char(latest_legal_offblocks_utc,'HH24:MI"Z"') latest_legal_utc,
       latest_legal_offblocks_local::time AS latest_legal_local, to_char(operational_target_utc,'HH24:MI"Z"') ops_target,
       minutes_to_latest_legal_departure AS mins_left, departure_legality
  FROM v_flight_watch WHERE case_id = :cid AND diverted_to IS NOT NULL;

\echo '=== 14. SHJ reopens 02:45Z at 12 arrivals/hr -> recovery order for the next 60 min'
UPDATE scenario SET sim_clock_utc = '2026-11-21 02:45Z' WHERE scenario_id = :scn;
BEGIN;
SELECT set_actor(:occ);
INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
       effective_from_utc, quality, entered_by)
VALUES (:scn,'SHJ','OPEN','Fog lifting',800,TRUE,12,'2026-11-21 02:45Z','MEASURED',:occ);
UPDATE diversion SET waiting_for = 'ARRIVAL_SLOT', status = 'READY', refuel_status = 'DONE' WHERE case_id = :cid;
UPDATE disruption_case SET phase = 'RECOVERY' WHERE case_id = :cid;
COMMIT;
SELECT set_actor(:agent);
SELECT build_recovery_plan(:scn, :cid, 60) AS plan \gset
SELECT rank, flight_no, current_location, to_char(earliest_arrival_utc,'HH24:MI"Z"') earliest,
       to_char(proposed_slot_utc,'HH24:MI"Z"') slot, proposed_slot_shj_local::time AS slot_local,
       within_window AS in_window, is_feasible AS feasible, priority_score AS score, reasons, infeasible_reason
  FROM v_recovery_plan_current WHERE plan_id = :plan ORDER BY rank;
SELECT arrivals_in_window, capacity_per_hr, to_char(window_start_utc,'HH24:MI"Z"') || '-' || to_char(window_end_utc,'HH24:MI"Z"') AS window
  FROM recovery_plan WHERE plan_id = :plan;

\echo '=== 15. Shared timeline (scenario clock) + report'
SELECT to_char(occurred_at,'HH24:MI') t, stream, actor, summary FROM v_case_timeline
 WHERE case_id = :cid ORDER BY occurred_at, ref_id;
SELECT generate_report(:cid, :occ) AS report_id \gset
SELECT report_id, jsonb_array_length(content->'flights') flights, jsonb_array_length(content->'decisions') decisions,
       jsonb_array_length(content->'timeline') timeline_rows, content->>'rule_set' rule_set, audit_watermark_id
  FROM report WHERE report_id = :report_id;

\echo '=== 16. Guardrail check: approved rule set is immutable'
DO $$
BEGIN
    UPDATE fogops.fdp_rule SET max_fdp_min = max_fdp_min + 60 WHERE rule_id = 1;
    RAISE NOTICE 'UNEXPECTED: rule edited';
EXCEPTION WHEN others THEN RAISE NOTICE 'Blocked as expected -> %', SQLERRM;
END $$;
