package com.yashasvi.hackathon.fogops.api;

import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Read models for the FogOps screens. Every number comes from the database (views and functions): this class
 * only selects, scopes and orders. It never computes legality, never filters rows out, never fills in missing values.
 * Every endpoint is scenario-scoped; no scenario_id means the LIVE scenario.
 */
@RestController
@RequestMapping("/api")
public class ReadController {

    private final FogDb db;

    public ReadController(FogDb db) {
        this.db = db;
    }

    /** Every screen is scenario-scoped. No scenario given = the LIVE operational picture. */
    private Integer scn(Integer scenarioId) {
        return scenarioId != null ? scenarioId : db.liveScenarioId();
    }

    private static int limit(int value, int max) {
        if (value < 1 || value > max) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "limit must be between 1 and " + max);
        }
        return value;
    }

    private static Map<String, Object> filters(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) {
            m.put((String) kv[i], kv[i + 1]);
        }
        return m;
    }

    private static Map<String, Object> params(Object... kv) {
        return filters(kv);
    }

    @GetMapping("/scenarios")
    public List<Map<String, Object>> scenarios() {
        return db.fetch("SELECT scenario_id, name, kind, parent_scenario_id, sim_clock_utc, description, is_active "
                + "FROM scenario ORDER BY scenario_id");
    }

    /** Who can act (drives the "acting as" picker). */
    @GetMapping("/users")
    public List<Map<String, Object>> users() {
        return db.fetch("SELECT user_id, username, display_name, role_code FROM app_user WHERE is_active ORDER BY user_id");
    }

    /** All disruption cases (newest first), with their scenario. Optional scenario filter. */
    @GetMapping("/cases")
    public List<Map<String, Object>> cases(@RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.fetch("""
                SELECT c.*, s.name AS scenario_name, s.kind AS scenario_kind, s.sim_clock_utc
                  FROM disruption_case c JOIN scenario s USING (scenario_id)
                 WHERE (CAST(:s AS integer) IS NULL OR c.scenario_id = CAST(:s AS integer)) ORDER BY c.case_id DESC
                """, params("s", scenarioId));
    }

    /** Single flight watch: status, ETA, fog exposure, captain, duty margin, recommendation, decision, owner. */
    @GetMapping("/flights")
    public List<Map<String, Object>> flights(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                             @RequestParam(value = "case_id", required = false) Integer caseId,
                                             @RequestParam(defaultValue = "1000") int limit) {
        return db.view("v_flight_watch", filters("scenario_id", scn(scenarioId), "case_id", caseId),
                "ORDER BY coalesce(eta_utc, sta_utc)", limit(limit, 5000));
    }

    /** Q1: which crew runs out of legality next (soonest first). With case_id, only duties flying that case's flights. */
    @GetMapping("/crew/legality")
    public List<Map<String, Object>> crewLegality(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                                  @RequestParam(value = "case_id", required = false) Integer caseId,
                                                  @RequestParam(defaultValue = "200") int limit) {
        Integer s = scn(scenarioId);
        int lim = limit(limit, 2000);
        if (caseId == null) {
            return db.view("v_crew_legality_ranking", filters("scenario_id", s),
                    "ORDER BY minutes_until_legal_end NULLS LAST", lim);
        }
        return db.fetch("""
                SELECT v.* FROM v_crew_legality_ranking v
                 WHERE v.scenario_id = :s AND v.duty_id IN (
                       SELECT l.duty_id FROM crew_duty_leg l JOIN case_flight cf ON cf.flight_id = l.flight_id
                        WHERE l.scenario_id = :s AND l.is_active AND cf.case_id = :c)
                 ORDER BY v.minutes_until_legal_end NULLS LAST LIMIT\s""" + lim, params("s", s, "c", caseId));
    }

    /** Q2: where is aircraft X and what is it waiting for. */
    @GetMapping("/aircraft/{registration}")
    public List<Map<String, Object>> aircraft(@PathVariable String registration,
                                              @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        List<Map<String, Object>> rows = db.view("v_aircraft_whereabouts",
                filters("scenario_id", scn(scenarioId), "registration", registration.toUpperCase()), null, 1000);
        if (rows.isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Unknown registration");
        }
        return rows;
    }

    /** Q4: alternate crew who keep legality and roster (positioning, LVP, rest, conflicts included). */
    @GetMapping("/crew/standby-candidates")
    public List<Map<String, Object>> standby(@RequestParam("duty_id") int dutyId,
                                             @RequestParam String position,
                                             @RequestParam String station,
                                             @RequestParam(value = "from_leg", defaultValue = "1") int fromLeg,
                                             @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.fetch("SELECT * FROM standby_candidates(:s, CAST(:d AS bigint), :p, CAST(:st AS char(3)), CAST(:f AS smallint))",
                params("s", scn(scenarioId), "d", dutyId, "p", position.toUpperCase(), "st", station.toUpperCase(), "f", fromLeg));
    }

    @GetMapping("/airport/status")
    public List<Map<String, Object>> airportStatus(@RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.view("v_airport_status_current", filters("scenario_id", scn(scenarioId)), null, 1000);
    }

    /** Current recovery plan items (with flight_id so the UI can move a flight to another slot). */
    @GetMapping("/recovery/plan")
    public List<Map<String, Object>> recoveryPlan(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                                  @RequestParam(value = "case_id", required = false) Integer caseId) {
        return db.fetch("""
                SELECT v.*, i.flight_id FROM v_recovery_plan_current v
                  JOIN recovery_plan_item i ON i.plan_id = v.plan_id AND i.rank = v.rank
                 WHERE v.scenario_id = :s AND (CAST(:c AS integer) IS NULL OR v.case_id = CAST(:c AS integer))
                 ORDER BY v.plan_id DESC, v.rank
                """, params("s", scn(scenarioId), "c", caseId));
    }

    @GetMapping("/decisions/log")
    public List<Map<String, Object>> decisionLog(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                                 @RequestParam(value = "case_id", required = false) Integer caseId,
                                                 @RequestParam(defaultValue = "500") int limit) {
        return db.view("v_decision_log", filters("scenario_id", scn(scenarioId), "case_id", caseId),
                "ORDER BY decided_at DESC", limit(limit, 5000));
    }

    /** Shared timeline: feed, airport, decisions, approvals, crew, comments on one clock. */
    @GetMapping("/timeline")
    public List<Map<String, Object>> timeline(@RequestParam("case_id") int caseId,
                                              @RequestParam(defaultValue = "500") int limit) {
        return db.view("v_case_timeline", filters("case_id", caseId), "ORDER BY occurred_at", limit(limit, 5000));
    }

    @GetMapping("/feed/freshness")
    public List<Map<String, Object>> feedFreshness() {
        return db.view("v_feed_freshness", null, null, 1000);
    }

    /** Open data-quality / verification items (scenario-less import findings are always included). */
    @GetMapping("/exceptions")
    public List<Map<String, Object>> exceptions(@RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.fetch("SELECT * FROM v_open_exceptions WHERE scenario_id = :s OR scenario_id IS NULL",
                params("s", scn(scenarioId)));
    }

    /**
     * Options panel: every ranked option (HOLD + each alternate) of the open recommendation, with blocking constraints.
     * option_id is joined in so a decision can reference the exact option chosen.
     */
    @GetMapping("/recommendations/options")
    public List<Map<String, Object>> recommendationOptions(@RequestParam("case_id") int caseId,
                                                           @RequestParam(value = "flight_id", required = false) Long flightId,
                                                           @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.fetch("""
                SELECT v.*, o.option_id FROM v_recommendation_options v
                  JOIN recommendation_option o ON o.rec_id = v.rec_id AND o.rank = v.rank
                 WHERE v.scenario_id = :s AND v.case_id = :c AND (CAST(:f AS bigint) IS NULL OR v.flight_id = CAST(:f AS bigint))
                 ORDER BY v.flight_no, v.rank LIMIT 2000
                """, params("s", scn(scenarioId), "c", caseId, "f", flightId));
    }

    /** Station-side tracking of diverted aircraft (what is it waiting for?). */
    @GetMapping("/diversions")
    public List<Map<String, Object>> diversions(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                                @RequestParam(value = "case_id", required = false) Integer caseId) {
        return db.view("diversion", filters("scenario_id", scn(scenarioId), "case_id", caseId),
                "ORDER BY diversion_id", 1000);
    }

    @GetMapping("/comments")
    public List<Map<String, Object>> comments(@RequestParam("case_id") int caseId,
                                              @RequestParam(value = "flight_id", required = false) Long flightId) {
        return db.fetch("""
                SELECT c.comment_id, c.flight_id, c.body, c.author_role, c.created_at, u.display_name AS author
                  FROM case_comment c JOIN app_user u ON u.user_id = c.author_id
                 WHERE c.case_id = :c AND (CAST(:f AS bigint) IS NULL OR c.flight_id = CAST(:f AS bigint)) ORDER BY c.created_at
                """, params("c", caseId, "f", flightId));
    }

    /** Latest holding-endurance estimate per flight, with its quality label. */
    @GetMapping("/fuel")
    public List<Map<String, Object>> fuel(@RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return db.fetch("""
                SELECT DISTINCT ON (flight_id) flight_id, as_of_utc, est_holding_endurance_min, fuel_on_board_kg, quality, basis
                  FROM flight_fuel_estimate WHERE scenario_id = :s ORDER BY flight_id, as_of_utc DESC, estimate_id DESC
                """, params("s", scn(scenarioId)));
    }

    /** Reassessment queue health (the worker drains it). */
    @GetMapping("/queue")
    public List<Map<String, Object>> queue() {
        return db.fetch("SELECT status, count(*) AS n, max(enqueued_at) AS latest FROM reassessment_queue GROUP BY status ORDER BY status");
    }
}
