package com.yashasvi.hackathon.fogops.console;

import com.fasterxml.jackson.databind.JsonNode;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.db.FogDb;
import org.postgresql.util.PSQLException;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static com.yashasvi.hackathon.fogops.console.Text.dec;
import static com.yashasvi.hackathon.fogops.console.Text.local;
import static com.yashasvi.hackathon.fogops.console.Text.str;
import static com.yashasvi.hackathon.fogops.console.Text.truthy;
import static com.yashasvi.hackathon.fogops.console.Text.z;

/**
 * Console read models: deadlines, flight explanation, briefing. Every number comes from the database engine
 * (views and functions); this class only selects, orders and words them. Missing data stays null/"verify", never guessed.
 */
@Service
public class ConsoleService {

    private static final Set<String> DIVERSION_DONE = Set.of("DEPARTED", "CLOSED", "CANCELLED");
    private static final Set<String> AIRBORNE = Set.of("AIRBORNE", "HOLDING", "DIVERTING");

    private final FogDb db;

    public ConsoleService(FogDb db) {
        this.db = db;
    }

    public Integer scn(Integer s) {
        return s != null ? s : db.liveScenarioId();
    }

    OffsetDateTime nowUtc(Integer s) {
        return (OffsetDateTime) db.fetch("SELECT scenario_now(:s) AS t", Map.of("s", s)).get(0).get("t");
    }

    private static List<Object> line(String mark, String text) {
        return List.of(mark, text);
    }

    private static Map<String, Object> map(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) {
            m.put((String) kv[i], kv[i + 1]);
        }
        return m;
    }

    private static OffsetDateTime plusMinutes(OffsetDateTime t, Object minutes) {
        BigDecimal m = dec(minutes).max(BigDecimal.ZERO);
        return t.plusNanos(m.multiply(BigDecimal.valueOf(60_000_000_000L)).longValue());
    }

    private List<Map<String, Object>> watch(Integer s, Integer caseId, Integer flightId) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("scenario_id", s);
        f.put("case_id", caseId);
        f.put("flight_id", flightId);
        return db.view("v_flight_watch", f, "ORDER BY flight_id", 2000);
    }

    /** flight_decision_inputs / rank_alternates refuse flights that are not airborne (RAISE): that means "no options to preview". */
    private static boolean isRefusal(DataAccessException e) {
        return e.getCause() instanceof PSQLException p && "P0001".equals(p.getSQLState());
    }

    private Map<String, Object> inputs(Integer s, Object flightId) {
        List<Map<String, Object>> r = db.fetch("SELECT * FROM flight_decision_inputs(:s, CAST(:f AS bigint))", Map.of("s", s, "f", flightId));
        return r.isEmpty() ? Map.of() : r.get(0);
    }

    private List<Map<String, Object>> alternates(Integer s, Object flightId) {
        return db.fetch("SELECT * FROM rank_alternates(:s, CAST(:f AS bigint))", Map.of("s", s, "f", flightId));
    }

    // ------------------------------------------------------------------ deadlines
    public Map<String, Object> deadlines(int caseId, Integer scenarioId) {
        Integer s = scn(scenarioId);
        OffsetDateTime now = nowUtc(s);
        List<Object> out = new ArrayList<>();
        for (Map<String, Object> f : watch(s, caseId, null)) {
            Map<String, Object> d = null;
            Object status = f.get("status");
            Object fid = f.get("flight_id");
            if (truthy(f.get("diverted_to")) && truthy(f.get("latest_legal_offblocks_utc"))
                    && !DIVERSION_DONE.contains(f.get("diversion_status"))) {
                List<String> why = List.of(
                        truthy(f.get("legal_end_utc"))
                                ? "Crew legal end " + z(f.get("legal_end_utc")) + " (" + local(f.get("legal_end_utc")) + " SHJ)"
                                : "Crew legal end not available",
                        "Latest legal off-blocks from " + str(Text.or(f.get("departure_from_iata"), f.get("diverted_to"))) + ": "
                                + z(f.get("latest_legal_offblocks_utc")) + " (legal end minus return block time)",
                        "Operational target " + z(f.get("operational_target_utc")) + " (includes the operational buffer)");
                d = map("deadline_utc", f.get("latest_legal_offblocks_utc"), "kind", "departure",
                        "reason", "Latest legal departure from " + str(f.get("diverted_to")), "why", why);
            } else if (AIRBORNE.contains(status)) {
                Map<String, Object> inp = inputs(s, fid);
                Object end = inp.get("endurance_left_min");
                if (end == null) {
                    d = map("deadline_utc", null, "kind", "verify", "reason", "Fuel endurance not reported",
                            "why", List.of("No holding-endurance estimate has been entered, so neither holding nor a diversion can be marked executable."));
                } else {
                    Map<String, Object> best = null;
                    for (Map<String, Object> o : alternates(s, fid)) {
                        if (truthy(o.get("is_executable")) && o.get("fuel_margin_min") != null
                                && (best == null || dec(o.get("fuel_margin_min")).compareTo(dec(best.get("fuel_margin_min"))) > 0)) {
                            best = o;
                        }
                    }
                    if (best != null) {
                        String alt = str(best.get("alt_iata"));
                        d = map("deadline_utc", plusMinutes(now, best.get("fuel_margin_min")), "kind", "divert",
                                "reason", "Last moment to divert to " + alt + " on fuel",
                                "why", List.of(
                                        "Holding endurance " + str(end) + " min (quality: " + str(inp.get("fuel_quality")).toLowerCase() + ")",
                                        "Flight time to " + alt + " about " + str(best.get("est_flight_min")) + " min ("
                                                + Math.round(Math.rint(dec(best.get("distance_km")).doubleValue())) + " km plus approach)",
                                        "Spare fuel on arrival at " + alt + " if diverting now: " + str(best.get("fuel_margin_min"))
                                                + " min, so the decision can wait about that long",
                                        truthy(inp.get("reopen_utc"))
                                                ? "SHJ reopening " + z(inp.get("reopen_utc")) + " (" + str(inp.get("reopen_quality")).toLowerCase() + ")"
                                                : "No reopening forecast on record"));
                    } else {
                        d = map("deadline_utc", plusMinutes(now, end), "kind", "fuel",
                                "reason", "Fuel runs out (no executable alternate)",
                                "why", List.of("Holding endurance " + str(end) + " min and no alternate is executable. Escalate to the OCC duty manager."));
                    }
                }
            } else if (truthy(f.get("latest_legal_offblocks_utc")) && ("SCHEDULED".equals(status) || "TAXI_OUT".equals(status))) {
                d = map("deadline_utc", f.get("latest_legal_offblocks_utc"), "kind", "departure", "reason", "Latest legal departure",
                        "why", List.of("Crew legal end " + z(f.get("legal_end_utc")), "Latest legal off-blocks " + z(f.get("latest_legal_offblocks_utc"))));
            }
            if (d != null) {
                Map<String, Object> item = map("flight_id", fid, "flight_no", f.get("flight_no"));
                item.putAll(d);
                out.add(item);
            }
        }
        return map("now_utc", now, "items", out);
    }

    // ------------------------------------------------------------------ flight explanation
    public Map<String, Object> flightDetail(int flightId, int caseId, Integer scenarioId) {
        Integer s = scn(scenarioId);
        List<Map<String, Object>> fl = watch(s, caseId, flightId);
        if (fl.isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Flight not in this case");
        }
        Map<String, Object> f = fl.get(0);
        List<Map<String, Object>> rec = db.fetch("""
                SELECT rec_id, rec_type, confidence, rationale, assumptions, uncertainty, generated_by, generated_at, required_approver_role, status
                  FROM recommendation WHERE scenario_id = :s AND flight_id = :f AND status IN ('PROPOSED','ACCEPTED')
                 ORDER BY generated_at DESC LIMIT 1""", Map.of("s", s, "f", flightId));
        List<Map<String, Object>> crew = db.fetch("""
                SELECT cm.crew_id, cm.full_name, ca.position_code,
                       EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = cm.crew_id AND q.qual_code = 'LVP') AS lvp
                  FROM crew_duty_leg l JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id AND ca.valid_to IS NULL
                  JOIN crew_member cm ON cm.crew_id = ca.crew_id
                 WHERE l.scenario_id = :s AND l.flight_id = :f AND l.is_active
                 ORDER BY array_position(ARRAY['CP','FO','SO','CS','CC','SEC','EN'], ca.position_code), cm.full_name""",
                Map.of("s", s, "f", flightId));
        List<Map<String, Object>> fdp = !truthy(f.get("duty_id")) ? List.of() : db.fetch("""
                SELECT fc.sign_in_utc, fc.band_tz, fc.sign_in_local_time, fc.legs_counted, fc.max_fdp_min, fc.legal_end_utc, fc.discretion_end_utc,
                       fc.projected_end_utc, fc.margin_min, fc.status, fr.source_rule_id, fr.local_start_from, fr.local_start_to, rs.name AS rule_set, rs.version
                  FROM fdp_calculation fc LEFT JOIN fdp_rule fr ON fr.rule_id = fc.rule_id LEFT JOIN rule_set rs ON rs.rule_set_id = fc.rule_set_id
                 WHERE fc.scenario_id = :s AND fc.duty_id = CAST(:d AS bigint) AND fc.is_current AND fc.crew_id IS NULL LIMIT 1""",
                Map.of("s", s, "d", f.get("duty_id")));
        Object pax = db.fetch("SELECT coalesce(sum(pax_count),0) AS n FROM pax_connection WHERE inbound_flight_id = :f",
                Map.of("f", flightId)).get(0).get("n");
        Object ldFlight = truthy(f.get("recovery_flight_id")) ? f.get("recovery_flight_id") : flightId;
        List<Map<String, Object>> ld = db.fetch("""
                SELECT assumptions, block_time_min, block_time_basis FROM latest_departure_calc
                 WHERE scenario_id = :s AND is_current AND flight_id = CAST(:f AS bigint) ORDER BY calculated_at DESC LIMIT 1""",
                Map.of("s", s, "f", ldFlight));

        Map<String, Object> conseq = consequences(s, flightId, f, pax);

        List<String> why = new ArrayList<>();
        if (!fdp.isEmpty()) {
            Map<String, Object> x = fdp.get(0);
            why.add("Crew signed in " + z(x.get("sign_in_utc")) + " (" + local(x.get("sign_in_utc")) + " SHJ), FDP band " + str(x.get("band_tz"))
                    + " local start " + str(x.get("sign_in_local_time")));
            // FastAPI crashes (500) here when the duty is VERIFICATION_REQUIRED and has no max FDP; say so instead of guessing
            String maxFdp = x.get("max_fdp_min") == null
                    ? "maximum FDP not available (duty needs verification)"
                    : "maximum FDP " + (((Number) x.get("max_fdp_min")).intValue() / 60) + "h "
                    + String.format("%02d", ((Number) x.get("max_fdp_min")).intValue() % 60) + "m";
            why.add(str(x.get("legs_counted")) + " sector(s) counted, " + maxFdp
                    + (truthy(x.get("rule_set")) ? " (rule " + str(x.get("source_rule_id")) + ", " + str(x.get("rule_set")) + " " + str(x.get("version")) + ")" : ""));
            why.add(truthy(x.get("legal_end_utc"))
                    ? "Legal end " + z(x.get("legal_end_utc")) + "; with commander discretion +3h: " + z(x.get("discretion_end_utc"))
                    : "Legal end not available");
            if (!ld.isEmpty()) {
                why.add(truthy(ld.get(0).get("block_time_basis"))
                        ? "Return block time: " + str(ld.get(0).get("block_time_basis")) : "Return block time not available");
            }
        }
        return map("flight", f, "recommendation", rec.isEmpty() ? null : rec.get(0), "crew", crew,
                "fdp", fdp.isEmpty() ? null : fdp.get(0), "connecting_pax", pax,
                "assumptions", ld.isEmpty() ? null : ld.get(0).get("assumptions"), "why", why, "consequences", conseq);
    }

    /** What each option would do, from the engine's own ranking. Empty for flights the engine refuses to rank (not airborne). */
    private Map<String, Object> consequences(Integer s, int flightId, Map<String, Object> f, Object pax) {
        try {
            Map<String, Object> inp = inputs(s, flightId);
            Map<String, Object> conseq = new LinkedHashMap<>();
            for (Map<String, Object> o : alternates(s, flightId)) {
                String alt = str(o.get("alt_iata"));
                List<List<Object>> lines = new ArrayList<>();
                lines.add(line("✓", "Creates recovery flight " + str(f.get("flight_no")) + "D " + alt + " to " + str(f.get("planned_arr_iata"))));
                if (truthy(inp.get("legal_end_now")) && truthy(inp.get("legal_end_if_diverted"))) {
                    lines.add(line("!", "Adds 1 sector for every operating crew member: legal end " + z(inp.get("legal_end_now")) + " to " + z(inp.get("legal_end_if_diverted"))));
                }
                Object crm = o.get("crew_return_margin_min");
                if (crm != null) {
                    boolean neg = dec(crm).signum() < 0;
                    lines.add(line(neg ? "!" : "✓", neg ? "Return to the hub needs commander discretion or a replacement crew"
                            : "Crew can fly the return legally (margin " + str(crm) + " min)"));
                }
                Object stands = o.get("stands_left");
                if (stands != null) {
                    int n = ((Number) stands).intValue();
                    lines.add(line(n <= 2 ? "!" : "✓", alt + " stands " + n + " to " + Math.max(0, n - 1)));
                }
                Object fuel = o.get("fuel_margin_min");
                if (fuel != null) {
                    lines.add(line(dec(fuel).compareTo(BigDecimal.valueOf(15)) < 0 ? "!" : "✓", "Spare fuel on arrival " + str(fuel) + " min"));
                }
                if (truthy(pax)) {
                    lines.add(line("i", str(pax) + " connecting passengers affected"));
                }
                if (o.get("blocking_constraints") instanceof JsonNode bc && bc.isArray()) {
                    for (JsonNode c : bc) {
                        JsonNode code = c.get("code");
                        String text = code == null ? "" : str(code);
                        lines.add(line(!truthy(c.get("verify")) ? "✕" : "?", text.replace('_', ' ').toLowerCase()));
                    }
                }
                conseq.put(alt, lines);
            }
            List<List<Object>> hold = new ArrayList<>();
            hold.add(line("✓", "Stays in the arrival sequence"));
            Object endur = inp.get("endurance_left_min");
            if (endur != null) {
                hold.add(line(dec(endur).compareTo(BigDecimal.valueOf(30)) < 0 ? "!" : "✓",
                        "Holding endurance " + str(endur) + " min (" + str(inp.get("fuel_quality")).toLowerCase() + ")"));
            }
            if (truthy(inp.get("reopen_utc"))) {
                hold.add(line("i", "Hub reopening " + z(inp.get("reopen_utc")) + " (" + str(inp.get("reopen_quality")).toLowerCase() + ")"));
            }
            if (truthy(pax)) {
                hold.add(line("i", str(pax) + " connecting passengers waiting"));
            }
            conseq.put("HOLD", hold);
            return conseq;
        } catch (DataAccessException e) {
            if (isRefusal(e)) {
                return new LinkedHashMap<>();
            }
            throw e;
        }
    }

    // ------------------------------------------------------------------ briefing
    public Map<String, Object> briefing(int caseId, Integer scenarioId, OffsetDateTime since, int limit) {
        Integer s = scn(scenarioId);
        OffsetDateTime now = nowUtc(s);
        Map<String, Object> p = new LinkedHashMap<>();
        p.put("c", caseId);
        p.put("since", since);
        p.put("lim", limit);
        List<Map<String, Object>> rows = new ArrayList<>(db.fetch("""
                SELECT occurred_at, stream, actor, actor_role, entity_type, summary FROM v_case_timeline
                 WHERE case_id = :c AND (CAST(:since AS timestamptz) IS NULL OR occurred_at > CAST(:since AS timestamptz))
                   AND entity_type IN ('decision','decision_approval','airport_status_event','diversion','crew_replacement','case_comment','recovery_plan','disruption_case')
                 ORDER BY occurred_at DESC LIMIT :lim""", p));
        Object recs = db.fetch("SELECT count(*) FILTER (WHERE generated_at > CAST(:t AS timestamptz)) AS n FROM recommendation WHERE scenario_id = :s",
                map("t", since != null ? since : OffsetDateTime.of(1970, 1, 1, 0, 0, 0, 0, ZoneOffset.UTC), "s", s)).get(0).get("n");
        java.util.Collections.reverse(rows);
        return map("now_utc", now, "since", since, "new_recommendations", recs, "items", rows);
    }

    // ------------------------------------------------------------------ ask suggestions
    /** Suggested questions filled with a real flight, tail and station from the case. AI free text arrives in a later phase. */
    public Map<String, Object> askQuestions(Integer caseId, Integer scenarioId) {
        String flight = "G9464";
        String reg = "A6-ARJ";
        String st = "RKT";
        if (caseId != null && caseId != 0) {
            List<Map<String, Object>> fl = watch(scn(scenarioId), caseId, null);
            Map<String, Object> d = null;
            for (Map<String, Object> f : fl) {
                if (truthy(f.get("diverted_to"))) {
                    d = f;
                    break;
                }
            }
            if (d == null && !fl.isEmpty()) {
                d = fl.get(0);
            }
            if (d != null) {
                flight = str(d.get("flight_no"));
                reg = truthy(d.get("registration")) ? str(d.get("registration")) : reg;
                st = str(Text.or(d.get("diverted_to"), d.get("dep_iata")));
            }
        }
        return map("ai", false, "model", null, "items", List.of(
                "Which crew runs out of legality next?",
                "What is the next deadline?",
                "Where is " + reg + " and what is it waiting for?",
                "What time must " + flight + " leave to land legal?",
                "Who can replace the " + flight + " captain without breaking rosters?",
                "What is waiting for approval?",
                "Summarise the situation",
                "Draft a message to " + st + " station about " + flight));
    }
}
