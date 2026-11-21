package com.yashasvi.hackathon.fogops.write;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.db.FogRows;
import org.postgresql.util.PGobject;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.SQLException;
import java.sql.Types;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * Runs database work as a named human (or the non-human AGENT): one transaction, and fogops.set_actor(user) is the
 * first statement in it, so the audit triggers and the role guardrails see who acted. set_actor is transaction-local,
 * which is why the actor and the write MUST share the transaction. Any exception rolls everything back.
 */
@Component
public class FogTx {

    private final TransactionTemplate tx;
    private final NamedParameterJdbcTemplate jdbc;
    private final FogRows rows;
    private final ObjectMapper json;

    public FogTx(PlatformTransactionManager tm, NamedParameterJdbcTemplate jdbc, ObjectMapper json) {
        this.tx = new TransactionTemplate(tm);
        this.jdbc = jdbc;
        this.rows = new FogRows(json);
        this.json = json;
    }

    public <T> T as(int userId, Function<Tx, T> work) {
        return tx.execute(status -> {
            jdbc.getJdbcTemplate().execute("SELECT set_actor(" + userId + ")");   // int: not injectable
            return work.apply(new Tx());
        });
    }

    /** The engine's own identity: it may write recommendations, never decisions (the database refuses those). */
    public int agentUserId() {
        List<Integer> ids = jdbc.getJdbcTemplate().queryForList(
                "SELECT user_id FROM app_user WHERE role_code = 'AGENT' AND is_active ORDER BY user_id LIMIT 1", Integer.class);
        if (ids.isEmpty()) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "No agent user configured");
        }
        return ids.get(0);
    }

    /** Params in request order; null values allowed. */
    public static Map<String, Object> p(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) {
            m.put((String) kv[i], kv[i + 1]);
        }
        return m;
    }

    /**
     * Text is sent untyped so Postgres infers the column or argument type (timestamptz, date, numeric, enums...);
     * objects and lists become jsonb. SQL still uses explicit CASTs where a function argument needs one.
     */
    private MapSqlParameterSource bind(Map<String, ?> params) {
        MapSqlParameterSource src = new MapSqlParameterSource();
        if (params == null) {
            return src;
        }
        params.forEach((k, v) -> {
            if (v instanceof String s) {
                src.addValue(k, s, Types.OTHER);
            } else if (v instanceof Map<?, ?> || v instanceof List<?> || v instanceof com.fasterxml.jackson.databind.JsonNode) {
                try {
                    PGobject o = new PGobject();
                    o.setType("jsonb");
                    o.setValue(json.writeValueAsString(v));
                    src.addValue(k, o);
                } catch (SQLException | com.fasterxml.jackson.core.JsonProcessingException e) {
                    throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "Invalid JSON value for " + k);
                }
            } else {
                src.addValue(k, v);
            }
        });
        return src;
    }

    public final class Tx {
        public List<Map<String, Object>> rows(String sql, Map<String, ?> params) {
            return jdbc.query(sql, bind(params), rows);
        }

        public Map<String, Object> one(String sql, Map<String, ?> params) {
            List<Map<String, Object>> r = rows(sql, params);
            return r.isEmpty() ? null : r.get(0);
        }

        public int update(String sql, Map<String, ?> params) {
            return jdbc.update(sql, bind(params));
        }
    }
}
