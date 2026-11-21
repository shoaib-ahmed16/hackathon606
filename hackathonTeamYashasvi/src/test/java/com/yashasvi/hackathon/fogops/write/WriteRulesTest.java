package com.yashasvi.hackathon.fogops.write;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.yashasvi.hackathon.fogops.api.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.util.Map;
import java.util.TreeSet;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class WriteRulesTest {

    private static final ObjectMapper JSON = new ObjectMapper();

    private static WriteController.Swap swap(long duty, int out, int in, Integer caseId) {
        return new WriteController.Swap(2, caseId, duty, out, in, "r", null, "SHJ", 1, null, null, 7L);
    }

    private static Map<String, Object> decision(String details, Integer caseId) throws Exception {
        return Map.of("status", "APPROVED", "decision_type", "CREW_REPLACE", "case_id", caseId, "details", JSON.readTree(details));
    }

    @Test
    void swapMustBeTheOneThatWasApproved() throws Exception {
        Map<String, Object> d = decision("{\"duty_id\":100,\"out_crew_id\":5,\"in_crew_id\":6}", 9);
        assertDoesNotThrow(() -> WriteController.requireSameAsApproved(d, swap(100, 5, 6, 9)));
        assertDoesNotThrow(() -> WriteController.requireSameAsApproved(d, swap(100, 5, 6, null)));
        for (WriteController.Swap other : new WriteController.Swap[]{swap(101, 5, 6, 9), swap(100, 7, 6, 9), swap(100, 5, 8, 9), swap(100, 5, 6, 10)}) {
            ApiException e = assertThrows(ApiException.class, () -> WriteController.requireSameAsApproved(d, other));
            assertEquals(HttpStatus.CONFLICT, e.getStatus());
        }
    }

    @Test
    void missingRequiredValuesAreRejectedWithAReadableMessage() {
        ApiException e = assertThrows(ApiException.class, () -> WriteController.need(null, "reason"));
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, e.getStatus());
        assertEquals("reason is required", e.getMessage());
        assertThrows(ApiException.class, () -> WriteController.need("  ", "reason"));
        assertEquals(5, WriteController.need(5, "n"));
    }

    @Test
    void unknownNamesAreListedLikeTheOriginalApi() {
        assertEquals("['a', 'b']", WriteController.names(new TreeSet<>(java.util.List.of("b", "a"))));
        assertEquals("[]", WriteController.names(new TreeSet<>()));
    }

    @Test
    void onlyWhitelistedTablesAndFieldsAreWritable() {
        assertEquals(10, WriteController.WRITABLE.size());
        assertEquals(false, WriteController.WRITABLE.contains("audit_log"));
        assertEquals(false, WriteController.WRITABLE.contains("app_user"));
        assertEquals(false, WriteController.DIVERSION_FIELDS.contains("updated_by"));
    }
}
