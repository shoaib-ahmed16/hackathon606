package com.yashasvi.hackathon.fogops.write;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.api.Times;
import com.yashasvi.hackathon.fogops.auth.FogUser;
import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import static com.yashasvi.hackathon.fogops.write.FogTx.p;
import static com.yashasvi.hackathon.fogops.write.WriteController.need;

/** Case lifecycle: create (real flights, real crew), close, delete (only if nobody acted on it). */
@RestController
@RequestMapping("/api")
public class CaseController {

    private static final Set<String> CASE_ROLES = Set.of("OCC", "ADMIN");
    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("ddMMM HH:mm:ss", Locale.ENGLISH);

    private final FogTx tx;
    private final FogDb db;

    public CaseController(FogTx tx, FogDb db) {
        this.tx = tx;
        this.db = db;
    }

    public record NewCase(@JsonProperty("scenario_id") Integer scenarioId, String title, @JsonProperty("hub_iata") String hubIata,
                          @JsonProperty("from_utc") String fromUtc, @JsonProperty("to_utc") String toUtc, String cause,
                          @JsonProperty("simulate_fog") Boolean simulateFog, @JsonProperty("reopen_after_min") Integer reopenAfterMin) {
    }

    /**
     * New disruption case whose watch list is every scheduled flight arriving at the hub inside the window.
     * With simulate_fog the case lives in its OWN what-if copy: simulated fog is written at scenario level and airport
     * status can never be deleted, so on the LIVE picture it would leak into every other LIVE case.
     */
    @PostMapping("/cases/create")
    public Map<String, Object> create(@RequestBody NewCase b, @AuthenticationPrincipal FogUser u) {
        String title = need(b.title(), "title").trim();
        String hub = (b.hubIata() == null || b.hubIata().isBlank() ? "SHJ" : b.hubIata()).toUpperCase(Locale.ROOT);
        OffsetDateTime from = Times.parse("from_utc", need(b.fromUtc(), "from_utc"));
        OffsetDateTime to = Times.parse("to_utc", need(b.toUtc(), "to_utc"));
        boolean sim = Boolean.TRUE.equals(b.simulateFog());
        int reopen = b.reopenAfterMin() == null ? 120 : b.reopenAfterMin();
        String cause = b.cause() == null ? "FOG" : b.cause();
        if (!to.isAfter(from)) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "The window must end after it starts");
        }
        Integer requested = b.scenarioId() != null ? b.scenarioId() : db.liveScenarioId();

        Map<String, Object> made = tx.as(u.userId(), t -> {
            Map<String, Object> src = t.one("SELECT kind FROM scenario WHERE scenario_id = :s", p("s", requested));
            if (src == null) {
                throw new ApiException(HttpStatus.NOT_FOUND, "Unknown scenario");
            }
            int scn = requested;
            if (sim && "LIVE".equals(src.get("kind"))) {
                String name = "WHATIF " + (title.isEmpty() ? hub : title) + " " + OffsetDateTime.now(ZoneOffset.UTC).format(STAMP);
                scn = ((Number) t.one("SELECT clone_scenario(CAST(:s AS int), :n, 'WHATIF') AS id", p("s", requested, "n", name)).get("id")).intValue();
            }
            final int scenario = scn;
            Map<String, Object> kase = t.one("""
                    INSERT INTO disruption_case (scenario_id, title, hub_iata, cause, phase, opened_by)
                    VALUES (:s, :t, :h, :c, 'MONITORING', :u) RETURNING *""", p("s", scenario, "t", title, "h", hub, "c", cause, "u", u.userId()));
            int caseId = ((Number) kase.get("case_id")).intValue();
            int n = t.update("""
                    INSERT INTO case_flight (case_id, flight_id, fog_exposure)
                    SELECT :c, f.flight_id, :x FROM flight f
                     WHERE f.arr_iata = :h AND f.flight_kind = 'SCHEDULED' AND f.sta_utc >= :from AND f.sta_utc < :to""",
                    p("c", caseId, "x", sim ? "HIGH" : "NONE", "h", hub, "from", from, "to", to));
            if (n == 0) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "No scheduled flights arrive at " + hub + " in that window");
            }
            if (sim) {
                OffsetDateTime stamp = (OffsetDateTime) t.one("SELECT scenario_now(CAST(:s AS int)) AS ts", p("s", scenario)).get("ts");
                t.update("""
                        INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
                               effective_from_utc, expected_reopen_utc, quality, entered_by, note)
                        VALUES (:s, :h, 'CLOSED', 'FOG (simulated)', 50, TRUE, 0, :ts, :ts + make_interval(mins => CAST(:m AS int)),
                               'SIMULATED', :u, 'Simulated fog for demonstration')""",
                        p("s", scenario, "h", hub, "ts", stamp, "m", reopen, "u", u.userId()));
                for (Object[] alt : new Object[][]{{"RKT", 4}, {"FJR", 6}}) {
                    t.update("""
                            INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, weather_above_minima, handling_ok,
                                   fuel_ok, lvp_in_force, effective_from_utc, quality, entered_by, note)
                            VALUES (:s, :a, 'OPEN', :p, TRUE, TRUE, TRUE, FALSE, :ts, 'SIMULATED', :u, 'Simulated alternate availability')""",
                            p("s", scenario, "a", alt[0], "p", alt[1], "ts", stamp, "u", u.userId()));
                }
            }
            Map<String, Object> out = new LinkedHashMap<>(kase);
            out.put("flights", n);
            out.put("scenario_for_agent", scenario);
            return out;
        });

        int scenario = ((Number) made.remove("scenario_for_agent")).intValue();
        int caseId = ((Number) made.get("case_id")).intValue();
        // first recommendations for airborne flights, written by the non-human agent
        int recommended = tx.as(tx.agentUserId(), t -> {
            List<Map<String, Object>> airborne = t.rows("""
                    SELECT cf.flight_id FROM case_flight cf
                      JOIN flight_state s ON s.flight_id = cf.flight_id AND s.scenario_id = :s
                     WHERE cf.case_id = :c AND s.status IN ('AIRBORNE','HOLDING')""", p("s", scenario, "c", caseId));
            for (Map<String, Object> r : airborne) {
                t.rows("SELECT propose_hold_or_divert(CAST(:s AS int), CAST(:c AS int), CAST(:f AS bigint))", p("s", scenario, "c", caseId, "f", r.get("flight_id")));
            }
            return airborne.size();
        });
        made.put("recommended", recommended);
        return made;
    }

    private static void requireRole(FogTx.Tx t, int userId) {
        Map<String, Object> row = t.one("SELECT role_code FROM app_user WHERE user_id = :u", p("u", userId));
        if (row == null || !CASE_ROLES.contains(row.get("role_code"))) {
            throw new ApiException(HttpStatus.FORBIDDEN, "Only OCC or ADMIN can do this");
        }
    }

    /** Archive a case. Decisions, comments and the audit trail stay; the case is just marked CLOSED. */
    @PostMapping("/cases/{caseId}/close")
    public Map<String, Object> close(@PathVariable int caseId, @AuthenticationPrincipal FogUser u) {
        return tx.as(u.userId(), t -> {
            requireRole(t, u.userId());
            List<Map<String, Object>> rows = t.rows(
                    "UPDATE disruption_case SET phase = 'CLOSED', closed_at = scenario_stamp(scenario_id) WHERE case_id = :c RETURNING *", p("c", caseId));
            if (rows.isEmpty()) {
                throw new ApiException(HttpStatus.NOT_FOUND, "Unknown case");
            }
            return rows.get(0);
        });
    }

    /**
     * Delete a case that nobody has acted on. Cases with decisions or comments are part of the audit trail (the database
     * forbids deleting those rows), so they must be closed instead.
     */
    @DeleteMapping("/cases/{caseId}")
    public Map<String, Object> delete(@PathVariable int caseId, @AuthenticationPrincipal FogUser u) {
        List<Map<String, Object>> refresh = tx.as(u.userId(), t -> {
            requireRole(t, u.userId());
            if (t.one("SELECT case_id FROM disruption_case WHERE case_id = :c", p("c", caseId)) == null) {
                throw new ApiException(HttpStatus.NOT_FOUND, "Unknown case");
            }
            Map<String, Object> used = t.one("SELECT (SELECT count(*) FROM decision WHERE case_id = :c) AS decisions, "
                    + "(SELECT count(*) FROM case_comment WHERE case_id = :c) AS comments", p("c", caseId));
            long decisions = ((Number) used.get("decisions")).longValue();
            long comments = ((Number) used.get("comments")).longValue();
            if (decisions > 0 || comments > 0) {
                throw new ApiException(HttpStatus.CONFLICT, "This case has " + decisions + " decision(s) and " + comments
                        + " comment(s). They are part of the audit trail and cannot be deleted. Close the case instead.");
            }
            t.update("DELETE FROM recovery_plan WHERE case_id = :c", p("c", caseId));   // items cascade
            t.update("DELETE FROM report WHERE case_id = :c", p("c", caseId));
            t.update("DELETE FROM diversion WHERE case_id = :c", p("c", caseId));
            // recommendations are unique per flight and scenario across ALL cases, so other cases may point at ours: unlink first
            t.update("UPDATE recommendation SET superseded_by = NULL WHERE superseded_by IN (SELECT rec_id FROM recommendation WHERE case_id = :c)", p("c", caseId));
            t.update("UPDATE recommendation SET superseded_by = NULL WHERE case_id = :c", p("c", caseId));
            // flights still watched by another case must not be left without an open recommendation
            List<Map<String, Object>> again = t.rows("""
                    SELECT DISTINCT other.case_id, cf.flight_id, dc.scenario_id
                      FROM case_flight cf
                      JOIN disruption_case dc ON dc.case_id = cf.case_id
                      JOIN case_flight other ON other.flight_id = cf.flight_id AND other.case_id <> cf.case_id
                      JOIN disruption_case odc ON odc.case_id = other.case_id AND odc.scenario_id = dc.scenario_id
                      JOIN flight_state s ON s.flight_id = cf.flight_id AND s.scenario_id = dc.scenario_id AND s.status IN ('AIRBORNE','HOLDING')
                     WHERE cf.case_id = :c""", p("c", caseId));
            t.update("DELETE FROM recommendation WHERE case_id = :c", p("c", caseId));   // options cascade
            t.update("DELETE FROM case_flight WHERE case_id = :c", p("c", caseId));
            t.update("DELETE FROM disruption_case WHERE case_id = :c", p("c", caseId));
            return again;
        });
        if (!refresh.isEmpty()) {
            tx.as(tx.agentUserId(), t -> {
                for (Map<String, Object> r : refresh) {
                    t.rows("SELECT propose_hold_or_divert(CAST(:s AS int), CAST(:c AS int), CAST(:f AS bigint))",
                            p("s", r.get("scenario_id"), "c", r.get("case_id"), "f", r.get("flight_id")));
                }
                return null;
            });
        }
        return p("deleted", caseId);
    }
}
