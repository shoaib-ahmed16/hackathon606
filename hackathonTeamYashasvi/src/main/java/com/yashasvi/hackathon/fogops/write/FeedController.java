package com.yashasvi.hackathon.fogops.write;

import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.api.Times;
import com.yashasvi.hackathon.fogops.auth.FogUser;
import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static com.yashasvi.hackathon.fogops.write.FogTx.p;

/**
 * Simulated live feed: one call pushes "what has happened by now" into the LIVE scenario. For every scheduled flight
 * that should have moved by as_of it sends OUT / OFF / ON / IN events through ingest_flight_event (the function a real
 * feed uses), so dedupe, out-of-order protection, status derivation, reassessment and audit behave as in production.
 * Safe to press repeatedly: message ids are fixed per flight and stage, so a stage already pushed comes back DUPLICATE.
 * Values a real source already filled are never overwritten. Cancelled, holding and diverted flights are left alone.
 * Airport status (fog, closures) is deliberately NOT simulated: it drives the cases and stays a human/OCC input.
 * Everything simulated carries its source (SIM_FEED) and fuel is labelled SIMULATED.
 * Deviation from the original API: only OCC or ADMIN may push, because it rewrites the LIVE picture.
 */
@RestController
@RequestMapping("/api/feed")
public class FeedController {

    private static final String SOURCE = "SIM_FEED";
    private static final Duration LOOKBACK = Duration.ofHours(36);   // do not replay older history than this
    private static final Set<String> ROLES = Set.of("OCC", "ADMIN");
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_OFFSET_DATE_TIME;

    private final FogTx tx;
    private final FogDb db;

    public FeedController(FogTx tx, FogDb db) {
        this.tx = tx;
        this.db = db;
    }

    private record Stage(String type, OffsetDateTime ts, Map<String, Object> payload) {
    }

    /** 2026-11-21T02:00:00+00:00: the same text the original API stores in the event payload (UTC, never "Z"). */
    private static String iso(OffsetDateTime t) {
        return t.withOffsetSameInstant(ZoneOffset.UTC).format(ISO).replaceAll("Z$", "+00:00");
    }

    private static OffsetDateTime time(Object o) {
        return o instanceof OffsetDateTime t ? t : null;
    }

    /** Stage events due by asOf. Actual values already in flight_state win over the simulated ones. */
    static List<Stage> plan(Map<String, Object> f, OffsetDateTime asOf) {
        long flightId = ((Number) f.get("flight_id")).longValue();
        long h = (flightId * 2654435761L) % 997;   // stable per flight, so repeat pushes agree
        Duration delay = Duration.ofMinutes(h % 16);               // 0-15 min late off blocks
        Duration taxiOut = Duration.ofMinutes(10 + h % 6);
        Duration taxiIn = Duration.ofMinutes(5);
        OffsetDateTime std = time(f.get("std_utc"));
        OffsetDateTime sta = time(f.get("sta_utc"));
        Duration block = Duration.between(std, sta);
        Duration air = block.minus(taxiOut).minus(taxiIn);
        if (air.compareTo(Duration.ofMinutes(10)) < 0) {
            air = Duration.ofMinutes(10);
        }
        OffsetDateTime atd = time(f.get("atd_utc")) != null ? time(f.get("atd_utc")) : std.plus(delay);
        OffsetDateTime toff = time(f.get("toff_utc")) != null ? time(f.get("toff_utc")) : atd.plus(taxiOut);
        OffsetDateTime tdown = time(f.get("tdown_utc")) != null ? time(f.get("tdown_utc")) : toff.plus(air);
        OffsetDateTime ata = time(f.get("ata_utc")) != null ? time(f.get("ata_utc")) : tdown.plus(taxiIn);

        Object[][] stages = {
                {"OUT", atd, "atd", f.get("atd_utc")}, {"OFF", toff, "toff", f.get("toff_utc")},
                {"ON", tdown, "tdown", f.get("tdown_utc")}, {"IN", ata, "ata", f.get("ata_utc")}};
        List<Stage> out = new ArrayList<>();
        for (Object[] st : stages) {
            OffsetDateTime ts = (OffsetDateTime) st[1];
            if (st[3] != null || ts.isAfter(asOf)) {
                continue;
            }
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put((String) st[2], iso(ts));
            if ("OUT".equals(st[0])) {
                payload.put("eta", iso(tdown));   // estimate shown while it is in the air
                if (f.get("pax_planned") != null && f.get("pax") == null) {
                    // simulated load factor of 85-96% of the planned passengers
                    payload.put("pax", Math.round(Math.rint(((Number) f.get("pax_planned")).doubleValue() * (0.85 + (h % 12) / 100.0))));
                }
            }
            out.add(new Stage((String) st[0], ts, payload));
        }
        return out;
    }

    @PostMapping("/push")
    public Map<String, Object> push(@RequestBody(required = false) Map<String, Object> body, @AuthenticationPrincipal FogUser u) {
        if (!ROLES.contains(u.role())) {
            throw new ApiException(HttpStatus.FORBIDDEN, "Only OCC or ADMIN can do this");
        }
        OffsetDateTime parsed = body == null || body.get("as_of") == null ? null : Times.parse("as_of", String.valueOf(body.get("as_of")));
        OffsetDateTime asOf = parsed != null ? parsed : OffsetDateTime.now(ZoneOffset.UTC);
        Integer scn = db.liveScenarioId();

        return tx.as(u.userId(), t -> {
            Map<String, Integer> counts = new LinkedHashMap<>();
            int touched = 0;
            List<Map<String, Object>> rows = t.rows("""
                    SELECT f.flight_id, f.std_utc, f.sta_utc, f.pax_planned, s.pax,
                           s.atd_utc, s.toff_utc, s.tdown_utc, s.ata_utc
                      FROM flight f
                      LEFT JOIN flight_state s ON s.scenario_id = :scn AND s.flight_id = f.flight_id
                     WHERE f.flight_kind = 'SCHEDULED'
                       AND f.std_utc <= :as_of AND f.std_utc >= :since
                       AND s.ata_utc IS NULL
                       AND coalesce(s.is_cancelled, FALSE) = FALSE
                       AND coalesce(s.is_holding, FALSE) = FALSE
                       AND (s.actual_arr_iata IS NULL OR s.actual_arr_iata = f.arr_iata)
                       AND NOT EXISTS (SELECT 1 FROM diversion d
                                        WHERE d.scenario_id = :scn AND d.original_flight_id = f.flight_id)
                     ORDER BY f.std_utc""", p("scn", scn, "as_of", asOf, "since", asOf.minus(LOOKBACK)));
            for (Map<String, Object> f : rows) {
                List<Stage> events = plan(f, asOf);
                if (events.isEmpty()) {
                    continue;
                }
                touched++;
                for (Stage e : events) {
                    Map<String, Object> res = t.one("""
                            SELECT ingest_flight_event(CAST(:s AS int), :src, :mid, CAST(:f AS bigint), :et,
                                   CAST(:ts AS timestamptz), CAST(:pl AS jsonb), NULL) AS r""",
                            p("s", scn, "src", SOURCE, "mid", "PUSH-" + f.get("flight_id") + "-" + e.type(), "f", f.get("flight_id"),
                                    "et", e.type(), "ts", e.ts(), "pl", e.payload()));
                    counts.merge(String.valueOf(res.get("r")), 1, Integer::sum);
                }
            }
            // crew, standby and fuel follow what the flights just did (state is read after the events above)
            int dutiesActive = t.update("""
                    UPDATE crew_duty d SET status = 'ACTIVE'
                     WHERE d.status = 'PLANNED'
                       AND EXISTS (SELECT 1 FROM crew_duty_leg l JOIN flight_state s
                                     ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
                                    WHERE l.scenario_id = :scn AND l.duty_id = d.duty_id AND l.is_active
                                      AND s.atd_utc IS NOT NULL)""", p("scn", scn));
            int dutiesDone = t.update("""
                    UPDATE crew_duty d SET status = 'COMPLETED'
                     WHERE d.status IN ('PLANNED','ACTIVE')
                       AND EXISTS (SELECT 1 FROM crew_duty_leg l WHERE l.scenario_id = :scn AND l.duty_id = d.duty_id AND l.is_active)
                       AND NOT EXISTS (SELECT 1 FROM crew_duty_leg l
                                         LEFT JOIN flight_state s ON s.scenario_id = l.scenario_id AND s.flight_id = l.flight_id
                                        WHERE l.scenario_id = :scn AND l.duty_id = d.duty_id AND l.is_active
                                          AND s.ata_utc IS NULL)""", p("scn", scn));
            int standbyReleased = t.update("UPDATE standby_slot SET status = 'RELEASED' WHERE status = 'AVAILABLE' AND end_utc < :as_of",
                    p("as_of", asOf));
            int fuel = t.update("""
                    INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg,
                                                      burn_rate_hold_kg_per_hr, est_holding_endurance_min, quality, basis)
                    SELECT s.scenario_id, s.flight_id, :as_of, fob.kg, 2300, 2400,
                           GREATEST(0, ((fob.kg - 2300) * 60 / 2400)), 'SIMULATED',
                           jsonb_build_object('from', 'simulated live feed: planned fuel less cruise burn since take-off')
                      FROM flight_state s
                      CROSS JOIN LATERAL (SELECT GREATEST(2500, 6500 + (s.flight_id % 20) * 100
                                               - (2400 * EXTRACT(EPOCH FROM (CAST(:as_of AS timestamptz) - s.toff_utc)) / 3600)::int) AS kg) fob
                     WHERE s.scenario_id = :scn AND s.toff_utc IS NOT NULL AND s.tdown_utc IS NULL
                       AND NOT EXISTS (SELECT 1 FROM flight_fuel_estimate e
                                        WHERE e.scenario_id = s.scenario_id AND e.flight_id = s.flight_id
                                          AND e.as_of_utc > CAST(:as_of AS timestamptz) - interval '10 minutes')""",
                    p("as_of", asOf, "scn", scn));
            int applied = counts.entrySet().stream().filter(e -> !"DUPLICATE".equals(e.getKey())).mapToInt(Map.Entry::getValue).sum();

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("as_of", asOf);
            out.put("scenario_id", scn);
            out.put("flights_updated", touched);
            out.put("events", counts);
            out.put("events_applied", applied);
            out.put("crew_duties_active", dutiesActive);
            out.put("crew_duties_completed", dutiesDone);
            out.put("standby_released", standbyReleased);
            out.put("fuel_estimates", fuel);
            return out;
        });
    }
}
