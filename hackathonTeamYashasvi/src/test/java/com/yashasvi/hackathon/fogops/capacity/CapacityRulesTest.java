package com.yashasvi.hackathon.fogops.capacity;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.console.AuditSummary;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class CapacityRulesTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    private static Map<String, Object> body(Object stands, Object arrivals, Object basis) {
        Map<String, Object> m = new HashMap<>();
        m.put("stands_assumed", stands);
        m.put("arrivals_per_hr_assumed", arrivals);
        m.put("basis", basis);
        return m;
    }

    private static ApiException refused(Map<String, Object> b) {
        return assertThrows(ApiException.class, () -> CapacityRules.parse(b));
    }

    @Test
    void onlyOccAndAdminMayWrite() {
        assertDoesNotThrow(() -> CapacityRules.requireWriter("OCC"));
        assertDoesNotThrow(() -> CapacityRules.requireWriter("ADMIN"));
        for (String role : new String[]{"DISPATCH", "CREW_CONTROL", "RECOVERY", "STATION", "AGENT", null}) {
            assertEquals(HttpStatus.FORBIDDEN, assertThrows(ApiException.class, () -> CapacityRules.requireWriter(role)).getStatus());
        }
    }

    @Test
    void validRequestIsAccepted() {
        CapacityRules.Setting s = CapacityRules.parse(body(20, 8, "  Capacity assumption confirmed by OCC "));
        assertEquals(20, s.standsAssumed());
        assertEquals(8, s.arrivalsPerHrAssumed());
        assertEquals("Capacity assumption confirmed by OCC", s.basis());
        assertDoesNotThrow(() -> CapacityRules.parse(body(0, 200, "x")));
    }

    @Test
    void valuesOutsideZeroTo200Give422WithAStringDetail() {
        for (Object bad : new Object[]{-1, 201, 1000, Long.MAX_VALUE}) {
            ApiException e = refused(body(bad, 5, "x"));
            assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, e.getStatus());
            assertNotNull(e.getMessage());
            assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, refused(body(5, bad, "x")).getStatus());
        }
    }

    @Test
    void numbersMustBeWholeNumbers() {
        for (Object bad : new Object[]{3.5, "7", true, 7.0}) {
            assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, refused(body(bad, 5, "x")).getStatus());
        }
    }

    @Test
    void basisIsMandatory() {
        for (Object bad : new Object[]{null, "", "   ", 5}) {
            ApiException e = refused(body(10, 5, bad));
            assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, e.getStatus());
            assertEquals(true, e.getMessage().contains("basis"));
        }
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, refused(body(10, 5, "x".repeat(CapacityRules.BASIS_MAX + 1))).getStatus());
    }

    @Test
    void missingNumberStaysNullAndNeverBecomesZero() {
        CapacityRules.Setting s = CapacityRules.parse(body(12, null, "stands only"));
        assertEquals(12, s.standsAssumed());
        assertNull(s.arrivalsPerHrAssumed());
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, refused(body(null, null, "x")).getStatus());
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, assertThrows(ApiException.class, () -> CapacityRules.parse(null)).getStatus());
    }

    @Test
    void iataCodeIsValidated() {
        assertEquals("RKT", CapacityRules.iata(" rkt "));
        for (String bad : new String[]{"RK", "RKTX", "R1T", "", null}) {
            assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, assertThrows(ApiException.class, () -> CapacityRules.iata(bad)).getStatus());
        }
    }

    @Test
    void queryBoundsAreEnforced() {
        assertEquals(0, CapacityRules.bounded(null, "extra", 0, 50, 0));
        assertEquals(3, CapacityRules.bounded(3, "extra", 0, 50, 0));
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, assertThrows(ApiException.class, () -> CapacityRules.bounded(51, "extra", 0, 50, 0)).getStatus());
    }

    @Test
    void roomestAlternateIsTheTighterDimensionAndUnknownIsLast() {
        assertEquals(2, CapacityRules.roomScore(5, 2));
        assertEquals(4, CapacityRules.roomScore(null, 4));
        assertEquals(Integer.MIN_VALUE, CapacityRules.roomScore(null, null));
    }

    @Test
    void firstConstrainedHourIsFoundFromTheOutlook() throws Exception {
        var ok = JSON.readTree("[{\"hour_utc\":\"h1\",\"stands_free_with_proposed\":5,\"arrival_slots_left_with_proposed\":3},"
                + "{\"hour_utc\":\"h2\",\"stands_free_with_proposed\":1,\"arrival_slots_left_with_proposed\":3}]");
        assertEquals("h2", CapacityService.firstConstrained(ok));
        assertNull(CapacityService.firstConstrained(JSON.readTree("[{\"hour_utc\":\"h1\",\"stands_free_with_proposed\":null,\"arrival_slots_left_with_proposed\":null}]")));
    }

    @Test
    void auditLineSaysSetAirportCapacity() throws Exception {
        Map<String, Object> row = new HashMap<>();
        row.put("action", "PUT");
        row.put("entity_type", "api");
        row.put("entity_id", "/api/airports/FJR/capacity");
        row.put("after_data", JSON.readTree("{\"path\":\"/api/airports/FJR/capacity\",\"ok\":true,\"body\":{\"basis\":\"OCC\"}}"));
        assertEquals("Set airport capacity", AuditSummary.of(row));
        row.put("after_data", JSON.readTree("{\"path\":\"/api/airports/FJR/capacity\",\"ok\":false,\"status\":403}"));
        assertEquals("Set airport capacity - REFUSED (403)", AuditSummary.of(row));
    }
}
