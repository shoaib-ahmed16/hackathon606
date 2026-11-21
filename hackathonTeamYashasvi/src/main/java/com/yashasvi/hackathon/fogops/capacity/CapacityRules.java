package com.yashasvi.hackathon.fogops.capacity;

import com.yashasvi.hackathon.fogops.api.ApiException;
import org.springframework.http.HttpStatus;

import java.math.BigInteger;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Request rules for the capacity API, kept free of Spring and the database so they can be unit-tested. */
public final class CapacityRules {

    public static final Set<String> WRITERS = Set.of("OCC", "ADMIN");
    public static final int MIN = 0;
    public static final int MAX = 200;
    public static final int BASIS_MAX = 500;
    private static final Pattern IATA = Pattern.compile("^[A-Za-z]{3}$");

    private CapacityRules() {
    }

    /** What a person says to assume. A null number means "not stated", it is never turned into 0. */
    public record Setting(Integer standsAssumed, Integer arrivalsPerHrAssumed, String basis) {
    }

    public static void requireWriter(String role) {
        if (role == null || !WRITERS.contains(role)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "Only OCC or ADMIN can do this");
        }
    }

    public static String iata(String raw) {
        if (raw == null || !IATA.matcher(raw.trim()).matches()) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "iata must be a 3-letter airport code");
        }
        return raw.trim().toUpperCase();
    }

    /** Body {stands_assumed, arrivals_per_hr_assumed, basis}: whole numbers 0..200 (at least one), basis required. */
    public static Setting parse(Map<String, Object> body) {
        if (body == null) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "Request body is required");
        }
        Integer stands = whole(body.get("stands_assumed"), "stands_assumed");
        Integer arrivals = whole(body.get("arrivals_per_hr_assumed"), "arrivals_per_hr_assumed");
        if (stands == null && arrivals == null) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "Give stands_assumed, arrivals_per_hr_assumed or both");
        }
        Object b = body.get("basis");
        if (!(b instanceof String s) || s.isBlank()) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "basis is required: say who or what states this capacity");
        }
        if (s.trim().length() > BASIS_MAX) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "basis must be at most " + BASIS_MAX + " characters");
        }
        return new Setting(stands, arrivals, s.trim());
    }

    private static Integer whole(Object v, String field) {
        if (v == null) {
            return null;
        }
        long n;
        if (v instanceof Integer || v instanceof Long || v instanceof Short || v instanceof Byte) {
            n = ((Number) v).longValue();
        } else if (v instanceof BigInteger bi && bi.bitLength() < 63) {
            n = bi.longValue();
        } else {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, field + " must be a whole number between " + MIN + " and " + MAX);
        }
        if (n < MIN || n > MAX) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, field + " must be between " + MIN + " and " + MAX);
        }
        return (int) n;
    }

    /** Query-parameter bound; a missing value takes the default. */
    public static int bounded(Integer v, String name, int lo, int hi, int dflt) {
        if (v == null) {
            return dflt;
        }
        if (v < lo || v > hi) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, name + " must be between " + lo + " and " + hi);
        }
        return v;
    }

    /** Remaining-capacity ordering for "which alternate has the most room": the tighter of the two dimensions, unknown last. */
    public static int roomScore(Integer standsFreeAfter, Integer arrivalSlotsAfter) {
        if (standsFreeAfter == null && arrivalSlotsAfter == null) {
            return Integer.MIN_VALUE;
        }
        if (standsFreeAfter == null) {
            return arrivalSlotsAfter;
        }
        if (arrivalSlotsAfter == null) {
            return standsFreeAfter;
        }
        return Math.min(standsFreeAfter, arrivalSlotsAfter);
    }
}
