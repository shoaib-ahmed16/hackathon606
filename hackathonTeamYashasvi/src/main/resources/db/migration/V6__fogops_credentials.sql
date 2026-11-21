-- Sign-in credentials for the FogOps API users (fogops.app_user). Hashes are NOT stored in SQL:
-- CredentialSeeder (Java, BCrypt) gives every active user without a credential the configured demo password
-- at application start. An inactive or credential-less user can never sign in.
CREATE TABLE IF NOT EXISTS fogops.app_credential (
    user_id       INT PRIMARY KEY REFERENCES fogops.app_user,
    password_hash TEXT NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
