# FogOps remaining work: work packages

Phases 1 to 3 and the spec sync are done (see the root `CLAUDE.md`, section "Where we are"). Everything left is split into packages that
different people can build in parallel, each in their own Claude session. Each `WP-*.md` file has a **brief to paste into Claude** plus
acceptance criteria.

**Who does what, and in which order: see `ASSIGNMENTS.md`.** Shared-database steps: `RELEASE-CHECKLIST.md`.

## Step 0 (one person, before anyone starts): commit the baseline

All Phase 1 to 3 and spec-sync work is still **uncommitted** in the working tree. Commit and push it on a shared branch first, so every
package branches from the same code:

```
Add FogOps Spring backend: Phases 1-3 (auth, reads, console, actions) and spec sync (V7/V8, feed push)
```

Before committing check: no secrets in staged files (`.env`, a key in any `.env.example`), the 23 MB `data/` folder is intended, and
`hackathonTeamYashasvi/db/fogops/fix_pax_connection.sql` and the root `CLAUDE.md` are included.

## Packages

| # | Package | Who (skills) | Size | Needs first | Main place it touches |
|---|---|---|---|---|---|
| WP-0 | Parity test kit (scratch DBs, run both backends, diff) | backend or devops | M | step 0 | `hackathonTeamYashasvi/tools/parity/` (new) |
| WP-1 | Live updates: SSE `/api/stream` + reassessment worker (Phase 4) | Java | M | step 0 | `fogops/live/` (new) |
| WP-2 | Recovery plan edits + what-if (Phase 5) | Java | M | step 0 | `fogops/recovery/` (new) |
| WP-3 | Ask assistant (Phase 6) | Java, prompt design | L | step 0 | `fogops/ask/` (new) |
| WP-4 | Stand and slot capacity (config screen + history estimate) | SQL, Java, React | L | step 0 | migration 003, `fogops/capacity/`, UI screen |
| WP-5 | Fuel estimate from history; fuel outlook for SHJ and the diversion leg | SQL, Java | L | step 0 | migration 004, `fogops/fuel/` |
| WP-6 | Connecting-passenger risk | SQL, Java | M | step 0, passenger repair on the DB | migration 005, `fogops/pax/` |
| WP-7 | Engine integration: wire WP-4/5/6 into `rank_alternates` and the screens | SQL, Java | L | helper contracts below (can start on stubs) | migration 006, `ConsoleService` |
| WP-8 | Hardening and deployment (Phase 7) | devops, Java | M | can start now, finish last | `Dockerfile`, compose, README, security |

Crew legality for N and N+1 legs (the first requirement) is already computed by the database engine; WP-1 makes it automatic and WP-7
shows it. The 82 crew still `VERIFICATION_REQUIRED` need answers from the organisers, not code.

## Order

```
step 0 (baseline commit)
  |-- WP-0 (helps everyone verify; start first, others can use manual checks until it lands)
  |-- WP-1, WP-2, WP-3  : independent of each other and of the engine packages, start at once
  |-- WP-4, WP-5, WP-6  : independent of each other, each delivers a helper function with a FIXED contract
  |        \__ WP-7 wires the three helpers into the engine (merge after 4, 5, 6)
  \-- WP-8 (Dockerfile and docs can start now; security review and the final compose run last)
```

## Rules every package follows

1. **Read the root `CLAUDE.md` first.** It has the build and test method, conventions, guardrails and security rules. Paste the brief, and
   tell Claude to read `CLAUDE.md` before anything else.
2. **Own branch and worktree:** `wp<N>-<short-name>` from the baseline. Small pull requests. Do not commit to the shared branch directly.
3. **Plan first.** Claude shows a short plan (files, endpoints, SQL, deviations, tests) and waits for your OK before coding.
4. **Never test writes on the shared database.** Use a scratch copy (see `CLAUDE.md`, "Testing against the spec"; WP-0 automates it).
5. **Files that are not yours:** do not edit `backend/` (teammate's FastAPI), `hackathon-app/` (React) unless your package says so,
   root `docker-compose.yml`, `reset-db.sh`, root `README.md`. Never run `reset-db.sh` or `rebuild.sh`.
6. **Migrations:** one number block per package (below). Put the SQL in `backend/migrations/NNN_name.sql` **and** mirror it byte for byte as
   `hackathonTeamYashasvi/src/main/resources/db/migration/V(NNN+6)__name.sql` (`MigrationMirrorTest` checks this). Never edit an applied
   migration. Only WP-7 may change `rank_alternates` or `propose_hold_or_divert`. Putting new SQL in the teammate's `backend/migrations/`
   needs their agreement: confirm with them once, before WP-4 starts.
7. **Shared files, edit minimally:** `AuditSummary.java` (add one line), `application.yml` (add your own block), `ConsoleService.java`
   (WP-7 only). `CLAUDE.md` is updated by the lead; put your suggested lines in the pull request description.
8. **Guardrails never relaxed:** human decides, no fabricated facts (label every assumption `ASSUMED` or `ESTIMATED_FROM_HISTORY`, null stays
   null), timezone-aware UTC, audit every state change, no crew mobile numbers, graceful degradation (`verify` instead of a crash).
9. **Done means:** acceptance criteria met, `./gradlew clean build -x test` passes, unit tests (no database) added, parity or scratch-DB
   verification run and reported honestly, nothing secret committed.

## Migration number blocks (avoids collisions)

| Package | `backend/migrations/` | Flyway mirror |
|---|---|---|
| WP-4 stands | `003_stand_capacity.sql` | `V9__stand_capacity.sql` |
| WP-5 fuel | `004_fuel_burn_reference.sql` | `V10__fuel_burn_reference.sql` |
| WP-6 passengers | `005_connection_risk.sql` | `V11__connection_risk.sql` |
| WP-7 integration | `006_engine_integration.sql` | `V12__engine_integration.sql` |
| spare | `007` to `009` | `V13` to `V15` |

## Helper contracts (fixed, so WP-4/5/6 and WP-7 can work at the same time)

All are SQL functions in schema `fogops`, `STABLE`, read-only, `SET search_path TO 'fogops','hist','public'`. Unknown stays NULL; a
`quality` column says where each number came from (`MEASURED`, `MANUAL`, `ASSUMED`, `ESTIMATED_FROM_HISTORY`, `SIMULATED`).

```sql
-- WP-4: how many stands can this airport take for diversions at time p_at?
fogops.alt_stand_capacity(p_scenario_id int, p_iata char(3), p_at timestamptz)
  RETURNS TABLE (stands_total int, arrivals_per_hr int, quality text, basis text, sample_n int)
-- precedence: latest airport_status_event.parking_available (people, current) > configured assumption > history estimate > NULL

-- WP-5: fuel picture for one flight right now (never overrides an entered or fed estimate)
fogops.flight_fuel_outlook(p_scenario_id int, p_flight_id bigint, p_at timestamptz)
  RETURNS TABLE (fuel_on_board_kg numeric, burn_kg_per_hr numeric, hold_minutes numeric, quality text, basis text,
                 fuel_at_dest_min_above_reserve int, dest_iata char(3), remaining_flight_min int)

-- WP-6: connections that would be missed if the flight arrives at p_arrival_utc
fogops.connection_risk(p_scenario_id int, p_flight_id bigint, p_arrival_utc timestamptz)
  RETURNS TABLE (connections_total int, pax_total int, connections_at_risk int, pax_at_risk int,
                 tightest_slack_min int, min_connection_min int, quality text, basis text)
```

If a package finds a contract cannot work, it stops and agrees a change with the WP-7 owner before merging.

## Facts every brief relies on (checked against the real database)

- Alternates for SHJ: AAN, AUH, DWC, FJR, MCT, RKT. `alternate_airport.max_parking_stands` is NULL for all of them today.
- Historical arrivals per hour (peak) at the alternates are thin: RKT 817 hours of history (peak 3), MCT 512 (peak 2), FJR 11 (peak 9),
  AAN 4, AUH 8, DWC 1. SHJ has 6,960 hours (peak 22). Only RKT and MCT are trustworthy from history, so a configured assumption is required.
- Historical fuel: `hist.fuel` has 65,922 rows (61,273 plausible); 63,534 join to `hist.flight`. Median burn over 58,564 plausible legs is about
  2,485 kg/h (the engine assumes 2,400). No function reads `hist.fuel` today.
- The engine today (`rank_alternates`, migration V8) uses fuel on board and burn rate only when a fuel estimate row has them. The real database has
  0 fuel estimates until someone enters them or `/api/feed/push` simulates them.
- `pax_connection` in a database loaded with the old loader is wrong (9,626 pairs, 5,059 reversed). The repair script gives 5,044 pairs and 31,454 pax.
