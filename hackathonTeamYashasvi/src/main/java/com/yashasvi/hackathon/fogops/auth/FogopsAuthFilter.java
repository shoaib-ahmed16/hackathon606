package com.yashasvi.hackathon.fogops.auth;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Optional;

/**
 * Authenticates the FogOps API (/api/**, except the legacy /api/v1/**). The token comes from
 * "Authorization: Bearer" or from "?token=" (the browser's EventSource cannot send headers).
 * A token that is present but invalid, expired or belongs to an inactive user is refused with 401.
 */
@Component
public class FogopsAuthFilter extends OncePerRequestFilter {

    public static final String LOGIN = "/api/auth/login";

    private final FogopsTokenService tokens;
    private final FogopsUsers users;

    public FogopsAuthFilter(FogopsTokenService tokens, FogopsUsers users) {
        this.tokens = tokens;
        this.users = users;
    }

    public static boolean isFogopsPath(String path) {
        return path.startsWith("/api/") && !path.startsWith("/api/v1/");
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getServletPath();
        return !isFogopsPath(path) || path.equals(LOGIN);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        String raw = bearer(req);
        if (raw != null) {
            Integer uid = tokens.readUid(raw);
            Optional<FogUser> user = uid == null ? Optional.empty() : users.activeById(uid);
            if (user.isEmpty()) {
                SecurityContextHolder.clearContext();
                res.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                res.setContentType("application/json");
                res.setCharacterEncoding(StandardCharsets.UTF_8.name());
                res.getWriter().write("{\"detail\":\"Sign in required\"}");
                return;
            }
            FogUser u = user.get();
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                    u, null, AuthorityUtils.createAuthorityList("ROLE_" + u.role())));
        }
        chain.doFilter(req, res);
    }

    private static String bearer(HttpServletRequest req) {
        String h = req.getHeader("Authorization");
        if (h != null && h.regionMatches(true, 0, "Bearer ", 0, 7)) {
            return h.substring(7).trim();
        }
        String q = req.getParameter("token");
        return (q == null || q.isBlank()) ? null : q;
    }
}
