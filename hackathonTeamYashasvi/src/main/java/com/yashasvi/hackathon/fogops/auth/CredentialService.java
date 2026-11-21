package com.yashasvi.hackathon.fogops.auth;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * Passwords for fogops.app_user. Synthetic demo environment: every active user gets the configured demo password
 * (fogops.auth.demo-password) the first time, at start or on first sign-in. Leave it blank to disable this and
 * provision app_credential rows yourself. The non-human AGENT account never gets a credential.
 */
@Slf4j
@Component
public class CredentialService implements ApplicationRunner {

    private final JdbcTemplate jdbc;
    private final PasswordEncoder encoder;
    private final String demoPassword;

    public CredentialService(JdbcTemplate jdbc, PasswordEncoder encoder,
                             @Value("${fogops.auth.demo-password:}") String demoPassword) {
        this.jdbc = jdbc;
        this.encoder = encoder;
        this.demoPassword = demoPassword == null ? "" : demoPassword;
    }

    @Override
    public void run(ApplicationArguments args) {
        if (demoPassword.isBlank()) {
            log.info("fogops.auth.demo-password is blank: no demo credentials are provisioned");
            return;
        }
        List<Integer> missing = jdbc.queryForList(
                "SELECT user_id FROM app_user WHERE is_active AND role_code <> 'AGENT' "
                        + "AND user_id NOT IN (SELECT user_id FROM app_credential)", Integer.class);
        missing.forEach(this::insert);
        if (!missing.isEmpty()) {
            log.info("Provisioned demo credentials for {} FogOps user(s)", missing.size());
        }
    }

    /** Gives one active, non-agent user the demo password if it has no credential yet. */
    public void ensureDemoCredential(int userId) {
        if (demoPassword.isBlank()) {
            return;
        }
        Integer has = jdbc.queryForObject("SELECT count(*) FROM app_credential WHERE user_id = ?", Integer.class, userId);
        if (has != null && has == 0) {
            insert(userId);
        }
    }

    private void insert(int userId) {
        jdbc.update("INSERT INTO app_credential (user_id, password_hash) VALUES (?, ?) ON CONFLICT (user_id) DO NOTHING",
                userId, encoder.encode(demoPassword));
    }
}
