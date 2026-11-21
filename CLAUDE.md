# FogOps (Hack606): Spring Boot backend for the Air Arabia fog-disruption console

Everything lives in this repo (`/home/datti/Desktop/hackathon/hackathon606`). Always work here. The old copy under
`/home/datti/Desktop/hackathon_docs/hackathon/` is obsolete: do not read from it or write to it.

## Layout

| Path | What it is | Ours? |
|---|---|---|
| `hackathonTeamYashasvi/` | **Spring Boot 3.5 / Java 17 / Gradle backend (port 8888). This is what we build.** | yes |
| `hackathon-app/` | React UI (teammate). It calls `OPS_API_URL + /api/...`. Own rules: `hackathon-app/CLAUDE.md`. | no, except `nginx.spring.conf`, `docker-compose.spring.yml`, `.env` |
| `backend/` | Teammate's working **FastAPI** backend. It is the executable **spec** for the API contract. Read-only reference. | no |
| `docker-compose.yml`, `reset-db.sh`, `README.md`, root `.env*` | Teammate's FastAPI stack. Do not edit. **Never run `reset-db.sh` or `rebuild.sh`.** | no |

Spring DB: PostgreSQL 17, container `yashasvi-postgres` on 5432, database `hackathon_yashasvi`, schemas `fogops` and `hist`.
Credentials are in `hackathonTeamYashasvi/.env` (git-ignored). Never print them: `set -a; . ./.env; set +a` and use the variables.

## How to work (user preferences)

- **Plan first, discuss before coding.** For a new phase: read the FastAPI code and the DB functions, bring a short plan with the
  guardrail mapping and any deviation from FastAPI, wait for a go. Small follow-ups can go straight in.
- **Do not commit or push unless asked.** Suggest a commit message when asked. Do not touch files that are not ours (see table).
- **Strict parity with FastAPI first, enhancements only after the diff passes.** Every deviation is deliberate, named in the plan,
  and listed in the final report. Before each phase run `git log --stat -5 -- backend hackathon-app/src`: the teammate keeps changing
  the spec (new endpoints, DB migrations).
- Be honest in reports: say what was tested, what was not, and what is still open.
- Answer questions about behaviour from the real code (SQL functions, controllers), not from memory.

## Build, run, test

- JDK: the shell default (25) fails the toolchain. Use `export JAVA_HOME=/home/datti/apps/jdk-17 PATH=/home/datti/apps/jdk-17/bin:$PATH`.
- Build: `cd hackathonTeamYashasvi && ./gradlew clean build -x test` (run it directly, no wrapper scripts).
- Unit tests (no DB): `./gradlew test --tests '*ConsoleTextTest' --tests '*WriteRulesTest' --tests '*FogopsTokenServiceTest' --tests '*MigrationMirrorTest'`.
  **Do not run the old Spring context test**: it connects to the real database.
- Run Spring: `java -jar build/libs/hackathonTeamYashasvi-0.0.1-SNAPSHOT.jar '--spring.config.import=optional:file:<repo>/hackathonTeamYashasvi/.env[.properties]'`
  (loads the DB settings from `.env` without printing them; **quote the argument**, zsh treats `[...]` as a glob). Find what holds port 8888 with
  `ss -ltnp` and stop it first. Flyway applies pending migrations on start. Start it with `setsid nohup ... < /dev/null &`.
- UI (npm is not available locally, Docker only): `cd hackathon-app && docker compose -f docker-compose.spring.yml up -d --build`
  then http://localhost:8080. nginx forwards `/ops-api/` to `host.docker.internal:8888` and **blanks the `Origin` header**
  (otherwise Spring answers "Invalid CORS request"). Browser CORS for direct calls: `security.cors.allowed-origins`.
- Demo users (synthetic, password from `fogops.auth.demo-password`, default `FogOps@2026`): `occ.dm`, `dispatch.1`, `crew.ctl.1`,
  `recovery.1`, `admin`, `station.rkt|fjr|aan|mct`. The `agent` user (role AGENT) can never sign in.

## Testing against the spec (the method that works)

- **Never test writes on the user's database.** Make a scratch copy: `pg_dump -Fc hackathon_yashasvi | pg_restore -d <scratch>` via
  `docker exec yashasvi-postgres`, run one backend per scratch DB, drive both with the same request sequence, then compare the
  responses and the resulting table contents. Drop the scratch DBs afterwards and restart Spring on the real DB.
- FastAPI cannot verify Spring's BCrypt hashes: `DELETE FROM fogops.app_credential` in the FastAPI scratch DB, then start FastAPI
  (it seeds its own). Use `/usr/local/bin/python3.12` (3.8 breaks on timestamp parsing); install FastAPI deps with `pip --target`.
- Start FastAPI with `WORKER_ENABLED=false`. Use `setsid nohup ... < /dev/null &`. Never `pkill -f <pattern>` (it kills your own shell).
- Scratch files go in the session scratchpad, not `/tmp` or the repo. Backups of the shared database are kept OUTSIDE the repo in
  `/home/datti/hackathon-backups/` (take a `pg_dump -Fc` there before any change to the real database; `docker exec yashasvi-postgres ...`
  works without a password through the container's local socket).

## Backend conventions (package `com.yashasvi.hackathon.fogops`)

- No JPA for FogOps: views and functions through `FogDb` (reads) and `FogTx` (writes). `FogRows` keeps column names exactly as the DB
  defines them (the React app reads them), timestamptz as UTC `OffsetDateTime`, NULL stays null.
- **Writes** go through `FogTx.as(userId, ...)`: one transaction, `set_actor(<human>)` first (it is transaction-local, the audit triggers
  and role guardrails need it in the same transaction). Engine re-runs use `fogTx.agentUserId()` (the AGENT may write recommendations, never decisions).
- Text parameters are bound untyped (Postgres infers the type); use explicit `CAST(:x AS bigint)` for function arguments. Dynamic column
  or table names only from whitelists or `information_schema`, never from raw input.
- Errors are always `{"detail": "<string>"}` (the UI shows only a string `detail`). Postgres `RAISE` P0001 becomes 403 (guardrail/role/human)
  or 409; SQLSTATE class 22/23 and 42804 become 422; anything else is 500 `Database error` (never leak SQL).
- Auth: `FogopsAuthFilter` on `/api/**` (not `/api/v1/**`), HS256 token with claim `uid`, header or `?token=` (SSE). `ApiAuditFilter`
  audits every POST/PATCH/PUT/DELETE including refused ones. Do not mix with the old `/api/v1` JWT stack.
- Flyway: `V2..V6` are ours (V6 = `app_credential`). The teammate's `backend/migrations/NNN_name.sql` are mirrored **byte for byte** as
  `V(NNN+6)__name.sql` (001 -> V7, 002 -> V8); `MigrationMirrorTest` fails when they drift. New teammate migration = copy it, bump by 6.
  Never edit an applied migration, add a new one. Flyway applies pending migrations when Spring starts: **starting the jar against the
  real database applies them**, so get the user's OK first, or start with `SPRING_FLYWAY_ENABLED=false`.
- DB sessions are pinned to UTC (`connection-init-sql`): the JDBC driver would otherwise use the JVM zone (IST here) and the database
  writes timestamptz into JSON/text in the session zone. Keep timestamps in event payloads as `+00:00` text like the original API.
- The loader (`db/fogops/loader/load_data.py`) is not re-runnable. A database loaded with the OLD loader needs the one-time
  `db/fogops/fix_pax_connection.sql` (backup first). `refresh_leg_time_reference()` runs at the end of the loader.

## Guardrails (from `Crew Duty Recovery_Hackathon_Use Case 3.docx`)

Human in control (the AI never decides; the DB rejects AGENT decisions) / approved crew rules only (Java does no legality maths) /
real crew assignments / safety and feasibility first / time integrity (timezone-aware UTC, SHJ-local only inside text) / no fabricated
facts (null stays null, quality labels MEASURED, SIMULATED, ESTIMATED, ASSUMED pass through) / audit trail / controlled environment
(synthetic data, **crew mobile numbers are never stored or returned**) / graceful degradation (`VERIFICATION_REQUIRED` is shown as
"needs verification", never a crash and never hidden).

## Security rules

- Never print or commit secrets: `.env`, DB password, JWT secret, Anthropic key. `.env.example` files hold placeholders only. If a key was ever
  exposed (it was, once, in `.env.example`) remind the user to rotate it.
- **The root `.env` is tracked in git** (committed in `6f41de5`; it holds `DB_PASSWORD`, `AUTH_SECRET`, `JWT_SECRET_KEY` of the teammate's stack). It is in
  `.gitignore` but already tracked: it needs `git rm --cached .env` and a rotation of those values. Not ours to change unprompted; keep reminding the user.
- `.claude/` (worktrees, session settings) must never be committed; add it to `.gitignore`.
- Do not log passwords; the audit filter redacts password, token, authorization.
- Free-text AI (Phase 6) runs server-side only, grounded on DB facts, audited, rate limited. The key never reaches the browser.

## Where we are

Done and verified against FastAPI on scratch DBs: Phase 1 (login, 17 reads), Phase 2 (`/deadlines`, `/flights/{id}/detail`, `/briefing`,
`/audit`, `/ask/questions` with `ai:false`), Phase 3 (actions, `/records/{table}`, case lifecycle, crew swap rule), and the **spec sync**
(migrations 001/002 as V7/V8, fixed passenger loader plus repair script, `POST /api/feed/push`, audit wording, `/health` migration level):
engine output, recommendations and table state identical to FastAPI after feed pushes.
**Applied to the shared database on 2026-11-21 (done):** Flyway V7 and V8, the passenger repair (9,626 pairs -> 5,044 pairs, 31,454 pax, 0 reversed,
0 impossible), and removal of the 28 leftover tables of the retired design plus `pax_connection_backup` (schema `public` now holds only
`flyway_schema_history` and `users_details`). `/health` shows `V8__rank_alternates_fuel_policy.sql`. Backup taken before: `/home/datti/hackathon-backups/
hackathon_yashasvi_before_V7_V8_pax.dump`. Data check: 885 flights, 2,747 crew, legality LEGAL 416 / AT_RISK 26 / VERIFICATION_REQUIRED 82, no crew
mobile numbers, 0 fuel estimates (so the new fuel rule is dormant and the engine reports LEGACY until fuel is entered, pushed or estimated), 0 decisions.
The Spring server may be stopped: the UI at :8080 needs it running on 8888.
Known gap: the updated loader (passenger fix, leg-time refresh) has not been run end to end on an EMPTY database (a fresh-install rehearsal on a
scratch database is part of WP-8).

**Remaining work is split into work packages: see `docs/work-packages/`** (`README.md` rules and helper contracts, `ASSIGNMENTS.md` who does what in which
order, `WP-0` to `WP-8` briefs, `RELEASE-CHECKLIST.md`). Summary: WP-0 parity test kit, WP-1 live updates (SSE `/api/stream` + reassessment worker, Phase 4),
WP-2 recovery edits + `/whatif` (Phase 5), WP-3 Ask (Phase 6), WP-4 stand capacity (config + history), WP-5 fuel from history + fuel outlook, WP-6 connecting-pax
risk, WP-7 engine integration (only WP-7 may change `rank_alternates` / `propose_hold_or_divert`), WP-8 hardening and deployment (Phase 7). New migrations:
`backend/migrations/003` to `006` mirrored as `V9` to `V12`. Only the lead applies migrations to the shared database. Assignment: Datti WP-6, WP-0, WP-7;
Shoaib WP-4, WP-1, WP-3; Somesh WP-5, WP-2, WP-8. Port the teammate's newer `routes_ask.py` in WP-3.

Deliberate deviations from FastAPI (keep): string `detail` on validation errors; swap needs an APPROVED `CREW_REPLACE` decision and must match it
(duty, outgoing, incoming crew); `/flights/{id}/detail` shows "needs verification" instead of a 500 when max FDP is null; `/recompute` is one
transaction; `/ask/questions` reports `ai:false` until Phase 6; `/api/feed/push` is OCC/ADMIN only (it writes simulated movements, SIM_FEED
source, SIMULATED fuel and an invented 85-96% passenger load into LIVE); UTC database sessions.
Open decisions: list `VERIFICATION_REQUIRED` crew first in `/crew/legality` (default 200 rows hides all 82 in the daily cases); connection-risk
factor in hold/divert ranking (connection slack = outbound STD minus inbound STA is derivable from the repaired `pax_connection`); restrict
`/audit` by role.
