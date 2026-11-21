package com.yashasvi.hackathon.fogops.console;

import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** The audit trail (any signed-in user, as in the original API). Reading it is not itself audited. */
@RestController
@RequestMapping("/api")
public class AuditController {

    /** rows the loader/engine writes in bulk: hidden unless asked for. Constants only (inlined into the SQL). */
    private static final String SYSTEM_ENTITIES = "'data_exception','recommendation','recommendation_option','crew_assignment','crew_duty_leg',"
            + "'case_flight','fdp_calculation','latest_departure_calc','flight_state','reassessment_queue'";

    private final FogDb db;
    private final ConsoleService console;

    public AuditController(FogDb db, ConsoleService console) {
        this.db = db;
        this.console = console;
    }

    /** kind: all | action (what people did) | change (what changed in the data). */
    @GetMapping("/audit")
    public List<Map<String, Object>> audit(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                           @RequestParam(value = "case_id", required = false) Integer caseId,
                                           @RequestParam(value = "actor_id", required = false) Integer actorId,
                                           @RequestParam(defaultValue = "all") String kind,
                                           @RequestParam(value = "q", required = false) String q,
                                           @RequestParam(value = "include_system", defaultValue = "false") boolean includeSystem,
                                           @RequestParam(value = "flight_id", required = false) Integer flightId,
                                           @RequestParam(defaultValue = "300") int limit) {
        if (limit < 1 || limit > 2000) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "limit must be between 1 and 2000");
        }
        List<String> where = new ArrayList<>(List.of("1=1"));
        Map<String, Object> p = new LinkedHashMap<>();
        if (scenarioId != null) {
            where.add("(al.scenario_id = :s OR al.scenario_id IS NULL)");
            p.put("s", scenarioId);
        }
        if (caseId != null) {
            where.add("(al.case_id = :c OR al.case_id IS NULL)");
            p.put("c", caseId);
        }
        if (actorId != null) {
            where.add("al.actor_user_id = :a");
            p.put("a", actorId);
        }
        if ("action".equals(kind)) {
            where.add("al.entity_type = 'api'");
        } else if ("change".equals(kind)) {
            where.add("al.entity_type <> 'api'");
        }
        if (!includeSystem) {
            where.add("(al.entity_type = 'api' OR (al.actor_user_id IS NOT NULL AND al.entity_type NOT IN (" + SYSTEM_ENTITIES + ")))");
        }
        if (flightId != null) {
            where.add("(al.after_data->>'flight_id' = :f OR al.entity_id = :f OR al.after_data->'query'->>'flight_id' = :f OR al.entity_id LIKE :fp)");
            p.put("f", String.valueOf(flightId));
            p.put("fp", "/api/flights/" + flightId + "/%");
        }
        if (q != null && !q.isEmpty()) {
            where.add("(al.entity_type ILIKE :q OR al.entity_id ILIKE :q OR al.action ILIKE :q OR al.after_data::text ILIKE :q OR u.display_name ILIKE :q)");
            p.put("q", "%" + q + "%");
        }
        List<Map<String, Object>> rows = db.fetch("""
                SELECT al.audit_id, al.occurred_at, al.scenario_time_utc, al.actor_user_id, u.display_name AS actor, al.actor_role,
                       al.scenario_id, al.case_id, al.entity_type, al.entity_id, al.action, al.changed_fields, al.before_data, al.after_data
                  FROM audit_log al LEFT JOIN app_user u ON u.user_id = al.actor_user_id
                 WHERE\s""" + String.join(" AND ", where) + " ORDER BY al.audit_id DESC LIMIT " + limit, p);
        for (Map<String, Object> row : rows) {
            row.put("kind", "api".equals(row.get("entity_type")) ? "action" : "change");
            row.put("summary", AuditSummary.of(row));
        }
        return rows;
    }
}
