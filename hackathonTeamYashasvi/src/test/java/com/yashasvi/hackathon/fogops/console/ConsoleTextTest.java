package com.yashasvi.hackathon.fogops.console;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ConsoleTextTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    @Test
    void utcAndSharjahClocks() {
        OffsetDateTime t = OffsetDateTime.of(2026, 11, 21, 21, 5, 0, 0, ZoneOffset.UTC);
        assertEquals("21:05Z", Text.z(t));
        assertEquals("01:05", Text.local(t));          // UTC+4 crosses midnight
        assertEquals("-", Text.z(null));
        assertEquals("-", Text.local(null));
    }

    @Test
    void pythonStyleTruthinessAndText() {
        assertFalse(Text.truthy(null));
        assertFalse(Text.truthy(0));
        assertFalse(Text.truthy(""));
        assertTrue(Text.truthy(new BigDecimal("0.5")));
        assertEquals("None", Text.str(null));
        assertEquals("45", Text.str(new BigDecimal("45")));
        assertEquals("True", Text.str(true));
    }

    private static Map<String, Object> row(String entityType, String action, String entityId, String afterJson, List<Object> changed) throws Exception {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("entity_type", entityType);
        r.put("action", action);
        r.put("entity_id", entityId);
        r.put("after_data", afterJson == null ? null : JSON.readTree(afterJson));
        r.put("changed_fields", changed);
        return r;
    }

    @Test
    void apiRowsReadAsSentences() throws Exception {
        assertEquals("Signed in", AuditSummary.of(row("api", "POST", "/api/auth/login", "{\"path\":\"/api/auth/login\",\"ok\":true}", null)));
        assertEquals("Executed a diversion - REFUSED (403)",
                AuditSummary.of(row("api", "POST", "x", "{\"path\":\"/api/decisions/5/execute-diversion\",\"ok\":false,\"status\":403}", null)));
        assertEquals("Recorded a case comment: Fog ahead",
                AuditSummary.of(row("api", "POST", "x", "{\"path\":\"/api/records/case_comment\",\"body\":{\"title\":\"Fog ahead\"}}", null)));
    }

    @Test
    void changeRowsListStatusAndChangedFields() throws Exception {
        assertEquals("Update decision #7 - APPROVED (status)",
                AuditSummary.of(row("decision", "UPDATE", "7", "{\"status\":\"APPROVED\"}", List.of("status"))));
        assertEquals("Insert flight state #9", AuditSummary.of(row("flight_state", "INSERT", "9", null, null)));
    }
}
