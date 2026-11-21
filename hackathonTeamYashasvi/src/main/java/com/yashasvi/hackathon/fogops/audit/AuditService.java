package com.yashasvi.hackathon.fogops.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.sql.Types;
import java.util.Map;

/** Writes an action row into the append-only fogops.audit_log (the database audits table changes itself). */
@Slf4j
@Service
public class AuditService {

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper json;

    public AuditService(NamedParameterJdbcTemplate jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    /** Never throws: auditing must not break the action it records. */
    public void write(Integer userId, String action, String entityType, String entityId, Map<String, Object> detail,
                      Integer scenarioId, Integer caseId) {
        try {
            MapSqlParameterSource p = new MapSqlParameterSource()
                    .addValue("uid", userId, Types.INTEGER)
                    .addValue("sid", scenarioId, Types.INTEGER)
                    .addValue("cid", caseId, Types.INTEGER)
                    .addValue("et", entityType)
                    .addValue("eid", entityId.length() > 200 ? entityId.substring(0, 200) : entityId)
                    .addValue("act", action)
                    .addValue("detail", json.writeValueAsString(detail));
            jdbc.update("""
                    INSERT INTO audit_log (scenario_time_utc, actor_user_id, actor_role, scenario_id, case_id,
                                           entity_type, entity_id, action, after_data)
                    VALUES (CASE WHEN CAST(:sid AS integer) IS NULL THEN NULL ELSE scenario_stamp(CAST(:sid AS integer)) END,
                            :uid, (SELECT role_code FROM app_user WHERE user_id = :uid), :sid, :cid,
                            :et, :eid, :act, CAST(:detail AS jsonb))
                    """, p);
        } catch (Exception e) {
            log.warn("Audit write failed (action not blocked): {}", e.getMessage());
        }
    }
}
