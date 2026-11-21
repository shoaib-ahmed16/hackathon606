package com.yashasvi.hackathon.fogops.auth;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/** Lookups on fogops.app_user. Active-user checks are cached for a few seconds (the UI polls many endpoints). */
@Component
public class FogopsUsers {

    private static final long CACHE_MS = 15_000;

    private record Cached(FogUser user, long at) {
    }

    private final JdbcTemplate jdbc;
    private final ConcurrentHashMap<Integer, Cached> cache = new ConcurrentHashMap<>();

    public FogopsUsers(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** The active user with this id, or empty (unknown or deactivated: the token is no longer valid). */
    public Optional<FogUser> activeById(int userId) {
        Cached c = cache.get(userId);
        if (c != null && System.currentTimeMillis() - c.at < CACHE_MS) {
            return Optional.ofNullable(c.user);
        }
        List<FogUser> rows = jdbc.query(
                "SELECT user_id, username, display_name, role_code FROM app_user WHERE user_id = ? AND is_active",
                (rs, i) -> new FogUser(rs.getInt(1), rs.getString(2), rs.getString(3), rs.getString(4)), userId);
        FogUser u = rows.isEmpty() ? null : rows.get(0);
        cache.put(userId, new Cached(u, System.currentTimeMillis()));
        return Optional.ofNullable(u);
    }
}
