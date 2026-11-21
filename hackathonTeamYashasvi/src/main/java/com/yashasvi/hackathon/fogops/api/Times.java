package com.yashasvi.hackathon.fogops.api;

import org.springframework.http.HttpStatus;

import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeParseException;

/** ISO-8601 parsing for request values. A time without an offset is read as UTC (the OCC files are UTC). */
public final class Times {

    private Times() {
    }

    public static OffsetDateTime parse(String name, String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String v = value.trim().replace(' ', '+');   // "+" in a query string arrives as a space
        try {
            return OffsetDateTime.parse(v).withOffsetSameInstant(ZoneOffset.UTC);
        } catch (DateTimeParseException e) {
            try {
                return LocalDateTime.parse(v).atOffset(ZoneOffset.UTC);
            } catch (DateTimeParseException e2) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, name + " must be an ISO-8601 date-time");
            }
        }
    }
}
