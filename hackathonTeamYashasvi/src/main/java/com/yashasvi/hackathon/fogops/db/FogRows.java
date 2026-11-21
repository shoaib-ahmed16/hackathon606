package com.yashasvi.hackathon.fogops.db;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.postgresql.util.PGobject;
import org.springframework.jdbc.core.RowMapper;

import java.sql.Array;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Turns a result row into a JSON-friendly map, keeping column names exactly as the database views define them
 * (the React app reads them directly).
 * <ul>
 *   <li>timestamptz -> OffsetDateTime in UTC (always timezone-aware, never converted to local time)</li>
 *   <li>jsonb/json -> JSON tree, arrays -> lists, numeric -> BigDecimal, NULL stays null (no defaults invented)</li>
 * </ul>
 */
public final class FogRows implements RowMapper<Map<String, Object>> {

    private final ObjectMapper json;

    public FogRows(ObjectMapper json) {
        this.json = json;
    }

    @Override
    public Map<String, Object> mapRow(ResultSet rs, int rowNum) throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        Map<String, Object> row = new LinkedHashMap<>(md.getColumnCount() * 2);
        for (int i = 1; i <= md.getColumnCount(); i++) {
            row.put(md.getColumnLabel(i), value(rs, i, md.getColumnTypeName(i)));
        }
        return row;
    }

    private Object value(ResultSet rs, int i, String type) throws SQLException {
        switch (type) {
            case "timestamptz": {
                OffsetDateTime t = rs.getObject(i, OffsetDateTime.class);
                return t == null ? null : t.withOffsetSameInstant(ZoneOffset.UTC);
            }
            case "date":
                return rs.getObject(i, java.time.LocalDate.class);
            case "timestamp":
                return rs.getObject(i, java.time.LocalDateTime.class);
            case "json":
            case "jsonb": {
                String s = rs.getString(i);
                try {
                    return s == null ? null : json.readTree(s);
                } catch (Exception e) {
                    return s;
                }
            }
            default:
                break;
        }
        Object o = rs.getObject(i);
        if (o instanceof Array a) {
            Object[] items = (Object[]) a.getArray();
            List<Object> out = new ArrayList<>(items.length);
            out.addAll(Arrays.asList(items));
            return out;
        }
        if (o instanceof PGobject p) {
            return p.getValue();
        }
        return o;
    }
}
