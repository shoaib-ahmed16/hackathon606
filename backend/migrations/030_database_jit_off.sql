-- 030: switch off Postgres JIT for this database.
-- The read models (v_flight_watch and the views built on it) are heavy, joined queries; JIT compiles them to machine code on every run,
-- which cost more than it saved: the flight list took about 0.45 s without JIT and 0.85 to 1.3 s with it on the same data.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET jit = off', current_database());
END $$;
