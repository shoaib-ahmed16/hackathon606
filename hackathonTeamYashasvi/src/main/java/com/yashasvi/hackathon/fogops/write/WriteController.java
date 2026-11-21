package com.yashasvi.hackathon.fogops.write;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.api.Times;
import com.yashasvi.hackathon.fogops.auth.FogUser;
import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

import static com.yashasvi.hackathon.fogops.write.FogTx.p;

/**
 * Actions. Each call is ONE transaction that starts with set_actor(<signed-in human>), so the database audit
 * triggers and role guardrails see the person. Legality, ranking and the hold/divert advice stay in Postgres; this
 * class only checks the request shape and the human-in-control preconditions.
 */
@RestController
@RequestMapping("/api")
public class WriteController {

    /** Tables people may insert into; columns are checked against the real table definition. */
    static final Set<String> WRITABLE = Set.of("decision", "decision_approval", "recommendation", "recommendation_option",
            "case_comment", "airport_status_event", "disruption_case", "case_flight", "flight_fuel_estimate", "crew_replacement");
    static final Set<String> DIVERSION_FIELDS = Set.of("status", "refuel_status", "handling_status", "waiting_for", "pax_onboard",
            "landed_alt_utc", "on_blocks_alt_utc", "planned_departure_utc", "actual_departure_utc", "turnaround_min_assumed");
    static final String NEEDS_APPROVED = "The swap needs an APPROVED CREW_REPLACE decision first";

    private final FogTx tx;
    private final FogDb db;

    public WriteController(FogTx tx, FogDb db) {
        this.tx = tx;
        this.db = db;
    }

    private Integer scn(Integer s) {
        return s != null ? s : db.liveScenarioId();
    }

    /** ['a', 'b'] - the same wording the original API used. */
    static String names(Set<String> s) {
        return s.stream().map(x -> "'" + x + "'").collect(java.util.stream.Collectors.joining(", ", "[", "]"));
    }

    static <T> T need(T value, String name) {
        if (value == null || value instanceof String s && s.isBlank()) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, name + " is required");
        }
        return value;
    }

    // ---------------------------------------------------------------- feed
    public record FlightEvent(@JsonProperty("scenario_id") Integer scenarioId, String source,
                              @JsonProperty("message_id") String messageId, @JsonProperty("flight_id") Long flightId,
                              @JsonProperty("event_type") String eventType, @JsonProperty("event_ts") String eventTs,
                              Map<String, Object> payload, @JsonProperty("seq_no") Long seqNo) {
    }

    /** Feed message in, flight state out (dedupe, out-of-order guard and status derivation happen in the database). */
    @PostMapping("/events/flight")
    public List<Map<String, Object>> flightEvent(@RequestBody FlightEvent b, @AuthenticationPrincipal FogUser u) {
        OffsetDateTime ts = Times.parse("event_ts", need(b.eventTs(), "event_ts"));
        return tx.as(u.userId(), t -> t.rows("""
                SELECT * FROM ingest_flight_event(CAST(:s AS int), :src, :mid, CAST(:f AS bigint), :et,
                       CAST(:ts AS timestamptz), CAST(:pl AS jsonb), CAST(:seq AS bigint))""",
                p("s", scn(b.scenarioId()), "src", b.source() == null ? "SIM_FEED" : b.source(),
                        "mid", need(b.messageId(), "message_id"), "f", need(b.flightId(), "flight_id"),
                        "et", need(b.eventType(), "event_type"), "ts", ts,
                        "pl", b.payload() == null ? Map.of() : b.payload(), "seq", b.seqNo())));
    }

    // ---------------------------------------------------------------- engine calls
    /** Creates the recovery leg and the diversion record and recomputes affected crew legality. */
    @PostMapping("/decisions/{decisionId}/execute-diversion")
    public List<Map<String, Object>> executeDiversion(@PathVariable long decisionId,
                                                      @RequestParam(value = "turnaround_min", required = false) Integer turnaroundMin,
                                                      @AuthenticationPrincipal FogUser u) {
        return tx.as(u.userId(), t -> t.rows("SELECT * FROM execute_diversion(CAST(:d AS bigint), CAST(:t AS int))",
                p("d", decisionId, "t", turnaroundMin)));
    }

    /** Re-run the hold/divert engine. The engine is the non-human AGENT: it writes the recommendation, never a decision. */
    @PostMapping("/flights/{flightId}/recommend")
    public List<Map<String, Object>> recommend(@PathVariable long flightId, @RequestParam("case_id") int caseId,
                                               @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        Integer s = scn(scenarioId);
        return tx.as(tx.agentUserId(), t -> {
            t.rows("SELECT compute_flight_legality(CAST(:s AS int), CAST(:f AS bigint), 'ui')", p("s", s, "f", flightId));
            return t.rows("SELECT propose_hold_or_divert(CAST(:s AS int), CAST(:c AS int), CAST(:f AS bigint)) AS rec_id",
                    p("s", s, "c", caseId, "f", flightId));
        });
    }

    /** Recompute legality and latest departure (new rows; history is kept, never overwritten). */
    @PostMapping("/flights/{flightId}/recompute")
    public Map<String, Object> recompute(@PathVariable long flightId,
                                         @RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                         @RequestParam(value = "buffer_min", defaultValue = "30") int bufferMin,
                                         @AuthenticationPrincipal FogUser u) {
        Integer s = scn(scenarioId);
        return tx.as(u.userId(), t -> {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("legality", t.rows("SELECT * FROM compute_flight_legality(CAST(:s AS int), CAST(:f AS bigint))", p("s", s, "f", flightId)));
            out.put("latest_departure", t.rows("SELECT * FROM compute_latest_departure(CAST(:s AS int), CAST(:f AS bigint), CAST(:b AS int))",
                    p("s", s, "f", flightId, "b", bufferMin)));
            return out;
        });
    }

    public record Recovery(@JsonProperty("scenario_id") Integer scenarioId, @JsonProperty("case_id") Integer caseId,
                           @JsonProperty("window_min") Integer windowMin, Map<String, Double> weights) {
    }

    @PostMapping("/recovery/build")
    public List<Map<String, Object>> buildRecovery(@RequestBody Recovery b, @AuthenticationPrincipal FogUser u) {
        Map<String, Object> w = b.weights() != null && !b.weights().isEmpty() ? new LinkedHashMap<>(b.weights())
                : p("fuel", 0.40, "crew", 0.30, "rotation", 0.15, "pax", 0.15);
        return tx.as(u.userId(), t -> t.rows("SELECT * FROM build_recovery_plan(CAST(:s AS int), CAST(:c AS int), CAST(:w AS int), CAST(:wt AS jsonb))",
                p("s", scn(b.scenarioId()), "c", need(b.caseId(), "case_id"), "w", b.windowMin() == null ? 60 : b.windowMin(), "wt", w)));
    }

    @PostMapping("/cases/{caseId}/report")
    public List<Map<String, Object>> report(@PathVariable int caseId, @AuthenticationPrincipal FogUser u) {
        return tx.as(u.userId(), t -> t.rows("SELECT * FROM generate_report(CAST(:c AS int), CAST(:u AS int))", p("c", caseId, "u", u.userId())));
    }

    public record Clone(@JsonProperty("source_scenario_id") Integer sourceScenarioId, String name, String kind, Map<String, Object> overrides) {
    }

    /** What-if: an isolated copy of flight state, crew and calculations. */
    @PostMapping("/scenarios/clone")
    public List<Map<String, Object>> clone(@RequestBody Clone b, @AuthenticationPrincipal FogUser u) {
        return tx.as(u.userId(), t -> t.rows("SELECT * FROM clone_scenario(CAST(:src AS int), :name, :kind, CAST(:ov AS jsonb))",
                p("src", scn(b.sourceScenarioId()), "name", need(b.name(), "name"), "kind", b.kind() == null ? "WHATIF" : b.kind(),
                        "ov", b.overrides() == null ? Map.of() : b.overrides())));
    }

    // ---------------------------------------------------------------- crew swap
    public record Swap(@JsonProperty("scenario_id") Integer scenarioId, @JsonProperty("case_id") Integer caseId,
                       @JsonProperty("duty_id") Long dutyId, @JsonProperty("out_crew_id") Integer outCrewId,
                       @JsonProperty("in_crew_id") Integer inCrewId, String reason,
                       @JsonProperty("sign_in_utc") String signInUtc, @JsonProperty("report_station") String reportStation,
                       @JsonProperty("from_leg_seq") Integer fromLegSeq, @JsonProperty("standby_id") Long standbyId,
                       @JsonProperty("positioning_min") Integer positioningMin, @JsonProperty("decision_id") Long decisionId) {
    }

    /**
     * Closes one assignment and opens another (history kept), records the replacement and marks the decision EXECUTED.
     * Human in control: a swap ALWAYS needs an APPROVED CREW_REPLACE decision, and must be the swap that was approved
     * (same duty, same outgoing and incoming crew). The database function itself does not check this.
     */
    @PostMapping("/crew/swap")
    public Map<String, Object> swap(@RequestBody Swap b, @AuthenticationPrincipal FogUser u) {
        need(b.dutyId(), "duty_id");
        need(b.outCrewId(), "out_crew_id");
        need(b.inCrewId(), "in_crew_id");
        need(b.reason(), "reason");
        OffsetDateTime signIn = Times.parse("sign_in_utc", b.signInUtc());
        Integer s = scn(b.scenarioId());
        return tx.as(u.userId(), t -> {
            if (b.decisionId() == null) {
                throw new ApiException(HttpStatus.CONFLICT, NEEDS_APPROVED);
            }
            Map<String, Object> d = t.one("SELECT status, decision_type, case_id, details FROM decision WHERE decision_id = CAST(:d AS bigint) FOR UPDATE",
                    p("d", b.decisionId()));
            if (d == null || !"APPROVED".equals(d.get("status")) || !"CREW_REPLACE".equals(d.get("decision_type"))) {
                throw new ApiException(HttpStatus.CONFLICT, NEEDS_APPROVED);
            }
            requireSameAsApproved(d, b);
            t.rows("SELECT swap_crew(CAST(:s AS int), CAST(:d AS bigint), CAST(:o AS int), CAST(:i AS int), :r, CAST(:si AS timestamptz), :rs, CAST(:fl AS smallint), 'REPLACEMENT')",
                    p("s", s, "d", b.dutyId(), "o", b.outCrewId(), "i", b.inCrewId(), "r", b.reason(), "si", signIn,
                            "rs", b.reportStation(), "fl", b.fromLegSeq() == null ? 1 : b.fromLegSeq()));
            if (b.caseId() != null) {
                t.update("""
                        INSERT INTO crew_replacement (scenario_id, case_id, duty_id, outgoing_crew_id, incoming_crew_id, standby_id,
                               positioning_from_iata, positioning_to_iata, positioning_mode, positioning_min, new_sign_in_utc, decision_id, status)
                        VALUES (:s, :c, :d, :o, :i, :sb, 'SHJ', :rs, 'ROAD', :pm, CAST(:si AS timestamptz), :dec, 'APPROVED')""",
                        p("s", s, "c", b.caseId(), "d", b.dutyId(), "o", b.outCrewId(), "i", b.inCrewId(), "sb", b.standbyId(),
                                "rs", b.reportStation(), "pm", b.positioningMin(), "si", signIn, "dec", b.decisionId()));
            }
            t.update("UPDATE decision SET status = 'EXECUTED' WHERE decision_id = :d", p("d", b.decisionId()));
            return p("ok", true);
        });
    }

    /** The approval covered one specific replacement; it cannot be used for a different duty or different people. */
    static void requireSameAsApproved(Map<String, Object> decision, Swap b) {
        JsonNode details = decision.get("details") instanceof JsonNode n ? n : null;
        boolean ok = same(details, "duty_id", b.dutyId()) && same(details, "out_crew_id", b.outCrewId())
                && same(details, "in_crew_id", b.inCrewId());
        Object decisionCase = decision.get("case_id");
        if (ok && b.caseId() != null && decisionCase != null) {
            ok = ((Number) decisionCase).intValue() == b.caseId();
        }
        if (!ok) {
            throw new ApiException(HttpStatus.CONFLICT,
                    "The swap does not match the approved decision (same duty, outgoing and incoming crew required)");
        }
    }

    private static boolean same(JsonNode details, String key, Number requested) {
        JsonNode v = details == null ? null : details.get(key);
        return v == null || v.isNull() || v.asLong() == requested.longValue();
    }

    // ---------------------------------------------------------------- station update
    /** Station update at the alternate (landed, refuelled, waiting for ...). Audited; feeds "what is it waiting for". */
    @PatchMapping("/diversions/{diversionId}")
    public List<Map<String, Object>> updateDiversion(@PathVariable long diversionId, @RequestBody Map<String, Object> body,
                                                     @AuthenticationPrincipal FogUser u) {
        Set<String> bad = new TreeSet<>(body.keySet());
        bad.removeAll(DIVERSION_FIELDS);
        if (!bad.isEmpty() || body.isEmpty()) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "Unknown or empty fields: " + names(bad));
        }
        List<String> sets = new ArrayList<>();
        Map<String, Object> params = new LinkedHashMap<>(body);   // keys are whitelisted constants: safe as names
        body.keySet().forEach(k -> sets.add(k + " = :" + k));
        params.put("uby__", u.userId());
        params.put("id__", diversionId);
        List<Map<String, Object>> rows = tx.as(u.userId(), t -> t.rows("UPDATE diversion SET " + String.join(", ", sets)
                + ", updated_by = :uby__, updated_at = now() WHERE diversion_id = :id__ RETURNING *", params));
        if (rows.isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Unknown diversion");
        }
        return rows;
    }

    // ---------------------------------------------------------------- human records
    /** Human workflow rows are plain INSERTs; the guardrail triggers enforce roles and status transitions. */
    @PostMapping("/records/{table}")
    public List<Map<String, Object>> insertRecord(@PathVariable String table, @RequestBody Map<String, Object> body,
                                                  @AuthenticationPrincipal FogUser u) {
        if (!WRITABLE.contains(table)) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Table not writable: " + table);
        }
        return tx.as(u.userId(), t -> {
            Set<String> cols = new java.util.HashSet<>();
            t.rows("SELECT column_name FROM information_schema.columns WHERE table_schema = 'fogops' AND table_name = :t",
                    p("t", table)).forEach(r -> cols.add((String) r.get("column_name")));
            Set<String> bad = new TreeSet<>(body.keySet());
            bad.removeAll(cols);
            if (!bad.isEmpty() || body.isEmpty()) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "Unknown or empty columns: " + names(bad));
            }
            List<String> names = new ArrayList<>();
            List<String> marks = new ArrayList<>();
            Map<String, Object> params = new LinkedHashMap<>();
            int i = 0;
            for (Map.Entry<String, Object> e : body.entrySet()) {
                names.add('"' + e.getKey() + '"');   // validated against information_schema above
                marks.add(":v" + i);
                params.put("v" + i++, e.getValue());
            }
            return t.rows("INSERT INTO fogops." + table + " (" + String.join(",", names) + ") VALUES (" + String.join(",", marks)
                    + ") RETURNING *", params);
        });
    }
}
