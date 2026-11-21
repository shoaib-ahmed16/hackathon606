package com.yashasvi.hackathon.fogops.auth;

import com.yashasvi.hackathon.fogops.api.ApiException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Sign in / who am I / sign out. Same contract as the FogOps UI expects: {token, user{user_id, username, display_name, role_code}}. */
@RestController
@RequestMapping("/api")
public class AuthController {

    public static final String UID_ATTR = "fogops.uid";

    public record Login(@NotBlank String username, @NotBlank String password) {
    }

    private record Row(int userId, String username, String displayName, String role, String hash) {
    }

    private final JdbcTemplate jdbc;
    private final PasswordEncoder encoder;
    private final FogopsTokenService tokens;
    private final CredentialService credentials;
    /** Compared against when the user does not exist, so response time does not reveal valid usernames. */
    private final String dummyHash;

    public AuthController(JdbcTemplate jdbc, PasswordEncoder encoder, FogopsTokenService tokens, CredentialService credentials) {
        this.jdbc = jdbc;
        this.encoder = encoder;
        this.tokens = tokens;
        this.credentials = credentials;
        this.dummyHash = encoder.encode(java.util.UUID.randomUUID().toString());
    }

    @PostMapping("/auth/login")
    public Map<String, Object> login(@Valid @RequestBody Login body, HttpServletRequest req) {
        String username = body.username().trim();
        Row row = find(username);
        if (row != null && row.hash == null && !"AGENT".equals(row.role)) {
            credentials.ensureDemoCredential(row.userId);
            row = find(username);
        }
        // the decision-support agent is a non-human role: no interactive sign-in, whatever the password
        if (row != null && "AGENT".equals(row.role)) {
            encoder.matches(body.password(), dummyHash);
            throw new ApiException(HttpStatus.FORBIDDEN, "The agent account cannot sign in interactively");
        }
        boolean known = row != null && row.hash != null;
        boolean matches = encoder.matches(body.password(), known ? row.hash : dummyHash);
        if (!known || !matches) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "Invalid username or password");
        }
        req.setAttribute(UID_ATTR, row.userId);   // the audit filter records WHO signed in
        Map<String, Object> user = new LinkedHashMap<>();
        user.put("user_id", row.userId);
        user.put("username", row.username);
        user.put("display_name", row.displayName);
        user.put("role_code", row.role);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("token", tokens.make(row.userId));
        out.put("user", user);
        return out;
    }

    @GetMapping("/me")
    public Map<String, Object> me(@AuthenticationPrincipal FogUser u) {
        if (u == null) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "Sign in required");
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("user_id", u.userId());
        m.put("username", u.username());
        m.put("display_name", u.displayName());
        m.put("role_code", u.role());
        return m;
    }

    /** Tokens are stateless; this exists so signing out is recorded in the audit trail (by the audit filter). */
    @PostMapping("/auth/logout")
    public Map<String, Object> logout() {
        return Map.of("ok", true);
    }

    private Row find(String username) {
        List<Row> rows = jdbc.query(
                "SELECT u.user_id, u.username, u.display_name, u.role_code, c.password_hash FROM app_user u "
                        + "LEFT JOIN app_credential c USING (user_id) WHERE lower(u.username) = lower(?) AND u.is_active",
                (rs, i) -> new Row(rs.getInt(1), rs.getString(2), rs.getString(3), rs.getString(4), rs.getString(5)),
                username);
        return rows.isEmpty() ? null : rows.get(0);
    }
}
