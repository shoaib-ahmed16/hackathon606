package com.yashasvi.hackathon.fogops.capacity;

import com.fasterxml.jackson.databind.JsonNode;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.db.FogDb;
import com.yashasvi.hackathon.fogops.write.FogTx;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static com.yashasvi.hackathon.fogops.write.FogTx.p;

/**
 * Airport capacity: stands, arrivals per hour and occupancy, each with its source. All numbers come from the SQL functions
 * (airport_capacity_assess and friends in migration 003); this class only shapes them for the screen. Reads are read-only,
 * so what-if questions never touch scenario or baseline data. The one write is the OCC/ADMIN assumption.
 */
@Service
public class CapacityService {

    private static final String AIRPORTS = """
            SELECT a.iata, a.name, a.is_hub,
                   c.stands_assumed, c.arrivals_per_hr_assumed, c.basis AS configured_basis,
                   c.updated_at AS configured_updated_at, u.display_name AS configured_by
              FROM airport a
              LEFT JOIN airport_capacity c ON c.iata = a.iata
              LEFT JOIN app_user u ON u.user_id = c.updated_by
             WHERE a.is_hub OR a.iata IN (SELECT alt_iata FROM alternate_airport WHERE is_active)
             ORDER BY a.is_hub DESC, a.iata""";

    private static final String AIRPORT_ONE = """
            SELECT a.iata, a.name, a.is_hub,
                   c.stands_assumed, c.arrivals_per_hr_assumed, c.basis AS configured_basis,
                   c.updated_at AS configured_updated_at, u.display_name AS configured_by
              FROM airport a
              LEFT JOIN airport_capacity c ON c.iata = a.iata
              LEFT JOIN app_user u ON u.user_id = c.updated_by
             WHERE a.iata = CAST(:iata AS char(3))
               AND (a.is_hub OR a.iata IN (SELECT alt_iata FROM alternate_airport WHERE is_active))""";

    private static final String ASSESS = """
            SELECT airport_capacity_assess(CAST(:scn AS integer), CAST(:iata AS char(3)), CAST(:arr AS timestamptz),
                   CAST(:extra AS integer), CAST(:flight AS bigint), CAST(:delay AS integer), CAST(:win AS integer)) AS a""";

    private final FogDb db;
    private final FogTx tx;

    public CapacityService(FogDb db, FogTx tx) {
        this.db = db;
        this.tx = tx;
    }

    public Integer scenario(Integer scenarioId) {
        Integer s = scenarioId != null ? scenarioId : db.liveScenarioId();
        if (s == null) {
            throw new ApiException(HttpStatus.NOT_FOUND, "No active scenario");
        }
        return s;
    }

    private JsonNode assess(int scn, String iata, OffsetDateTime arrival, int extra, Long flightId, int delay, int window) {
        List<Map<String, Object>> r = db.fetch(ASSESS, p("scn", scn, "iata", iata, "arr", arrival, "extra", extra,
                "flight", flightId, "delay", delay, "win", window));
        return (JsonNode) r.get(0).get("a");
    }

    public Map<String, Object> airport(String iata) {
        List<Map<String, Object>> r = db.fetch(AIRPORT_ONE, p("iata", iata));
        if (r.isEmpty()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Airport " + iata + " is not a hub or an alternate");
        }
        return r.get(0);
    }

    /** One row per hub and alternate: effective values, where each comes from, current occupancy, history. */
    public List<Map<String, Object>> overview(int scn) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> ap : db.fetch(AIRPORTS)) {
            out.add(row(ap, assess(scn, (String) ap.get("iata"), null, 0, null, 0, 6)));
        }
        return out;
    }

    public Map<String, Object> overviewRow(int scn, String iata) {
        return row(airport(iata), assess(scn, iata, null, 0, null, 0, 6));
    }

    private static Object v(JsonNode n) {
        if (n == null || n.isNull() || n.isMissingNode()) {
            return null;
        }
        if (n.isInt() || n.isLong()) {
            return n.asLong() >= Integer.MIN_VALUE && n.asLong() <= Integer.MAX_VALUE ? (Object) n.asInt() : (Object) n.asLong();
        }
        if (n.isBoolean()) {
            return n.asBoolean();
        }
        return n.isNumber() ? n.numberValue() : n.asText();
    }

    private static String latest(Object... iso) {
        String best = null;
        for (Object o : iso) {
            if (o != null && (best == null || o.toString().compareTo(best) > 0)) {
                best = o.toString();
            }
        }
        return best;
    }

    private static Map<String, Object> row(Map<String, Object> ap, JsonNode j) {
        JsonNode st = j.path("stands");
        JsonNode ar = j.path("arrivals_per_hr");
        JsonNode oc = j.path("occupancy");
        JsonNode hi = j.path("history");
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("airport", ap.get("iata"));
        m.put("name", ap.get("name"));
        m.put("is_hub", ap.get("is_hub"));
        m.put("airport_op_status", v(j.get("airport_op_status")));
        m.put("stands_total", v(st.get("total")));
        m.put("stands_source", v(st.get("source")));
        m.put("stands_quality", v(st.get("quality")));
        m.put("stands_basis", v(st.get("basis")));
        m.put("stands_as_of_utc", v(st.get("as_of_utc")));
        Object known = v(oc.get("on_ground_now_known_departure"));
        Object unknown = v(oc.get("on_ground_now_no_known_departure"));
        // no movement to this airport in the data = occupancy is UNKNOWN (null), never 0; a person's status entry still stands
        boolean evidence = oc.path("movement_evidence").asBoolean(false);
        boolean fromEntry = "STATUS_EVENT".equals(v(st.get("source")));
        m.put("occupied_stands", !evidence || known == null ? null : (Integer) known + (Integer) unknown);
        m.put("occupied_without_known_departure", evidence ? unknown : null);
        m.put("movement_evidence", evidence);
        m.put("available_stands", evidence || fromEntry ? v(st.get("free_before")) : null);
        m.put("arrivals_per_hr", v(ar.get("capacity")));
        m.put("arrivals_source", v(ar.get("source")));
        m.put("arrivals_quality", v(ar.get("quality")));
        m.put("arrivals_basis", v(ar.get("basis")));
        m.put("arrivals_as_of_utc", v(ar.get("as_of_utc")));
        m.put("projected_arrivals", v(ar.get("projected_in_hour")));
        m.put("remaining_arrival_capacity", v(ar.get("remaining_after")));
        m.put("history_sample_n", v(hi.get("sample_n")));
        m.put("history_min_sample_hours", v(hi.get("min_sample_hours")));
        m.put("history_peak_arrivals_per_hr", v(hi.get("peak_arrivals_per_hr")));
        m.put("history_peak_ground", v(hi.get("peak_ground")));
        m.put("configured_stands", ap.get("stands_assumed"));
        m.put("configured_arrivals_per_hr", ap.get("arrivals_per_hr_assumed"));
        m.put("configured_basis", ap.get("configured_basis"));
        m.put("configured_by", ap.get("configured_by"));
        m.put("configured_updated_at", ap.get("configured_updated_at"));
        m.put("outcome", v(j.get("outcome")));
        m.put("verification_required", v(j.get("verification_required")));
        m.put("occupancy_verified", false);
        m.put("occupancy_basis", v(oc.get("basis")));
        m.put("computed_at_utc", v(j.get("scenario_now_utc")));
        m.put("last_updated_utc", latest(v(st.get("as_of_utc")), v(ar.get("as_of_utc")), ap.get("configured_updated_at") == null ? null : ap.get("configured_updated_at").toString()));
        m.put("reasons", j.get("reasons"));
        return m;
    }

    /** Everything for the detail panel of one airport: assessment now, hourly outlook, history, traffic lists. */
    public Map<String, Object> detail(int scn, String iata, int windowHours) {
        Map<String, Object> ap = airport(iata);
        JsonNode now = assess(scn, iata, null, 0, null, 0, windowHours);
        Map<String, Object> m = new LinkedHashMap<>(row(ap, now));
        m.put("assessment", now);
        m.put("history", db.fetch("SELECT * FROM airport_history_capacity(CAST(:iata AS char(3)))", p("iata", iata)).get(0));
        m.put("history_profile", db.fetch("SELECT airport_history_profile(CAST(:iata AS char(3))) AS p", p("iata", iata)).get(0).get("p"));
        Map<String, Object> w = p("scn", scn, "iata", iata);
        m.put("inbound", db.fetch("""
                SELECT s.flight_id, s.flight_no, s.registration, s.ta AS arrival_utc, s.ta_actual AS arrival_is_actual,
                       s.td AS departure_utc, s.diverted, f.dep_iata AS origin
                  FROM airport_stays(CAST(:scn AS integer), CAST(:iata AS char(3))) s JOIN flight f ON f.flight_id = s.flight_id
                 WHERE s.ta >= scenario_now(CAST(:scn AS integer)) - interval '1 hour'
                   AND s.ta <= scenario_now(CAST(:scn AS integer)) + interval '12 hours'
                 ORDER BY s.ta LIMIT 100""", w));
        m.put("on_ground", db.fetch("""
                SELECT s.flight_id, s.flight_no, s.registration, s.ta AS arrived_utc, s.ta_actual AS arrival_is_actual,
                       s.td AS departure_utc, s.diverted
                  FROM airport_stays(CAST(:scn AS integer), CAST(:iata AS char(3))) s
                 WHERE s.ta <= scenario_now(CAST(:scn AS integer))
                   AND ((s.td IS NOT NULL AND s.td > scenario_now(CAST(:scn AS integer)))
                        OR (s.td IS NULL AND s.ta_actual AND scenario_now(CAST(:scn AS integer)) - s.ta <= interval '48 hours'))
                 ORDER BY s.ta LIMIT 100""", w));
        m.put("outbound", db.fetch("""
                SELECT f.flight_id, f.flight_no, coalesce(fs.registration, f.registration_planned) AS registration, f.arr_iata AS destination,
                       coalesce(fs.atd_utc, fs.etd_utc, f.std_utc) AS departure_utc, (fs.atd_utc IS NOT NULL) AS departure_is_actual
                  FROM flight f LEFT JOIN flight_state fs ON fs.flight_id = f.flight_id AND fs.scenario_id = CAST(:scn AS integer)
                 WHERE f.dep_iata = CAST(:iata AS char(3)) AND NOT coalesce(fs.is_cancelled, FALSE)
                   AND coalesce(fs.atd_utc, fs.etd_utc, f.std_utc) BETWEEN scenario_now(CAST(:scn AS integer))
                       AND scenario_now(CAST(:scn AS integer)) + interval '12 hours'
                 ORDER BY 5 LIMIT 100""", w));
        return m;
    }

    /** Incoming-flight assessment and what-if for one airport (read-only). */
    public JsonNode assessment(int scn, String iata, OffsetDateTime arrival, int extra, Long flightId, int delay, int window) {
        airport(iata);
        return assess(scn, iata, arrival, extra, flightId, delay, window);
    }

    /** The same what-if across every active alternate, roomiest first (unknown last). */
    public List<Map<String, Object>> compare(int scn, OffsetDateTime arrival, int extra, Long flightId, int delay, int window) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> ap : db.fetch("SELECT DISTINCT a.iata, a.name FROM airport a JOIN alternate_airport aa ON aa.alt_iata = a.iata WHERE aa.is_active ORDER BY a.iata")) {
            JsonNode j = assess(scn, (String) ap.get("iata"), arrival, extra, flightId, delay, window);
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("airport", ap.get("iata"));
            m.put("name", ap.get("name"));
            m.put("outcome", v(j.get("outcome")));
            m.put("verification_required", v(j.get("verification_required")));
            m.put("arrival_utc", v(j.get("arrival_utc")));
            m.put("stands_free_before", v(j.path("stands").get("free_before")));
            m.put("stands_free_after", v(j.path("stands").get("free_after")));
            m.put("arrival_slots_before", v(j.path("arrivals_per_hr").get("remaining_before")));
            m.put("arrival_slots_after", v(j.path("arrivals_per_hr").get("remaining_after")));
            m.put("stands_source", v(j.path("stands").get("source")));
            m.put("arrivals_source", v(j.path("arrivals_per_hr").get("source")));
            m.put("first_constrained_hour_utc", firstConstrained(j.get("hourly")));
            out.add(m);
        }
        out.sort(Comparator.comparingInt((Map<String, Object> m) -> CapacityRules.roomScore((Integer) m.get("stands_free_after"), (Integer) m.get("arrival_slots_after"))).reversed());
        return out;
    }

    /** First hour of the outlook where adding the proposed flight(s) would leave one dimension constrained or exceeded. */
    static String firstConstrained(JsonNode hourly) {
        if (hourly == null || !hourly.isArray()) {
            return null;
        }
        for (JsonNode h : hourly) {
            JsonNode s = h.get("stands_free_with_proposed");
            JsonNode a = h.get("arrival_slots_left_with_proposed");
            boolean tight = (s != null && !s.isNull() && s.asInt() <= 1) || (a != null && !a.isNull() && a.asInt() <= 1);
            if (tight) {
                return h.get("hour_utc").asText();
            }
        }
        return null;
    }

    /** OCC/ADMIN states an assumption. One transaction as the signed-in person; the table's audit trigger records it. */
    public Map<String, Object> setCapacity(int userId, int scn, String iata, CapacityRules.Setting s) {
        airport(iata);
        tx.as(userId, t -> t.update("""
                INSERT INTO airport_capacity (iata, stands_assumed, arrivals_per_hr_assumed, basis, updated_by, updated_at)
                VALUES (CAST(:iata AS char(3)), CAST(:stands AS integer), CAST(:arr AS integer), :basis, :uid, now())
                ON CONFLICT (iata) DO UPDATE SET stands_assumed = EXCLUDED.stands_assumed,
                    arrivals_per_hr_assumed = EXCLUDED.arrivals_per_hr_assumed, basis = EXCLUDED.basis,
                    updated_by = EXCLUDED.updated_by, updated_at = now()""",
                p("iata", iata, "stands", s.standsAssumed() == null ? null : String.valueOf(s.standsAssumed()),
                        "arr", s.arrivalsPerHrAssumed() == null ? null : String.valueOf(s.arrivalsPerHrAssumed()),
                        "basis", s.basis(), "uid", userId)));
        return overviewRow(scn, iata);
    }
}
