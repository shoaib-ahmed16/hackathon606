package com.yashasvi.hackathon.fogops.console;

import com.fasterxml.jackson.databind.JsonNode;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;

/** Small formatting helpers for the explanation lines (display text only; stored times stay timezone-aware UTC). */
public final class Text {

    private static final DateTimeFormatter HM = DateTimeFormatter.ofPattern("HH:mm");

    private Text() {
    }

    /** UTC clock like 14:30Z, or "-" when unknown. */
    public static String z(Object ts) {
        return ts instanceof OffsetDateTime t ? t.withOffsetSameInstant(ZoneOffset.UTC).format(HM) + "Z" : "-";
    }

    /** Sharjah (UTC+4) clock like 18:30, or "-" when unknown. */
    public static String local(Object ts) {
        return ts instanceof OffsetDateTime t ? t.withOffsetSameInstant(ZoneOffset.ofHours(4)).format(HM) : "-";
    }

    /** Python-style text of a value: null -> None, numbers without exponent. */
    public static String str(Object o) {
        if (o == null) {
            return "None";
        }
        if (o instanceof BigDecimal b) {
            return b.toPlainString();
        }
        if (o instanceof Boolean b) {
            return b ? "True" : "False";
        }
        if (o instanceof JsonNode n) {
            return n.isTextual() ? n.asText() : n.toString();
        }
        return String.valueOf(o);
    }

    /** Python truthiness: null, false, 0 and empty text are false. */
    public static boolean truthy(Object o) {
        if (o == null) {
            return false;
        }
        if (o instanceof Boolean b) {
            return b;
        }
        if (o instanceof Number n) {
            return new BigDecimal(n.toString()).signum() != 0;
        }
        if (o instanceof CharSequence s) {
            return s.length() > 0;
        }
        if (o instanceof JsonNode n) {
            if (n.isNull() || n.isMissingNode()) {
                return false;
            }
            if (n.isBoolean()) {
                return n.asBoolean();
            }
            if (n.isNumber()) {
                return n.decimalValue().signum() != 0;
            }
            if (n.isTextual()) {
                return !n.asText().isEmpty();
            }
            return n.size() > 0;
        }
        return true;
    }

    public static BigDecimal dec(Object o) {
        return o == null ? null : new BigDecimal(o.toString());
    }

    /** The first value that is truthy, else the last one (Python "a or b"). */
    public static Object or(Object a, Object b) {
        return truthy(a) ? a : b;
    }
}
