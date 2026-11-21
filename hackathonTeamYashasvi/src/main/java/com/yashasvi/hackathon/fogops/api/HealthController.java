package com.yashasvi.hackathon.fogops.api;

import com.yashasvi.hackathon.fogops.db.FogDb;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/** UP, plus whether the database has the current schema (hold/divert engine and LVP columns). Open (no sign-in). */
@RestController
public class HealthController {

    private final FogDb db;

    public HealthController(FogDb db) {
        this.db = db;
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        boolean ok = !db.fetch("SELECT 1 AS ok").isEmpty();
        Object current = db.fetch("""
                SELECT to_regproc('fogops.propose_hold_or_divert') IS NOT NULL AND EXISTS (
                       SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'fogops' AND table_name = 'airport_status_event' AND column_name = 'lvp_in_force') AS ok
                """).get(0).get("ok");
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", "UP");
        m.put("db", ok);
        m.put("schema", Boolean.TRUE.equals(current) ? "current" : "OUTDATED: rebuild the database from fogops_db");
        m.put("migration", migrationLevel());
        return m;
    }

    /** The last Flyway script that was applied (the original API reports its own migration file the same way). */
    private Object migrationLevel() {
        try {
            var rows = db.fetch("SELECT script FROM public.flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1");
            return rows.isEmpty() ? null : rows.get(0).get("script");
        } catch (RuntimeException e) {
            return null;
        }
    }
}
