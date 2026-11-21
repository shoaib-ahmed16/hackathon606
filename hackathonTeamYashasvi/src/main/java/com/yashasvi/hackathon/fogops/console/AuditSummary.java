package com.yashasvi.hackathon.fogops.console;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** One readable line per audit row ("Signed in", "Executed a diversion - REFUSED (403)", ...). */
public final class AuditSummary {

    private static final String[][] FRIENDLY = {
            {"/api/auth/login", "Signed in"}, {"/api/auth/logout", "Signed out"}, {"/api/ask", "Asked the assistant"},
            {"/api/cases/create", "Created a case"}, {"/api/events/flight", "Sent a flight feed event"}, {"/api/feed/push", "Pushed the live data feed"},
            {"/api/crew/swap", "Executed a crew swap"}, {"/api/recovery/build", "Built a recovery plan"},
            {"/api/scenarios/clone", "Cloned a scenario"}, {"/api/whatif", "Ran a what-if"},
    };
    private static final String[] BITS = {"decision_type", "status", "verdict", "op_status", "rec_type", "alternate_iata", "phase"};

    private AuditSummary() {
    }

    private static JsonNode obj(Object o) {
        return o instanceof JsonNode n && n.isObject() ? n : null;
    }

    private static Object get(JsonNode n, String key) {
        JsonNode v = n == null ? null : n.get(key);
        return v == null || v.isNull() ? null : v;
    }

    @SuppressWarnings("unchecked")
    public static String of(Map<String, Object> row) {
        String action = (String) row.get("action");
        String entityType = (String) row.get("entity_type");
        JsonNode d = obj(row.get("after_data"));
        if ("api".equals(entityType)) {
            Object p = Text.or(get(d, "path"), row.get("entity_id"));
            String path = Text.str(p);
            JsonNode body = obj(get(d, "body"));
            String what = null;
            for (String[] f : FRIENDLY) {
                if (path.equals(f[0])) {
                    what = f[1];
                }
            }
            if (what == null) {
                if (path.endsWith("/recommend")) what = "Re-ran the recommendation engine";
                else if (path.endsWith("/recompute")) what = "Recomputed legality";
                else if (path.endsWith("/execute-diversion")) what = "Executed a diversion";
                else if (path.endsWith("/close")) what = "Closed a case";
                else if (path.endsWith("/report")) what = "Generated a report";
                else if (path.contains("/approve")) what = "Approved a recovery plan";
                else if (path.startsWith("/api/diversions/")) what = "Station update";
                else if (path.startsWith("/api/records/"))
                    what = "Recorded a " + path.substring(path.lastIndexOf('/') + 1).replace('_', ' ');
                else if ("DELETE".equals(action)) what = "Deleted";
                else what = action + " " + path;
            }
            Object extra = Text.or(Text.or(get(body, "question"), get(body, "title")), get(body, "username"));
            String x = Text.truthy(extra) ? Text.str(extra) : "";
            JsonNode ok = d == null ? null : d.get("ok");
            boolean fine = ok == null || Text.truthy(ok);
            String res = fine ? "" : " - REFUSED (" + Text.str(get(d, "status")) + ")";
            return what + (x.isEmpty() ? "" : ": " + (x.length() > 120 ? x.substring(0, 120) : x)) + res;
        }
        String et = entityType.replace('_', ' ');
        List<String> bits = new ArrayList<>();
        for (String k : BITS) {
            Object v = get(d, k);
            if (Text.truthy(v)) {
                bits.add(Text.str(v));
            }
        }
        List<Object> changed = (List<Object>) row.get("changed_fields");
        String fields = changed != null && !changed.isEmpty() && "UPDATE".equals(action)
                ? " (" + String.join(", ", changed.stream().map(Text::str).toList()) + ")" : "";
        String title = action.isEmpty() ? action : action.substring(0, 1).toUpperCase() + action.substring(1).toLowerCase();
        return title + " " + et + " #" + row.get("entity_id") + (bits.isEmpty() ? "" : " - " + String.join(", ", bits)) + fields;
    }
}
