# Release checklist for the shared (real) database

Packages are verified on scratch copies. Only the lead applies them to the shared database `hackathon_yashasvi`, one step at a time. Flyway applies pending
migrations **when the Spring jar starts**, so starting the jar against the real database is itself a deployment.

Before every step: `pg_dump -Fc hackathon_yashasvi > backup_<step>.dump` (via `docker exec yashasvi-postgres`), and tell the team.

| Step | Action | Check afterwards |
|---|---|---|
| R1 (pending today) | Start Spring with Flyway on: applies V7 and V8 (`divert_policy`, `leg_time_reference`, new `rank_alternates`) | `/health` shows `V8__rank_alternates_fuel_policy.sql`; `leg_time_reference` has 12 rows |
| R2 (pending today) | Run `db/fogops/fix_pax_connection.sql` once | `pax_connection` is 5,044 pairs and 31,454 pax, 0 reversed |
| R3 | After WP-4 merges: V9 | `airport_capacity` exists; open the capacity screen; enter the assumed stands per airport with a real "basis" |
| R4 | After WP-5 merges: V10 | `fuel_burn_reference` filled; check an airborne flight's outlook |
| R5 | After WP-6 merges: V11 | confirm the minimum connection time with the airline and set `min_connection_min` |
| R6 | After WP-7 merges: V12 | compare recommendations before and after on three flights with the duty manager |
| R7 | After WP-1 merges | start with `WORKER_ENABLED=true`; push live data; watch the queue drain and the screens refresh |

Rules: never run `reset-db.sh` or `rebuild.sh`; never edit an applied migration; if a step goes wrong, restore the dump taken just before it and report.
