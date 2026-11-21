package com.yashasvi.hackathon.fogops.auth;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;

/**
 * Signed, expiring session tokens for the FogOps API. The claim set differs from the legacy /api/v1 token
 * (it carries "uid", no "username"), and each filter rejects the other's tokens, so one cannot be replayed on the other.
 */
@Component
public class FogopsTokenService {

    static final String UID = "uid";

    private final SecretKey key;
    private final Duration ttl;
    private final String issuer;

    public FogopsTokenService(@Value("${jwt.security.token.secret_key}") String secret,
                              @Value("${jwt.security.token.issuer}") String issuer,
                              @Value("${fogops.auth.token-ttl-hours:12}") long ttlHours) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.issuer = issuer;
        this.ttl = Duration.ofHours(ttlHours);
    }

    public String make(int userId) {
        Date now = new Date();
        return Jwts.builder()
                .issuer(issuer)
                .claim(UID, userId)
                .issuedAt(now)
                .expiration(new Date(now.getTime() + ttl.toMillis()))
                .signWith(key, Jwts.SIG.HS256)
                .compact();
    }

    /** The user id, or null when the token is malformed, tampered with, expired or not a FogOps token. */
    public Integer readUid(String token) {
        if (token == null || token.isBlank()) {
            return null;
        }
        try {
            Claims c = Jwts.parser().verifyWith(key).build().parseSignedClaims(token).getPayload();
            Object uid = c.get(UID);
            return uid instanceof Number n ? n.intValue() : null;
        } catch (JwtException | IllegalArgumentException e) {
            return null;
        }
    }
}
