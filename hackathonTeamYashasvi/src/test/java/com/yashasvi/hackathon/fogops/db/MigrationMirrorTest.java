package com.yashasvi.hackathon.fogops.db;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * The teammate's backend/migrations/NNN_name.sql are mirrored byte for byte as Flyway V(NNN+6)__name.sql
 * (V2..V6 are ours). If a file changes or a new one appears, this fails until the Flyway copy is updated.
 * No database needed.
 */
class MigrationMirrorTest {

    private static final int OFFSET = 6;

    @Test
    void everyBackendMigrationHasAnIdenticalFlywayMirror() throws IOException {
        Path backend = Path.of("..", "backend", "migrations");
        assumeTrue(Files.isDirectory(backend), "backend/migrations not found (running outside the monorepo)");
        Path flyway = Path.of("src", "main", "resources", "db", "migration");
        List<Path> sources;
        try (Stream<Path> s = Files.list(backend)) {
            sources = s.filter(p -> p.getFileName().toString().matches("\\d{3}_.+\\.sql")).sorted().toList();
        }
        for (Path src : sources) {
            String name = src.getFileName().toString();
            int n = Integer.parseInt(name.substring(0, 3));
            Path mirror = flyway.resolve("V" + (n + OFFSET) + "__" + name.substring(4));
            assertEquals(true, Files.exists(mirror), "missing Flyway mirror " + mirror.getFileName() + " for backend/migrations/" + name);
            assertEquals(Files.readString(src), Files.readString(mirror), mirror.getFileName() + " differs from backend/migrations/" + name);
        }
    }
}
