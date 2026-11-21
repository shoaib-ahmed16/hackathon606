package com.yashasvi.hackathon.fogops.auth;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/** No database and no Spring context: pure token rules. */
class FogopsTokenServiceTest {

    private static final String SECRET = "test-secret-test-secret-test-secret-123456";

    private final FogopsTokenService service = new FogopsTokenService(SECRET, "issuer", 12);

    @Test
    void roundTripsTheUserId() {
        assertEquals(7, service.readUid(service.make(7)));
    }

    @Test
    void rejectsTamperedAndGarbageTokens() {
        String t = service.make(7);
        assertNull(service.readUid(t.substring(0, t.length() - 2) + "xx"));
        assertNull(service.readUid("abc.def.ghi"));
        assertNull(service.readUid(""));
        assertNull(service.readUid(null));
    }

    @Test
    void rejectsExpiredTokens() {
        assertNull(new FogopsTokenService(SECRET, "issuer", -1).readUid(new FogopsTokenService(SECRET, "issuer", -1).make(7)));
    }

    @Test
    void rejectsTokensSignedWithAnotherSecret() {
        assertNull(new FogopsTokenService("another-secret-another-secret-another-secret-9", "issuer", 12)
                .readUid(service.make(7)));
    }

    @Test
    void rejectsLegacyTokensThatCarryNoUid() {
        SecretKey key = Keys.hmacShaKeyFor(SECRET.getBytes(StandardCharsets.UTF_8));
        String legacy = Jwts.builder().claim("username", "someone").claim("authorities", "ROLE_ADMIN")
                .expiration(new Date(System.currentTimeMillis() + 60_000)).signWith(key, Jwts.SIG.HS256).compact();
        assertNull(service.readUid(legacy));
    }
}
