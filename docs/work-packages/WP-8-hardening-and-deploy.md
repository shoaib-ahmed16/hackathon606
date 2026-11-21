# WP-8: Hardening and deployment (Phase 7)

**Why:** make the Spring stack runnable by anyone with one command and safe to expose. Parts (Dockerfile, compose, README) can start now; the security review and the final
end-to-end run come last, after the other packages merge.

**Skills:** Docker and compose, Java security basics, technical writing. **Size:** M. **Depends on:** step 0 (final run after the other packages).

## Brief to paste into Claude

> You are working on the FogOps repo. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md`. Show me a short plan and wait for my OK before coding.
> Do not edit the teammate's files (`backend/`, root `docker-compose.yml`, root `README.md`, `reset-db.sh`); add new files beside them.
>
> 1. **One-command stack for Spring.** A compose file (propose its location in the plan, for example `docker-compose.spring.yml` at the repo root) with PostgreSQL 17,
>    the Spring API (use `hackathonTeamYashasvi/Dockerfile`, check it builds with JDK 17), a one-shot loader step that fills an empty database with the Excel files in
>    `hackathonTeamYashasvi/data/` (the loader needs Python and `requirements.txt`; it is not re-runnable, so make it run only when `fogops.flight` is empty), the seed
>    cases (`db/fogops/seed_cases.sql`), and the UI (`hackathon-app/docker-compose.spring.yml` and `nginx.spring.conf` already exist; the proxy must reach the API
>    container, not `host.docker.internal`, in this compose). A health check on every service; start order by health.
> 2. **Configuration and secrets.** `.env.example` with placeholders only for every variable the stack reads (database, `JWT_SECRET_KEY`, demo password, `ANTHROPIC_API_KEY`,
>    `ASK_*`, `WORKER_ENABLED`, CORS origins). Fail fast at startup in a non-dev profile when the JWT secret or demo password still has its default value. Remove default
>    secrets from `application.yml` for that profile. Make sure no real key or password exists in any tracked file or git history of this repo (report, do not rewrite history).
> 3. **Login protection.** Rate limit sign-in failures per username and per IP (for example 5 per minute) with a clear 429 `{"detail": "..."}`; every refused attempt is audited;
>    the AGENT account still never signs in. Keep the existing timing-safe dummy hash.
> 4. **Decisions for the lead (implement after the answer, small and separate commits):** (a) restrict `GET /api/audit` to certain roles; (b) list `VERIFICATION_REQUIRED`
>    crew first in `/api/crew/legality` (today the default limit of 200 rows hides all 82 in the daily cases).
> 5. **Security review** of the Spring code under `fogops/` (use the `/security-review` skill): authentication on every route, dynamic SQL names (whitelists only), error bodies (no SQL
>    or stack traces), CORS, request size limits, SSE connection limits, logging (no passwords, tokens or keys), actuator exposure, tracing exporter errors when no collector runs.
>    The old unrelated code (`/api/v1`, chat/WebSocket) is not ours: report anything risky you see, do not change it.
> 6. **README** for the Spring stack: what it is, how to run it from zero, environment variables, migrations (including the mirror rule), loader and repair script, demo users, demo flow
>    (push live data, create a case with simulated fog, decide, approve, execute, swap), how to run the parity kit, and the guardrails.

## Acceptance criteria

- From a clean clone with only Docker installed, one documented command brings up database, API, loader, seed and UI; `http://localhost:8080` signs in as `occ.dm` and shows the four
  daily cases with data; a smoke script checks `/health`, login, `/api/cases`, one flight detail, one action on a scratch database.
- Starting with a default secret in the production profile fails with a clear message.
- Six failed sign-ins in a minute give 429 and appear in the audit trail; a correct sign-in afterwards still works after the window.
- `git grep` for the key prefix, the real database password and the real JWT secret finds nothing in tracked files.
- The security review's findings are listed with severity and either fixed or handed to the lead.
- `./gradlew clean build -x test` passes and all unit tests pass.
