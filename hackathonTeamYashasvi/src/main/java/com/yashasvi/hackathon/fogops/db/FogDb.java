package com.yashasvi.hackathon.fogops.db;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Thin read access to the fogops schema (the connection search_path is "fogops, public"). */
@Component
public class FogDb {

    private final NamedParameterJdbcTemplate jdbc;
    private final FogRows rows;

    public FogDb(NamedParameterJdbcTemplate jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.rows = new FogRows(json);
    }

    public NamedParameterJdbcTemplate jdbc() {
        return jdbc;
    }

    public List<Map<String, Object>> fetch(String sql, Map<String, ?> params) {
        return jdbc.query(sql, new MapSqlParameterSource(params == null ? Map.of() : params), rows);
    }

    public List<Map<String, Object>> fetch(String sql) {
        return fetch(sql, null);
    }

    /**
     * SELECT * FROM a view with optional equality filters (null values are skipped).
     * {@code view}, the column names and {@code order} are always code-supplied constants, never user input.
     */
    public List<Map<String, Object>> view(String view, Map<String, Object> filters, String order, int limit) {
        List<String> where = new ArrayList<>();
        MapSqlParameterSource p = new MapSqlParameterSource();
        if (filters != null) {
            filters.forEach((col, v) -> {
                if (v != null) {
                    where.add(col + " = :" + col);
                    p.addValue(col, v);
                }
            });
        }
        String sql = "SELECT * FROM " + view + (where.isEmpty() ? "" : " WHERE " + String.join(" AND ", where))
                + (order == null ? "" : " " + order) + " LIMIT " + limit;
        return jdbc.query(sql, p, rows);
    }

    /** The active LIVE scenario (no scenario_id in a request means LIVE). */
    public Integer liveScenarioId() {
        List<Integer> ids = jdbc.getJdbcTemplate().queryForList(
                "SELECT scenario_id FROM scenario WHERE kind = 'LIVE' AND is_active ORDER BY scenario_id LIMIT 1", Integer.class);
        return ids.isEmpty() ? null : ids.get(0);
    }
}
