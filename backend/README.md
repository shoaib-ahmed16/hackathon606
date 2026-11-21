# Foooh! database (schema `fogops`)

Backing store for **Foooh!**, the disruption control room for airline operations (fog operations and crew duty recovery). The schema keeps its internal name `fogops`; renaming it would break existing databases.

The database holds:

- the flight feed;
- crew pairings and FDP rules;
- airport status;
- agent recommendations;
- human decisions;
- station updates;
- recovery plans;
- a complete, append-only audit trail.

It has been tested end to end on PostgreSQL 16 with the files supplied for the hackathon. It requires PostgreSQL 14 or newer.

```
fogops_db/
├── rebuild.sh                     drop + create + load (one command)
├── sql/01_schema.sql              43 tables (schemas: fogops, hist)
├── sql/02_functions_triggers.sql  ingestion, legality engine, guardrails, audit, recovery, report
├── sql/03_views.sql               read models for the frontend
├── sql/04_seed_reference.sql      crew types, roles, demo users, feed sources, LIVE scenario
├── sql/05_demo_fog_replay.sql     final-challenge replay on real 21 Nov flights (also an e2e test)
└── loader/load_data.py            loads the supplied Excel files
```

## Quick start

```bash
pip install pandas openpyxl xlrd psycopg2-binary airportsdata
export PGHOST=127.0.0.1 PGUSER=postgres            # or FOGOPS_DSN=postgresql://...
./rebuild.sh /path/to/hackathon/files fogops       # ~1 min
psql -d fogops -f sql/05_demo_fog_replay.sql        # optional: run the fog replay
```

Expected loader output with the supplied files:

| Item loaded | Count |
|---|---|
| Flights | 855 (plus 30 legs that exist only in the duty sheets) |
| Duties | 524 |
| Crew assignments | 3,224 |
| Roster rows | 26,172 |
| Standby slots | 1,020 |
| Historical flights | 65,943 |
| Block-time routes | 249 |

Legality status of the 524 duties:

| Status | Duties |
|---|---|
| LEGAL | 335 |
| AT_RISK | 26 |
| VERIFICATION_REQUIRED | 163 (see "Open questions") |

## Database changes: migrations (no more dump and restore)

The database is restored **once** from `db/init/10_fogops.sql.gz`. Every later change to tables, views or
functions is a numbered SQL file in [`migrations/`](migrations/), applied automatically when the API starts
([`app/migrate.py`](app/migrate.py)).

| Item | How it works |
|---|---|
| Naming | `NNN_short_name.sql` (three digits), applied in filename order |
| Tracking | `fogops.schema_migration` (file name, checksum, time applied). `GET /health` shows the latest as `migration` |
| Each file | Runs once, in its own transaction. If it fails, nothing from that file is kept and the error is in the API log (`MIGRATION FAILED`) |
| Fresh volume or existing volume | Both end at the same level, because the restored dump is older than the migrations |
| Concurrency | A Postgres advisory lock stops two API instances migrating at once |
| Edited after applying | Reported as a checksum mismatch and **not** re-applied. Add a new file instead |

**To make a database change:** add `migrations/00N_what_it_does.sql`, write it so it can be re-run safely
(`IF NOT EXISTS`, `CREATE OR REPLACE`; use `DROP FUNCTION` first if the return columns change), then
`docker compose up -d --build api`. Test it on a copy first:
`createdb fogops_test && pg_dump fogops | psql fogops_test`, then run `app.migrate` with `FOGOPS_DSN` pointing at the copy.

`backend/.dockerignore` excludes `*.sql`; it has an exception for `migrations/*.sql`. Keep it.

Applied so far:

| File | What it adds |
|---|---|
| `001_diversion_leg_times.sql` | `divert_policy` (constants), `leg_time_reference` (hub to alternate airborne times), `refresh_leg_time_reference()` |
| `002_rank_alternates_fuel_policy.sql` | New `rank_alternates()`: historical flight times, final-reserve fuel check, bingo time, return-to-base arrival |
| `003_mvp_extensions.sql` | New Plan appendices A and B: `flight_subscription`, `notification_outbox`, `data_request`, `ops_rule`, `approval_policy` (multi-role approval trigger), `external_system` + `integration_outbox` + `deep_link()`, `case_comment.kind`, `v_flight_severity`, `v_disruption_kpis`, notification fan-out and aeroMart outbox triggers |
| `004_connections_and_diversion_fix.sql` | `pax_connection` normalised to one row per connection (5,061 connections, 31,548 pax), `connection_iata` / `sched_connection_min`, `v_connection_risk`, `execute_diversion()` safe when a recovery leg already exists in another scenario |
| `005_approval_policy_hold_cancel.sql` | HOLD and CANCEL need OCC approval (without a policy row any approver could approve) |
| `006_ops_rule_matches.sql` | custom rules: remembers which flights an ALERT rule already matched; audit on `ops_rule` |
| `007_clearway_v2.sql` | v2 mockup: approval policy as agreed (DIVERT needs OCC and Crew Control), `flight_tag`, role-based notifications (approval needed, approved, rejected, data requested) |

If `hist.flight` is ever reloaded, or alternates change, run `SELECT fogops.refresh_leg_time_reference();`.

### Local ports

The project's `docker-compose.yml` maps the database to `127.0.0.1:${DB_PORT}` (the local `.env` uses 5434).
`backend/docker-compose.yml` (a separate database, container `fogops-postgres`, volume `backend_fogops-data`) uses 5433.
They hold **different copies of the data**; check which one you are connected to. `DB_PASSWORD` in `.env` must match the
password the database volume was created with, or the API cannot log in.

## Design principles

1. **Event in, state out.**
   - `flight_event` and `airport_status_event` are append-only.
   - `flight_state` is a projection of those events.
   - Duplicate messages are rejected by `(source, message_id)`.
   - An event that arrives late never overwrites a newer value, because each field remembers the timestamp that last set it.
2. **Status is derived, never typed.** Flight status comes from the actual times (OUT/OFF/ON/IN), the diversion state and holding state. The source `Status` column is always `SCH`, so it is ignored.
3. **The agent recommends; humans decide.**
   - `recommendation` holds what the agent suggests.
   - `decision` holds what a human chose.
   - `decision_approval` holds who authorised it.
   - Triggers block decisions or approvals by non-human roles and illegal status transitions. A decision's content cannot be edited; you record a new decision instead.
4. **Rules are versioned and frozen.**
   - Every legality result stores the `rule_set` and `fdp_rule` it used, plus every input.
   - An approved rule set cannot be edited, only retired and replaced by a new version.
5. **Missing or conflicting input never gives a "legal" result.** Any of the following produces `VERIFICATION_REQUIRED` and an entry in `data_exception`:
   - a missing sign-in time;
   - a crew type with no rule;
   - a stale feed for a flight in progress;
   - the duty sheet disagreeing with the rule set.
6. **Results are recomputed, never overwritten.** `fdp_calculation`, `latest_departure_calc`, `recommendation` and `recovery_plan` keep their history through `is_current` / `SUPERSEDED`.
7. **Scenarios isolate what-ifs.**
   - LIVE, REPLAY and WHATIF scenarios each have their own flight state, crew legs, crew assignments and calculations. `clone_scenario()` copies a starting point.
   - REPLAY and WHATIF scenarios run on a simulated clock (`sim_clock_utc`), and every "when" column is stamped with that clock.
8. **UTC everywhere.** Local time is always derived from `airport.tz`. The roster file is local time, so it is stored as local and as converted UTC side by side.

## Entity relationships (core)

```mermaid
erDiagram
    scenario ||--o{ disruption_case : contains
    scenario ||--o{ flight_state : "projects"
    flight ||--o{ flight_event : "feed"
    flight ||--o{ flight_state : ""
    disruption_case ||--o{ case_flight : watches
    flight ||--o{ case_flight : ""
    crew_duty ||--o{ crew_duty_leg : "sectors (per scenario)"
    flight ||--o{ crew_duty_leg : ""
    crew_duty ||--o{ crew_assignment : "who (temporal, per scenario)"
    crew_member ||--o{ crew_assignment : ""
    crew_member ||--o{ roster_entry : ""
    crew_member ||--o{ standby_slot : ""
    rule_set ||--o{ fdp_rule : ""
    fdp_rule ||--o{ fdp_calculation : "applied in"
    crew_duty ||--o{ fdp_calculation : ""
    fdp_calculation ||--o{ latest_departure_calc : ""
    disruption_case ||--o{ recommendation : ""
    recommendation ||--o{ recommendation_option : "ranked"
    recommendation ||--o{ decision : "may lead to"
    decision ||--o{ decision_approval : ""
    decision ||--o| diversion : "executes"
    diversion }o--|| flight : "recovery leg (G9xxxD)"
    decision ||--o{ crew_replacement : ""
    disruption_case ||--o{ recovery_plan : ""
    recovery_plan ||--o{ recovery_plan_item : ""
    disruption_case ||--o{ case_comment : ""
    disruption_case ||--o{ report : ""
```

`audit_log` is filled by triggers on every user-facing table. `reassessment_queue` is filled whenever an input changes.

## Table catalogue

| Group | Tables |
|---|---|
| Reference | `airport` (IANA tz, min ground time), `alternate_airport`, `aircraft`, `crew_type`, `block_time_reference` |
| Users and scope | `app_role`, `app_user`, `scenario`, `disruption_case`, `case_flight` (watch list, fog exposure, owner) |
| Rules | `rule_set` (versioned, approved, discretion minutes, band reference), `fdp_rule` |
| Flights | `flight`, `flight_event`, `flight_state`, `feed_source` (freshness), `flight_fuel_estimate` (quality-labelled), `pax_connection` |
| Airports | `airport_status_event` (open/restricted/closed, capacity, forecast reopening, alternate suitability) |
| Crew | `crew_member`, `crew_qualification` (LVP, ETOP, TRN), `crew_duty`, `crew_duty_leg`, `crew_assignment`, `roster_entry`, `standby_slot` |
| Calculations | `fdp_calculation`, `latest_departure_calc` |
| Decisions | `recommendation`, `recommendation_option`, `decision`, `decision_approval`, `diversion`, `crew_replacement` |
| Recovery | `recovery_plan`, `recovery_plan_item` |
| Collaboration and logs | `case_comment`, `audit_log`, `data_exception`, `reassessment_queue`, `report` |
| History | `hist.flight` (incl. 158 diversions), `hist.fuel` (implausible rows flagged) |

## How user actions are stored

Every API transaction starts with `SELECT fogops.set_actor(:user_id);`. The audit trigger uses it to record who did what, and the guardrails use it to check roles.

| UI action | Write | What happens automatically |
|---|---|---|
| Feed message arrives | `ingest_flight_event(scn, source, msg_id, flight_id, type, event_ts, payload)` | Duplicates and out-of-order updates are handled, status is re-derived, freshness is updated, and a reassessment is queued with NOTIFY |
| OCC sets SHJ closed or reopening forecast | `INSERT airport_status_event` | Audited; reassessment queued |
| Agent posts advice | `INSERT recommendation` + `recommendation_option` | The previous open recommendation for that flight is superseded and linked |
| Dispatch decides to divert or hold | `INSERT decision (status PROPOSED)` | Human role enforced; audited |
| OCC approves or rejects | `INSERT decision_approval` | The decision becomes APPROVED/REJECTED and the recommendation becomes ACCEPTED/REJECTED |
| Execute the diversion | `execute_diversion(decision_id)` | Creates the recovery leg (e.g. `G9588D RKT-SHJ`) and the `diversion` record, adds a sector to every affected crew duty, then recomputes legality and latest departure |
| Station update (landed, refuelled, waiting for…) | `UPDATE diversion` | Audited; feeds "what is it waiting for?" |
| Crew swap or replacement | `swap_crew(scn, duty, out, in, reason, sign_in, station, from_leg)` + `INSERT crew_replacement` | Temporal history kept; reassessment queued |
| Comment | `INSERT case_comment` | Role-labelled; append-only |
| Recompute | `compute_flight_legality(scn, flight)`, `compute_latest_departure(scn, flight, buffer_min)` | Stores rule, inputs and margins |
| Recovery order | `build_recovery_plan(scn, case, window_min, weights)` | Arrival slots against capacity, with feasibility flags and reasons |
| Report | `generate_report(case, user)` | Reproducible JSON snapshot with an audit watermark |
| What-if | `clone_scenario(src, name, 'WHATIF', overrides)` | Isolated copy of state, crew and calculations |

**Live updates.** A backend worker runs `LISTEN fogops_reassess` and processes rows from `reassessment_queue`. Typical work is recomputing legality and asking the agent for fresh recommendations. The frontend can then be pushed changes over WebSocket/SSE.

## Frontend read models (views)

| Screen or question | View / function |
|---|---|
| Single flight watch | `v_flight_watch`: status, aircraft, route, ETA, fog exposure, captain, duty margin, recommendation, decision, alternate, latest legal and target departure, owner, data age, open exceptions |
| **Q1** Which crew runs out of legality next? | `v_crew_legality_ranking ORDER BY minutes_until_legal_end` (shows the rule, band, legs and inputs used) |
| **Q2** Where is aircraft X and what is it waiting for? | `v_aircraft_whereabouts WHERE registration = 'A6-…'` |
| **Q3** What time must it leave to land legal? | `v_flight_watch.latest_legal_offblocks_utc / _local`, `operational_target_utc` and the live `departure_legality` |
| **Q4** Who is the alternate crew without breaking rosters? | `standby_candidates(scn, duty, position, station, from_leg)` (legality for the remaining legs, LVP, positioning time, roster conflicts) |
| Recovery order | `v_recovery_plan_current` |
| Decision history | `v_decision_log` |
| Shared timeline | `v_case_timeline` (feed, airport, decisions, approvals, crew, comments on one scenario clock) |
| Airport status, feed freshness, issues | `v_airport_status_current`, `v_feed_freshness`, `v_open_exceptions` |

## Data findings built into the load

- **Time zones:** the OCC rotation and duty sheets are UTC, but the roster is local time.
- **FDP band:** the duty sheet's `maxFdp` agrees with `Crew_FDTL.xlsx` for 96–99% of crew starting in the UAE when the sign-in station's local time is used.
- **Mismatches are flagged, not guessed.** Any disagreement becomes `SHEET_MAXFDP_MISMATCH` with both values and a conservative value.
- **Crew and aircraft are linked by flight number, date and route,** never by registration. Four aircraft swaps are flagged.
- **30 legs appear only in the duty sheets** (for example, returns on 24 Nov). They were created so that crew sector counts are complete.
- **Historical diversions** give the alternate ranking (FJR, RKT, MCT, AAN…) and P90 block times for alternate→SHJ.
- **Dirty fuel rows** (4,649) are flagged as implausible.

## Diversion model (how "can it divert, and what then?" is answered)

Implemented in `rank_alternates(scenario, flight)`; every option carries its basis so a reviewer can see what is
measured, historical or assumed. All timing comes from the supplied Excel files; nothing is invented except the
labelled assumptions below.

1. **Flight time hub to alternate.** `leg_time_reference` holds the **airborne time** (take-off to touchdown) from
   `hist.flight`, both directions of a pair pooled, outliers (under 5 or over 150 minutes) excluded. **P50** is used for
   the arrival estimate and **P90** for the fuel check. A pair with fewer than 5 historical flights uses a distance
   estimate (great-circle distance at 8 km/min + 8 min, P90 = 1.25 x) and is labelled `ESTIMATED`.
   Today: SHJ-FJR 18/24 min (32 flights), SHJ-RKT 15/19 (89), SHJ-AAN 26/35 (9), SHJ-AUH 29/36 (14),
   SHJ-MCT 40/45 (1,010), SHJ-DWC 16/20 **ESTIMATED** (2 flights).
2. **Fuel check.** Minutes of fuel on board now = latest `fuel_on_board_kg` / `burn_rate_hold_kg_per_hr`, less the time
   since that estimate. **Margin = that minus the P90 leg time minus the final reserve (30 min).** Negative margin blocks
   the alternate with `CANNOT_REACH_WITH_FUEL`. With no fuel on board or burn rate (only an endurance figure), the older rule
   is kept and labelled `LEGACY`. With no fuel data at all the option is `verify`, never executable.
3. **Bingo time** (`bingo_utc`): now + margin, the latest moment the aircraft can leave the hold for that alternate and still land with
   the final reserve.
4. **Return to base.** Alternate to hub block time: **P90** protects crew legality (`latest_legal_return_dep_utc`), the
   **median** gives the expected arrival (`return_arrival_hub_utc` = earliest departure after the ground time + median block).
   Ground time at the alternate is the airport's minimum ground time. The return cannot be planned before the hub's forecast reopening.
5. **Crew, stands, status, LVP** checks are unchanged (see the function and `score_breakdown`).

## Decisions made without organizer input

Only the supplied Excel files exist, so these were decided on aviation practice and the data. Change a constant with
`UPDATE fogops.divert_policy SET value = ... WHERE key = ...` (no migration needed); change logic with a new migration.

| # | Decision | Reason | Where |
|---|---|---|---|
| D1 | Final reserve = **30 min** | ICAO Annex 6 Part I (turbine aeroplanes): final reserve at holding speed. The legal floor; a stricter company figure was not supplied | `divert_policy.final_reserve_min` |
| D2 | Hold burn **2,400 kg/h** kept | The history implies a median of about 38 kg/min (2,280 kg/h) and P90 43 kg/min (2,580 kg/h) on 30-90 min sectors, so it is the right order | `flight_fuel_estimate.burn_rate_hold_kg_per_hr` |
| D3 | P50 for arrival time, **P90 for the fuel check** | Fuel decisions must be conservative; ETAs should be typical | `rank_alternates` |
| D4 | Airborne time (not block) for the outbound leg | The aircraft is already airborne; taxi does not apply | `leg_time_reference` |
| D5 | Pairs with under 5 flights use distance, labelled `ESTIMATED` | Never present a guess as history | `divert_policy.min_leg_sample_n` |
| D6 | Fuel estimate is **burned down to "now"** | A 90-minute-old estimate must not look fresh | `rank_alternates` |
| D7 | Old "2,300 kg minimum diversion fuel" no longer subtracted | It was an assumption (not from the Excel files) and double-counted the flight time. Margins are about 20-45 min less pessimistic than before | migration 002 |
| D8 | The 158 historical diversions are not used for timing | They are mostly flights that left SHJ and diverted elsewhere, not SHJ arrivals diverting to these alternates | n/a |
| D9 | Road positioning minutes stay **assumed** | Not in the Excel files | `alternate_airport` |

## Open questions for the organizers

Each item below is currently handled as "verification required" or as a labelled assumption.

1. **Crew types SO, SEC and EN are not in `Crew_FDTL.xlsx`.**
   - SO blocks a legality verdict.
   - SEC and EN are flagged but do not gate the flight.
2. **Outstation sign-ins disagree with the table**, for example 11:30 in the sheet against 13:00 in the table for 1 leg. This is probably acclimatisation rules, which are not in the supplied file.
3. **The time zone of the "Standby Details" times** is not stated. They were loaded as UTC on the sheet date.
4. **Minimum rest after duty** is not supplied. 12 hours is assumed, and it is used only for roster-conflict checks.
5. **The meaning of the 0-leg FDP rows** and of PTD/PTA in the 16:45 snapshot.
6. **Should LVP qualification be a hard constraint** for landing at SHJ in fog? Today it is stored and shown in the standby candidates.
7. **Does the airline have a company minimum landing fuel** above the 30-minute final reserve? If so, set it in `divert_policy` and the engine should use it (decision D1).
8. **Real hold burn rate and fuel on board per flight.** Today these are estimates; the Excel files give fuel at departure only.

## Notes

- The LIVE scenario clock is set to the time of the latest snapshot (20 Nov 16:45Z). Once a real feed is connected, set `scenario.sim_clock_utc = NULL` for LIVE so it uses the wall clock.
- The 12-per-hour reopening capacity, road positioning times and holding endurance values in the demo are **simulated or assumed**. They are labelled as such in the data (`quality`, `assumptions`, `notes`).

## Installing a new database drop from the DB team
```
backend/scripts/install_db_drop.sh ~/Downloads/fogops_db.zip      # or an unpacked folder
```
It shows which files changed, replaces `backend/fogops_db/sql` and `loader`, builds the database in a throwaway Postgres container
(baseline SQL + the Excel files + demo replay), writes `backend/db/init/10_fogops.sql.gz`, restores that seed into a clean database and
applies our `backend/migrations` on top to prove they still fit. Then commit and, on the server, `git pull && ./reset-db.sh`.
Our own changes never live inside `fogops_db/` (always in `migrations/`, `scripts/` and `app/`), so a drop is a plain overwrite.
The 06/07 "proposed" SQL files in a drop are not applied: our migrations already provide those features.
