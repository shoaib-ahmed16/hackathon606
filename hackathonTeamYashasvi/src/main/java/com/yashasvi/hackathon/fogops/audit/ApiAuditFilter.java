package com.yashasvi.hackathon.fogops.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.yashasvi.hackathon.fogops.auth.AuthController;
import com.yashasvi.hackathon.fogops.auth.FogopsAuthFilter;
import com.yashasvi.hackathon.fogops.auth.FogopsTokenService;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingRequestWrapper;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Records every state-changing FogOps API call in audit_log after it ran: who, what, with which parameters and the
 * outcome, refused attempts included (401/403/409/422). Runs BEFORE Spring Security so refused calls are seen too.
 * Passwords and tokens are redacted. Streaming responses (GET) are not touched.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class ApiAuditFilter extends OncePerRequestFilter {

    private static final Set<String> METHODS = Set.of("POST", "PATCH", "PUT", "DELETE");
    private static final Set<String> SENSITIVE = Set.of("password", "token", "authorization");
    private static final int MAX_BODY = 2000;

    private final AuditService audit;
    private final FogopsTokenService tokens;
    private final ObjectMapper json;

    public ApiAuditFilter(AuditService audit, FogopsTokenService tokens, ObjectMapper json) {
        this.audit = audit;
        this.tokens = tokens;
        this.json = json;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !FogopsAuthFilter.isFogopsPath(request.getServletPath()) || !METHODS.contains(request.getMethod());
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        ContentCachingRequestWrapper wrapped = new ContentCachingRequestWrapper(req, 64 * 1024);
        long started = System.nanoTime();
        try {
            chain.doFilter(wrapped, res);
        } finally {
            record(wrapped, res, started);
        }
    }

    private void record(ContentCachingRequestWrapper req, HttpServletResponse res, long started) {
        try {
            String path = req.getServletPath();
            Integer uid = (Integer) req.getAttribute(AuthController.UID_ATTR);
            if (uid == null) {
                uid = tokens.readUid(rawToken(req));
            }
            JsonNode body = parseBody(req);
            Map<String, Object> query = new LinkedHashMap<>();
            req.getParameterMap().forEach((k, v) -> {
                if (!"token".equals(k) && v.length > 0) {
                    query.put(k, v[0]);
                }
            });
            int status = res.getStatus();
            Map<String, Object> detail = new LinkedHashMap<>();
            detail.put("method", req.getMethod());
            detail.put("path", path);
            detail.put("query", query);
            detail.put("status", status);
            detail.put("ok", status < 400);
            detail.put("ms", (System.nanoTime() - started) / 1_000_000);
            detail.put("body", describeBody(path, body));
            Integer scenario = intOf(query.get("scenario_id"), body, "scenario_id");
            Integer kase = intOf(query.get("case_id"), body, "case_id");
            audit.write(uid, req.getMethod(), "api", path, detail, scenario, kase);
        } catch (Exception ignored) {
            // auditing must never break the request
        }
    }

    private Object describeBody(String path, JsonNode body) {
        if (body == null || !body.isObject() && !body.isArray()) {
            return null;
        }
        if (path.equals(FogopsAuthFilter.LOGIN)) {   // never keep more than the username of a sign-in
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("username", body.path("username").isMissingNode() ? null : body.path("username").asText());
            return m;
        }
        JsonNode redacted = redact(body);
        String text = redacted.toString();
        return text.length() <= MAX_BODY ? redacted : text.substring(0, MAX_BODY);
    }

    private JsonNode redact(JsonNode n) {
        if (n.isObject()) {
            ObjectNode out = json.createObjectNode();
            n.fields().forEachRemaining(e -> out.set(e.getKey(),
                    SENSITIVE.contains(e.getKey().toLowerCase()) ? json.getNodeFactory().textNode("***") : redact(e.getValue())));
            return out;
        }
        if (n.isArray()) {
            ArrayNode out = json.createArrayNode();
            for (int i = 0; i < Math.min(n.size(), 50); i++) {
                out.add(redact(n.get(i)));
            }
            return out;
        }
        return n;
    }

    private JsonNode parseBody(ContentCachingRequestWrapper req) {
        byte[] b = req.getContentAsByteArray();
        if (b.length == 0) {
            return null;
        }
        try {
            return json.readTree(new String(b, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }

    private static String rawToken(HttpServletRequest req) {
        String h = req.getHeader("Authorization");
        if (h != null && h.regionMatches(true, 0, "Bearer ", 0, 7)) {
            return h.substring(7).trim();
        }
        return req.getParameter("token");
    }

    private static Integer intOf(Object fromQuery, JsonNode body, String field) {
        try {
            if (fromQuery != null) {
                return Integer.valueOf(fromQuery.toString());
            }
            if (body != null && body.has(field) && body.get(field).canConvertToInt()) {
                return body.get(field).asInt();
            }
        } catch (NumberFormatException ignored) {
            // not a number: no scope recorded
        }
        return null;
    }
}
