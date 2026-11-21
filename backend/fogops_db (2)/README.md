# FogOps database: handover guide

PostgreSQL backend for the **Fog Operations & Crew Duty Recovery Agent** (Hack606, Air Arabia / SHJ).

This README is written so that another engineer **or another AI agent** can pick up the work without the original conversation. Read sections 1–4 before changing anything.

---

## 0. TL;DR

| Topic | Summary |
|---|---|
| What it is | A PostgreSQL 14+ database holding SHJ fog disruption data: live flight state, crew FDP legality, hold/divert options, human decisions, station updates, recovery order, audit log and reports |
| Where | Schemas `fogops` (operational) and `hist` (history, read-only reference). 43 tables, 11 views, about 30 callable functions plus trigger functions |
| Build | `./rebuild.sh <data_dir> [dbname]` drops, creates and loads the organizer files (about 1 minute) |
| Prove it works | `psql -d fogops -f sql/05_demo_fog_replay.sql`, then compare with `sql/05_demo_expected_output.txt`. Zero `ERROR` and zero `UNEXPECTED` lines are expected |
| Golden rule | **The engine recommends; humans decide.** The database enforces this and every other safety guardrail (section 3) |

---

## 1. Problem context in one page

Dense fog closes or restricts **Sharjah (SHJ)**. Inbound aircraft must either:

- **hold** (circle until SHJ reopens, limited by fuel), or
- **divert** to an alternate airport (RKT, FJR, AAN, DWC, AUH, MCT) and fly back later.

Each diversion adds a **sector** (flight leg) to the crew's duty. That shortens their legal **Flight Duty Period (FDP)**. Crew may then time out at the alternate and need a **replacement crew** from standby. When SHJ reopens with limited arrival capacity, flights must be **sequenced**.

The system keeps one live, explainable, auditable picture for:

- **OCC** (Operations Control Centre);
- **Dispatch**;
- **Crew Control**;
- **Stations** (the ground teams at alternates).

### Glossary

| Term | Meaning |
|---|---|
| STD / STA | Scheduled departure / arrival |
| ETD / ETA | Estimated departure / arrival |
| ATD / ATA | Actual departure (off-blocks) / arrival (on-blocks) |
| TOFF / TDOWN | Wheels off / wheels on |
| Sector / leg | One flight A→B |
| Duty / pairing | A crew's sequence of legs for one duty period. One `crew_duty` row |
| Sign-in | Crew report time; the FDP clock starts here |
| FDP | Flight Duty Period: from sign-in to on-blocks of the last leg. Maximum comes from `Crew_FDTL.xlsx` by crew type × SHJ-local sign-in band × number of legs |
| Commander discretion | Captain may extend FDP by up to +3 h (180 min). Shown separately, never planned by default |
| LVP | Low Visibility Procedures. While in force, both pilots (CP and FO) must be LVP-qualified to land |
| Crew types | CP captain, FO first officer, SO second officer, CS cabin supervisor, CC cabin crew, SEC security, EN engineer |
| Alternate | Diversion airport |
| Recovery leg | The flight from the alternate back to the hub, created on diversion with a `D` suffix (e.g. `G9588D RKT-SHJ`) |
| Block time | Off-blocks to on-blocks duration |

---

## 2. Repository map

```
fogops_db/
├── README.md                        ← this file
├── rebuild.sh                       drop + create DB, apply SQL 01-04, run loader
├── sql/
│   ├── 01_schema.sql                types, tables, indexes, constraints (fogops + hist)
│   ├── 02_functions_triggers.sql    all logic: audit, guardrails, ingestion, legality,
│   │                                latest departure, diversion, crew swap, standby search,
│   │                                LVP, alternate ranking, hold/divert proposal,
│   │                                recovery plan, scenario clone, report
│   ├── 03_views.sql                 read models used by the frontend
│   ├── 04_seed_reference.sql        crew types, roles, demo users, feed sources, LIVE scenario
│   ├── 05_demo_fog_replay.sql       end-to-end replay of the final challenge (also the e2e test
│   │                                and the reference for how the API should call the DB)
│   ├── 05_demo_expected_output.txt  output of the demo for comparison
│   ├── 06_proposed_extensions.sql   MVP additions (subscriptions, notifications, data requests, custom rules,
│   │                                approval policy, external systems, KPI/severity views); not in rebuild.sh yet
│   └── 07_proposed_triggers.sql     multi-role approval, notification fan-out, aeroMart outbox
└── loader/load_data.py              loads the organizer Excel files into the schema
```

**Order matters.** Apply 01 → 02 → 03 → 04, then run the loader. `rebuild.sh` does this for you. Section J of file 02 ends with a block that pins `search_path` on every function. Keep it last whenever you add functions; otherwise re-run it (see section 15).

---

## 3. Golden rules (invariants enforced by the database)

An agent extending this system **must not** work around these. Most are enforced by triggers and will raise an exception if violated.

1. **Call `SELECT fogops.set_actor(<user_id>);` at the start of every write transaction.**
   - The audit trail and the role checks depend on it.
   - `swap_crew` refuses to run without it.
2. **Never write `flight_state` directly.**
   - All flight changes go through `ingest_flight_event(...)`. It deduplicates by `(scenario, source, message_id)`, ignores out-of-order fields, derives status and queues reassessment.
3. **Status is derived, never typed.** `derive_flight_status()` computes it from the actual times plus holding, diversion and cancellation flags. The source file's `Status` column (always `SCH`) is ignored.
4. **Only humans decide.**
   - `decision.decided_by` must be a user whose role has `is_human = true` (not `AGENT`).
   - `decision_approval.approver_id` must be a human with `can_approve`: OCC, DISPATCH, CREW_CONTROL or RECOVERY. STATION and ADMIN cannot approve.
5. **Decisions are immutable.**
   - The content columns (type, rationale, decided_by, flight, alternate) cannot be edited.
   - Allowed status transitions:
     - PROPOSED → APPROVED / REJECTED / REVOKED
     - APPROVED → EXECUTED / REVOKED
     - EXECUTED → REVOKED
   - REVOKED requires `revoked_by` and `revoke_reason`.
   - New decisions must be inserted as PROPOSED. Approval happens only by inserting into `decision_approval`.
6. **Rules are versioned and frozen.**
   - An APPROVED `rule_set` and its `fdp_rule` rows cannot be edited or deleted; you can only retire it (set `status`/`effective_to`).
   - To change a rule, insert a new rule-set version as DRAFT, add its rules, then approve it.
7. **Append-only tables:** `audit_log`, `airport_status_event`, `decision_approval`, `case_comment`.
   - `flight_event` rows are immutable except the projector bookkeeping (`apply_result`, `fields_applied`), which is filled in once.
   - To "change" an airport status, insert a newer event.
8. **Missing or conflicting input never yields LEGAL or "executable".** It yields `VERIFICATION_REQUIRED` (legality) or a blocking constraint with `verify: true` (options), plus a `data_exception` row.
9. **Everything is scenario-scoped.**
   - `flight_state`, `crew_duty_leg`, `crew_assignment`, calculations, recommendations, decisions, diversions and plans all carry `scenario_id`. Always filter by it.
   - Replays and what-ifs never touch LIVE (scenario 1).
10. **All stored timestamps are UTC `TIMESTAMPTZ`.** Local time is derived with `airport.tz` (IANA).
11. **Every estimated or assumed value carries a quality label** (`data_quality` enum: MEASURED, FORECAST, SIMULATED, ASSUMED, ESTIMATED, MANUAL) or an `assumptions` entry. Never present an estimate as a fact.
12. **Never invent FDP limits.** Only `fdp_rule` rows of the approved rule set are used. A crew type or leg count without a rule gives `NO_FDP_RULE` → VERIFICATION_REQUIRED.

---

## 4. Confirmed business rules vs assumptions

### Confirmed by the organizers (treat as requirements)

| Rule | Where it lives |
|---|---|
| FDP time band uses **SHJ local time (UTC+4)** for all crew | `rule_set.band_reference = 'FIXED_TZ'`, `band_tz = 'Asia/Dubai'` |
| Flight times (rotation, feed, duty-sheet legs and sign-in) are **UTC** | loader + every `*_utc` column |
| Crew roster check-in/out times are **SHJ local** for all crew | `roster_entry.start_local/end_local` with `local_tz = 'Asia/Dubai'`, converted to `start_utc/end_utc` |
| **LVP qualification is required for fog landings** | `crew_type.requires_lvp` (CP, FO = true); `airport_status_event.lvp_in_force` |
| Commander discretion **+3 h** on top of FDP limits | `rule_set.commander_discretion_min = 180` |
| Use the **actual assigned crew**, never aircraft rotation or registration, as a proxy | crew linked to flights via `crew_duty_leg` (matched by flight number + route + STD), never by registration |

### Assumptions (labelled in the data, configurable)

| Assumption | Value | Where to change |
|---|---|---|
| Duty-sheet `maxFdp` that disagrees with the rules | WARN (log it, don't block) | `rule_set.parameters.sheet_mismatch_policy` (`WARN` or `BLOCK`); requires a new rule-set version |
| Minimum rest after duty (roster-conflict check only) | 720 min | `rule_set.parameters.min_rest_after_duty_min` |
| AT_RISK threshold | margin < 60 min | `rule_set.at_risk_threshold_min` |
| Positioning legs count as sectors | no | `rule_set.count_positioning_as_leg` |
| Standby sheet times | UTC on the sheet date | loader (`standby_slot.times_basis = 'ASSUMED_UTC_SAME_DATE'`) |
| Road positioning SHJ→alternate | RKT 60, FJR 90, DWC 60, AAN 120, AUH 120 min; MCT = deadhead | `alternate_airport.road_positioning_min` |
| Aircraft position for diversion distance | in the hub terminal area | `rank_alternates(p_km_per_min = 7.0, p_approach_min = 10)` |
| Hold beats divert if fuel spare at landing is at least the buffer | 15 min | `propose_hold_or_divert(p_min_hold_spare_min)` |
| Operational buffer before latest legal departure | 30 min | `compute_latest_departure(p_buffer_min)` |
| Recovery capacity when SHJ status has none | 20 arrivals/h | `scenario.overrides.recovery_capacity_per_hr`, or `arrival_capacity_per_hr` on the status event |
| Demo fog timings, fuel endurance, capacities | simulated | `05_demo_fog_replay.sql` only |

---

## 5. Setup and verification

```bash
# prerequisites
pip install pandas openpyxl xlrd psycopg2-binary airportsdata
export PGHOST=127.0.0.1 PGUSER=postgres          # or FOGOPS_DSN=postgresql://user@host:5432/fogops

# build + load (expects the organizer files in one folder; zip contents extracted)
./rebuild.sh /path/to/files fogops

# end-to-end test / demo
psql -d fogops -f sql/05_demo_fog_replay.sql > /tmp/demo.out
grep -c "ERROR\|UNEXPECTED" /tmp/demo.out        # expect 0
```

The loader expects these files: `OCC_Flight_Rotation_20Nov_23Nov26.xls`, `OCC_Flight_Rotation_as_of_*.xls`, `Crew_duty_sheet_*.xlsx`, `Crew_Roster_Next_10_Days.xlsx`, `Crew_FDTL.xlsx`, `Connecting_pax_data*.xlsx`, `Historical_Flight_Data_Jan-Nov_2026.xlsx` and `Historical_fuel_data.xlsx`.

### Expected loader result (sanity check)

| Item | Count |
|---|---|
| Airports | 429 |
| FDP rules | 216 |
| Flights | 855 (+4 created from duty sheets; 27 duty-sheet legs with a revised time linked to the rotation flight) |
| Duties / assignments | 524 / 3,224 |
| Roster rows | 26,172 |
| Standby slots | 1,020 |
| Pax connections | 5,061 (31,548 pax) |
| History | 65,943 flights, 65,922 fuel rows |
| Block-time routes | 249 |

| Duty legality | Count |
|---|---|
| LEGAL | 416 |
| AT_RISK | 26 |
| VERIFICATION_REQUIRED | 82 (81 because of SO crew, 1 duty with no crew) |

### Smoke-test queries

```sql
SET search_path = fogops;
SELECT status, count(*) FROM fdp_calculation WHERE scenario_id=1 AND is_current AND crew_id IS NULL GROUP BY 1;
SELECT * FROM v_open_exceptions LIMIT 20;
-- worked example: G9071 cockpit crew legal until 11:05Z (sign-in 00:50Z = 04:50 SHJ, 2 legs, CP 10:15, rule 42)
SELECT position_code, legal_end_utc, max_fdp_min FROM v_crew_legality_ranking
 WHERE scenario_id=1 AND duty_legs LIKE '%G9071 ELQ-SHJ%' AND position_code='CP';
```

---

## 6. Architecture

```
 organizer files ──loader──► reference + crew + flights + history
                                    │
 feed / UI writes ──► EVENTS (append-only)            flight_event, airport_status_event
                                    │  ingest_flight_event() / triggers
                                    ▼
                    STATE (projection, per scenario)   flight_state, crew_duty_leg, crew_assignment
                                    │  compute_* functions
                                    ▼
                    CALCULATIONS (versioned)           fdp_calculation, latest_departure_calc
                                    │  propose_hold_or_divert(), build_recovery_plan()
                                    ▼
                    RECOMMENDATIONS (agent/engine)     recommendation(+_option), recovery_plan(+_item)
                                    │  humans only
                                    ▼
                    DECISIONS                          decision, decision_approval
                                    │  execute_diversion(), swap_crew(), station updates
                                    ▼
                    OPERATIONS                         diversion, crew_replacement, case_comment
 every layer ──triggers──► audit_log (append-only) ;  reassessment_queue + NOTIFY 'fogops_reassess'
 frontend ◄── views: v_flight_watch, v_crew_legality_ranking, v_aircraft_whereabouts,
                     v_recommendation_options, v_recovery_plan_current, v_case_timeline, ...
```

### Scenarios and clocks

| Scenario kind | Clock used by calculations | Clock used to stamp records |
|---|---|---|
| `LIVE` (id 1) | `scenario.sim_clock_utc` if set, else wall clock | Always the wall clock |
| `REPLAY` / `WHATIF` | `sim_clock_utc` | `sim_clock_utc` |

- **LIVE.** The loader sets its clock to 2026-11-20 16:45Z, the time of the latest snapshot. Set `sim_clock_utc = NULL` once a real feed is connected.
- **REPLAY / WHATIF.**
  - Created with `clone_scenario()`, which copies flight state, airport status history, active crew legs, active crew assignments and current legality results.
  - Advance time with `UPDATE scenario SET sim_clock_utc = ...`.
- **Helper functions:**
  - `scenario_now(scn)` gives the clock for calculations.
  - `scenario_stamp(scn)` gives the "when" value for records (wall clock in LIVE, simulated clock otherwise).
  - BEFORE INSERT triggers (`stamp_*`) apply `scenario_stamp` to `decided_at`, `approved_at`, `created_at`, `generated_at`, `entered_at`, `calculated_at` and similar columns in REPLAY/WHATIF.
  - `audit_log.scenario_time_utc` stores the scenario clock, and `occurred_at` the wall clock.

---

## 7. Data model

Each table is listed with who writes it.

| Writer | Meaning |
|---|---|
| L | Loader |
| F | Database function |
| A | API / UI (direct insert or update) |
| T | Trigger |

### Reference

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `airport` | iata | IANA `tz`, `min_ground_time_min` (turnaround), lat/lon | L |
| `alternate_airport` | (hub, alt) | priority, road positioning time, historical diversions, `hist_median_ground_min`, static flags | L |
| `aircraft` | registration | | L |
| `crew_type` | code | `category`, `gates_flight_legality` (SEC/EN = false), `requires_lvp` (CP/FO = true) | seed |
| `block_time_reference` | (from, to) | median/P90 block minutes from history | L |

### Users and scope

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `app_role` | code | `is_human`, `can_approve` | seed |
| `app_user` | user_id | role, optional `station_iata` | seed, L |
| `scenario` | scenario_id | kind, `sim_clock_utc`, `overrides` | seed, F |
| `disruption_case` | case_id | hub, phase (MONITORING → RESTRICTED → RECOVERY → CLOSED) | A |
| `case_flight` | (case, flight) | watch list: `fog_exposure`, owner user and role | A |

### Rules

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `rule_set` | rule_set_id | version, status, band_reference/band_tz, discretion, thresholds, `parameters` jsonb | L |
| `fdp_rule` | rule_id | crew_type × local band × legs (0–8) → max_fdp_min; `source_rule_id` = FDP_ID in the source file | L |

### Flights

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `flight` | flight_id; unique (flight_no, std_utc, dep_iata) | `flight_kind` SCHEDULED / RECOVERY / FERRY / POSITIONING / TEST; `parent_flight_id` for recovery legs | L, F |
| `feed_source` | source_code | OCC_ROTATION, SIM_FEED, MANUAL; freshness | seed, F |
| `flight_event` | event_id; unique (scenario, source, message_id) | raw payload; `apply_result` | F |
| `flight_state` | (scenario, flight) | projected state, `field_ts` per field, derived `status` | F |
| `flight_fuel_estimate` | estimate_id | holding endurance with a `quality` label | A |
| `pax_connection` | (inbound, outbound) | passengers arriving on `inbound_flight_id` who continue on `outbound_flight_id` at `connection_iata`. Stores `pax_count` (max of both views), `pax_inbound_view`, `pax_outbound_view`, `source_view` and `sched_connection_min` (section 12) | L |

### Airport operations

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `airport_status_event` | append-only | op_status, `lvp_in_force`, visibility, arrival capacity/h, `expected_reopen_utc`, parking, weather/handling/fuel flags, quality | A |

### Crew

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `crew_member` | crew_id | type, base, languages, aircraft types | L |
| `crew_qualification` | (crew, qual) | LVP, ETOP, TRN (parsed from duty-sheet names) | L |
| `crew_duty` | duty_id | `sign_in_utc`, report station, sheet values (comparison only) | L |
| `crew_duty_leg` | (scenario, duty, leg_seq) | `leg_source` PLANNED / DIVERSION / RECOVERY / POSITIONING; `added_by_decision_id` | L, F |
| `crew_assignment` | assignment_id | temporal (`valid_from` / `valid_to`); per-crew `sign_in_utc` override, `report_station_iata`, `from_leg_seq`, `sheet_max_fdp_min` | L, F |
| `roster_entry` | roster_id | SHJ local and UTC; FLIGHT / EVENT(SBY) / LEAVE / TRAINING / SIM / GRT / DUTY / REST | L |
| `standby_slot` | standby_id | pattern, window (UTC, assumed), status | L |

### Calculations (history kept with `is_current`)

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `fdp_calculation` | calc_id | one row per crew member, plus one duty summary row (`crew_id IS NULL`) = the binding crew; rule, inputs, margins, status, reasons | F |
| `latest_departure_calc` | calc_id | per onward leg: legal end, block basis, latest legal / with-discretion off-blocks, operational target, assumptions | F |

### Decision support and decisions

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `recommendation` | rec_id; one PROPOSED per (scenario, flight) | type, confidence, rationale, assumptions, uncertainty, approver role, input snapshot, supersede chain | F, A |
| `recommendation_option` | (rec, rank) | action, alternate, executable, score, blocking constraints, reasons, fuel/crew margins | F, A |
| `decision` | decision_id | human decision; status machine (rule 5) | A |
| `decision_approval` | append-only | verdict + comment | A |
| `diversion` | (scenario, original flight) | alternate, recovery flight, landed/on-blocks times, refuel/handling, `waiting_for`, status | F, A (stations) |
| `crew_replacement` | replacement_id | outgoing/incoming crew, standby slot, positioning, new sign-in, roster conflict, decision | A |

### Recovery, collaboration and logs

| Table | Grain / key | Notes | Writer |
|---|---|---|---|
| `recovery_plan` / `recovery_plan_item` | plan / (plan, flight) | reopening, window, capacity, weights; rank = landing order, slot, feasibility, score breakdown, reasons | F |
| `case_comment` | append-only | role-labelled | A |
| `data_exception` | one OPEN per (scenario, entity, code) | severity INFO / WARN / BLOCKING; status OPEN / ACKNOWLEDGED / RESOLVED | F, L, A (resolve) |
| `audit_log` | append-only | actor, role, scenario, case, entity, action, changed fields, before/after, scenario time | T |
| `reassessment_queue` | job_id | PENDING / RUNNING / DONE / FAILED | T, F, worker |
| `report` | report_id | JSON content + `audit_watermark_id` (reproducible) | F |

### History (`hist` schema, read-only)

- **`hist.flight`.** For diversions, `arr_iata` is where the flight actually landed and `planned_dest_icao` is where it was going.
- **`hist.fuel`.** `is_plausible` flags dirty rows.

### Enumerations

| Enum | Values |
|---|---|
| `flight_status` | SCHEDULED, TAXI_OUT, AIRBORNE, HOLDING, DIVERTING, LANDED, ON_BLOCKS, CANCELLED |
| `airport_op_status` | OPEN, RESTRICTED, CLOSED |
| `legality_status` | LEGAL, AT_RISK, DISCRETION_REQUIRED, EXCEEDED, VERIFICATION_REQUIRED |
| `rec_type` | HOLD, DIVERT, MONITOR, RECOVER, CREW_REPLACE, DELAY_DEPARTURE, NO_ACTION |
| `rec_status` | PROPOSED, ACCEPTED, REJECTED, SUPERSEDED, EXPIRED |
| `decision_type` | HOLD, DIVERT, RECOVER, CANCEL, DELAY, CREW_REPLACE, COMMANDER_DISCRETION, AIRCRAFT_SWAP, OVERRIDE, OTHER |
| `decision_status` | PROPOSED, APPROVED, REJECTED, EXECUTED, REVOKED |
| `data_quality` | MEASURED, FORECAST, SIMULATED, ASSUMED, ESTIMATED, MANUAL |
| `severity_level` | INFO, WARN, BLOCKING |

---

## 8. Function reference

All functions live in schema `fogops` with a pinned `search_path`. The "Writes" column lists side effects.

### Session and time

| Function | Purpose | Writes |
|---|---|---|
| `set_actor(user_id)` | Sets the acting user and role for the transaction | — |
| `actor_user_id()`, `actor_role()` | Read the actor | — |
| `scenario_now(scn)` | Calculation clock | — |
| `scenario_stamp(scn)` | Record-stamping clock | — |
| `to_local(ts, iata)` | Local timestamp at an airport | — |
| `fmt_min(min)` | Minutes → `±HH:MM` | — |
| `distance_km(a, b)` | Great-circle distance between airports | — |

### Flight feed

| Function | Purpose | Writes |
|---|---|---|
| `ingest_flight_event(scn, source, message_id, flight_id, event_type, event_ts, payload jsonb [, seq_no, received_at]) → text` | The only way to change flight state. Returns `DUPLICATE`, `APPLIED`, `PARTIAL_OUT_OF_ORDER` or `IGNORED_STALE` | `flight_event`, `flight_state`, `feed_source`, `reassessment_queue` |
| `derive_flight_status(state, planned_arr)` | Status derivation | — |
| `projected_on_blocks(scn, flight) → (ts, basis, stale)` | ATA, else ETA, else STA; `stale` only for in-progress flights | — |

`ingest_flight_event` details:

- **Payload keys:** `etd`, `eta`, `atd`, `toff`, `tdown`, `ata` (ISO timestamps), `registration`, `pax`, `actual_arr_iata`, `holding` (bool), `cancelled` (bool).
- **Unknown keys** are kept in the raw event but not applied (for example `ptd`/`pta`).
- **`event_type = 'BASELINE'`** suppresses the reassessment trigger; use it for bulk loads.

### Crew legality

| Function | Purpose | Writes |
|---|---|---|
| `active_rule_set(name='GCAA FDP', at)` | rule_set_id effective at a time | — |
| `lookup_fdp_rule(rule_set, crew_type, local_time, legs) → fdp_rule` | Rule lookup; bands inclusive to the minute | — |
| `compute_duty_legality(scn, duty_id, triggered_by) → legality_status` | Per-crew and duty-summary FDP results | `fdp_calculation`, `data_exception` |
| `compute_flight_legality(scn, flight_id, triggered_by) → int` | Recompute every duty operating a flight; returns the number of duties | same |
| `compute_latest_departure(scn, flight_id, buffer_min=30, block_basis='P90') → calc_id` | Latest legal off-blocks for a leg, including the rest of the duty | `latest_departure_calc` (+ recompute) |
| `lvp_in_force(scn, iata) → bool` | Current LVP flag at an airport | — |
| `flight_lvp_check(scn, flight) → (lvp_required, lvp_ok, not_qualified jsonb, dest_iata)` | Are the operating pilots LVP-cleared for the destination? `lvp_ok` is NULL if unknown | — |

### Hold / divert engine

| Function | Purpose | Writes |
|---|---|---|
| `flight_decision_inputs(scn, flight)` | One row of inputs: endurance left, fuel quality, hub status/LVP/reopening, cockpit LVP, crew legal ends now and if diverted (+1 sector) | — |
| `rank_alternates(scn, flight, km_per_min=7.0, approach_min=10)` | Ranked alternates with constraints, fuel margin, return block, crew outcome, score breakdown, reasons. **Read-only** | — |
| `propose_hold_or_divert(scn, case, flight, generated_by='rules-engine v1', approach_min=10, min_hold_spare_min=15) → rec_id` | Builds the HOLD option plus all alternates, ranks them, sets rec_type, rationale, confidence and assumptions | `recommendation`, `recommendation_option` (supersedes the previous one) |

### Operational actions

| Function | Purpose | Writes |
|---|---|---|
| `execute_diversion(decision_id [, turnaround_min])` | Requires an APPROVED DIVERT decision. Sets the flight's `actual_arr_iata`, creates the recovery flight `<flt>D` ALT→hub, inserts a RECOVERY leg into every affected duty (+1 sector), recomputes legality and latest departure, marks the decision EXECUTED | many |
| `swap_crew(scn, duty, out_crew, in_crew, reason [, sign_in_utc, report_station, from_leg_seq, source='SWAP'])` | Closes one assignment and opens another (keeps the history). For a replacement, pass the new sign-in, the station and the first leg they operate | `crew_assignment` |
| `standby_candidates(scn, duty, position, station, from_leg_seq)` | Q4: available standby crew of that position, with FDP for the remaining legs, LVP requirement, positioning time and roster conflicts (min rest). See the verdict list below | — |

`standby_candidates` returns one of these verdicts per crew member:

- `CANDIDATE`;
- `LEGAL but breaks planned roster`;
- `NOT LEGAL for remaining legs`;
- `NOT LVP QUALIFIED (…)`;
- `VERIFY: …`.

### Recovery, scenarios and reporting

| Function | Purpose | Writes |
|---|---|---|
| `build_recovery_plan(scn, case, window_min=60, weights jsonb, generated_by) → plan_id` | Sequences hub arrivals after reopening (section 10.4) | `recovery_plan`, `recovery_plan_item` (supersedes) |
| `clone_scenario(src, name, kind='WHATIF', overrides) → scenario_id` | What-if or replay copy (audit suppressed during the bulk copy; one CLONE audit row) | many |
| `generate_report(case, user_id) → report_id` | JSON disruption report: case, hub status history, flights (watch view), diversions, decisions + approvals, latest recovery plan, timeline, exception count, rule set, audit watermark | `report` |
| `enqueue_reassessment(...)`, `raise_exception_item(...)` | Internal helpers | queue / exceptions |

---

## 9. Views (frontend read models)

| View | Grain | Use |
|---|---|---|
| `v_flight_watch` | case × flight | **Main screen.** See the column list below |
| `v_crew_legality_ranking` | scenario × crew (duty still running) | **Q1**: `ORDER BY minutes_until_legal_end`. Shows rule ref, band, legs, max FDP, margin, LVP |
| `v_aircraft_whereabouts` | scenario × registration | **Q2**: `position_text`, `on_ground_at`, `waiting_for`, next flight, its latest legal departure, `position_unverified` |
| `v_recommendation_options` | recommendation × option | Options panel: rank, action, alternate, executable, score, blocking constraints, `needs_verification`, reasons |
| `v_recovery_plan_current` | plan × flight | Recovery order: rank (landing order), slot UTC/SHJ local, within window, feasible, reasons |
| `v_decision_log` | decision | Decisions with approvals (shared record) |
| `v_case_timeline` | case × event | One chronological timeline on the scenario clock: AUDIT, APPROVAL, FEED, AIRPORT and CREW streams |
| `v_airport_status_current` | scenario × airport | Latest effective status, including `lvp_in_force` |
| `v_flight_crew_legality` | scenario × flight | Binding duty-level legality (used by other views) |
| `v_feed_freshness` | feed source | Data age and `is_stale` |
| `v_connection_risk` | scenario × connection | Projected connection time and status: OK, AT_RISK (< 40 min), MISSED, INBOUND_DIVERTED or CANCELLED. Feeds the "connecting passengers affected" numbers and misconnect handling |
| `v_open_exceptions` | exception | Verification items, BLOCKING first |

`v_flight_watch` columns, grouped:

- **Flight:** status, registration, STD/ETA/ATA, ETA local, delay, holding, fog exposure.
- **Crew:** captain, `crew_status`, `crew_margin_min`, legal/discretion end.
- **LVP:** `lvp_required`, `lvp_crew_ok`, `lvp_not_qualified`.
- **Agent and decision:** recommendation + alternate + confidence, last decision.
- **Diversion and departure:** `diverted_to`, `waiting_for`, `latest_legal_offblocks_utc/_local`, `operational_target_utc`, live `departure_legality`, `minutes_to_latest_legal_departure`.
- **Ownership and data health:** owner, `data_age_min`, `open_exceptions`.

### The duty manager's questions

| Question | Query |
|---|---|
| Q1 Which crew runs out of legality next? | `SELECT * FROM v_crew_legality_ranking WHERE scenario_id=:scn ORDER BY minutes_until_legal_end` |
| Q2 Where is aircraft X and what is it waiting for? | `SELECT position_text, waiting_for, next_flight FROM v_aircraft_whereabouts WHERE scenario_id=:scn AND registration='A6-ARJ'` |
| Q3 What time must it leave to land legal? | `SELECT latest_legal_offblocks_utc, latest_legal_offblocks_local, operational_target_utc, departure_legality FROM v_flight_watch WHERE case_id=:case AND flight_no='G9588'` |
| Q4 Alternate crew without breaking rosters? | `SELECT * FROM standby_candidates(:scn, :duty, 'CP', 'RKT', :first_leg_seq) WHERE verdict='CANDIDATE'` |

---

## 10. Algorithms

### 10.1 FDP legality (`compute_duty_legality`)

For each active assignment (`valid_to IS NULL`) in the scenario:

1. **Sign-in** = `crew_assignment.sign_in_utc`, else `crew_duty.sign_in_utc`.
2. **Band local time** = the sign-in converted to `band_tz` (Asia/Dubai).
3. **Legs** = active legs with `leg_seq >= from_leg_seq`. Positioning legs are excluded unless the rule set says otherwise.
4. **Rule** = `lookup_fdp_rule(crew type, band time, legs)`.
5. **Legal end** = sign-in + `max_fdp_min`.
6. **Discretion end** = legal end + 180 min.
7. **Projected end** = on-blocks of the duty's last active leg (ATA, else ETA, else STA).
8. **Margin** = legal end − projected end. Status:

| Condition | Status |
|---|---|
| Projected end is past the discretion end | EXCEEDED |
| Margin < 0 | DISCRETION_REQUIRED |
| Margin < 60 | AT_RISK |
| Otherwise | LEGAL |

Any of the following reasons forces VERIFICATION_REQUIRED (unless the result is EXCEEDED):

- `SIGN_IN_MISSING`;
- `BAND_TIMEZONE_UNKNOWN`;
- `NO_RULE:<type>/<n> legs`;
- `PROJECTED_END_UNKNOWN`;
- `FLIGHT_FEED_STALE` (in-progress flights only);
- `SHEET_DISAGREES_WITH_RULESET` (only when the sheet policy is `BLOCK`).

Three more points:

- **Sheet cross-check.** The duty sheet is compared against the rule for the *planned* leg count. Any difference is logged as a `SHEET_MAXFDP_MISMATCH` exception.
- **Duty summary row.** The row with `crew_id IS NULL` takes the smallest-margin crew among types with `gates_flight_legality`. Its status is the worst status among those types.
- **History.** Previous rows become `is_current = false`.

### 10.2 Latest legal departure (`compute_latest_departure`)

**Latest legal off-blocks** = binding legal end − (block time of this leg + scheduled blocks of the remaining legs + min ground time between them).

| Input | Source |
|---|---|
| Binding legal end | Minimum over the gating crew on every duty operating this leg |
| Block time of this leg | P90 from `block_time_reference`, else the schedule |
| With-discretion variant | Same calculation from the discretion end |
| Operational target | Latest legal − buffer (30 min) |

`v_flight_watch.departure_legality` re-evaluates the stored result against the scenario clock at read time.

### 10.3 Hold / divert ranking (`rank_alternates`, `propose_hold_or_divert`)

**Inputs** (`flight_decision_inputs`):

- **Fuel endurance left** = latest estimate's `as_of + endurance − now`.
- **Hub:** status, LVP and reopening time (forecast or actual).
- **Crew:** cockpit LVP coverage, and legal/discretion end now and with one extra sector.

**Per alternate:**

| Quantity | Calculation |
|---|---|
| Distance | Hub → alternate |
| Flight time | distance / 7 km per min + 10 min approach |
| Fuel margin | endurance left − flight time |
| Stands left | parking available − open diversions already there |
| Return block | P90 alternate → hub (else estimated from distance) |
| Ready time | arrival + turnaround |
| Earliest return departure | max(ready, reopening − return block) |
| Latest legal return departure | legal end if diverted − return block |

**Crew outcome**, in order of preference: CREW_CAN_RETURN, then NEEDS_COMMANDER_DISCRETION, then NEEDS_REPLACEMENT_BY_ROAD, then NEEDS_REPLACEMENT_DEADHEAD; VERIFY_CREW if unknown.

**Blocking constraints** (any one makes the option non-executable):

- ALTERNATE_STATUS_UNKNOWN\*;
- ALTERNATE_NOT_OPEN;
- WEATHER_UNCONFIRMED\*;
- WEATHER_BELOW_MINIMA;
- PARKING_UNCONFIRMED\*;
- NO_PARKING;
- NO_FUEL_AT_ALTERNATE;
- NO_HANDLING;
- FUEL_ENDURANCE_UNKNOWN\*;
- CANNOT_REACH_WITH_FUEL;
- CREW_NOT_LVP_QUALIFIED_FOR_ALTERNATE.

\* means `verify: true`.

**Score of executable alternates:**

| Factor | Weight | Scale |
|---|---|---|
| Fuel | 0.30 | margin / 30 min, capped at 1 |
| Crew | 0.30 | can return 1.0; discretion 0.6; road max(0.2, 0.5 − road min / 400); deadhead 0.1; unknown 0.3 |
| Recovery | 0.15 | 1 − return block / 120 |
| Stands | 0.10 | stands / 4 |
| History | 0.15 | diversions / 30 |

**HOLD option.** The aircraft would land at max(reopening, now) + 10 min. It is blocked by:

- REOPENING_TIME_UNKNOWN\*;
- FUEL_ENDURANCE_UNKNOWN\*;
- ENDURANCE_ENDS_BEFORE_REOPENING;
- CREW_NOT_LVP_QUALIFIED_FOR_HUB;
- CREW_LEGALITY_UNVERIFIED\*;
- CREW_EXCEEDS_FDP_EVEN_WITH_DISCRETION.

**Hold policy.**

- A feasible hold with fuel spare ≥ 15 min scores 1.0 + spare/60, which places it above every diversion.
- A feasible hold below the buffer scores 0.2 and ranks after the executable diversions, with the reason given.

**Result.** `rec_type` is the rank-1 action if it is executable, else MONITOR ("manual verification required"). Confidence starts at 0.9 and is reduced by:

| Condition | Reduction |
|---|---|
| Fuel estimated | −0.15 |
| Reopening is a forecast | −0.10 |
| Crew legality unknown | −0.20 |

The minimum confidence is 0.3.

### 10.4 Recovery sequencing (`build_recovery_plan`)

**Reopening time** = the hub's OPEN event time, else `expected_reopen_utc`.

**Capacity** comes from the first available of:

1. the scenario override;
2. the status event's arrival capacity;
3. 20 per hour.

The slot interval is 60 / capacity.

**Candidates:**

- watched flights still inbound to the hub (airborne, holding or not yet departed);
- the recovery legs of open diversions.

**Score** = 0.40 fuel urgency + 0.30 crew urgency + 0.15 rotation impact (hub departures by the same aircraft within 8 h) + 0.15 pax (pax + 2 × connecting pax).

**A candidate is infeasible if:**

- its fuel endurance ends before its earliest slot ("must divert");
- its crew's latest legal departure is before its earliest possible departure (replacement or discretion needed);
- LVP is in force and a pilot is not qualified.

**Slot allocation.** Feasible flights are taken in score order. Each gets the earliest free slot at or after its own earliest arrival. The final `rank` is the landing order, with infeasible flights last. `arrivals_in_window` counts slots inside `window_min`.

### 10.5 LVP (`flight_lvp_check`)

1. **When LVP is required:** the flight's current destination (`actual_arr_iata` or the planned destination) has `lvp_in_force` in its latest status event.
2. **Who is checked:** crew assigned with a `requires_lvp` position (CP, FO) who cover this leg (`from_leg_seq <= leg_seq`).
3. **Result:**
   - `lvp_ok` is true only if all of them hold LVP.
   - It is NULL when no pilots are linked to the leg.
   - `not_qualified` lists the pilots without LVP.

---

### Time-base rules (TB-1 to TB-5)

These rules exist because of a real bug. G9822 BKK→SHJ (departs 21 Nov 01:20Z) was evaluated with a clock of 20 Nov 17:11Z. The engine assumed the diversion happened "now", which gave three wrong results:

- a return to SHJ at 18:15Z on 20 Nov, 16 hours before the crew even sign in;
- a crew margin of 963 minutes;
- "18 h 09 left" on the crew bar.

The rules:

| Rule | Statement | Where |
|---|---|---|
| **TB-1** | Every hold/divert evaluation has a **decision moment** (`anchor_utc`) that depends on the flight phase: <br>• HOLDING or AIRBORNE → the scenario clock (it can divert now); <br>• NOT_DEPARTED → projected arrival − 20 min, as a *pre-departure assessment*; <br>• diverted, landed or cancelled → not divertible | `flight_decision_inputs()` |
| **TB-2** | All diversion times are computed from the decision moment, never from "now" directly: arrival at the alternate, fuel margin, ready time, return departure, hold landing | `rank_alternates()`, `propose_hold_or_divert()` |
| **TB-3** | Crew time only "runs" after sign-in. If `duty_started = false`, the UI shows *"duty starts HH:MMZ · legal until HH:MMZ"*, never a countdown | `v_crew_legality_ranking.duty_started` |
| **TB-4** | Sanity check: a return departure earlier than the crew's sign-in means the time base is wrong. The option is blocked as `TIME_BASE_INCONSISTENT` (verify) | `rank_alternates()` |
| **TB-5** | One clock: every countdown and margin is computed against `scenario_now()` from the database. The browser clock is used only to tick the display | API + UI |

### Downstream impact (aircraft rotation, crew next duty, connections)

`downstream_impact(scenario, flight, ready_at_hub_utc DEFAULT NULL, horizon_hours DEFAULT 24)` returns two kinds of row.

**AIRCRAFT rows: the same aircraft's next legs.**

1. The aircraft's ready time is `ready_at_hub_utc` (a what-if, e.g. the diversion return time + turnaround), otherwise projected on-blocks + minimum ground time.
2. Each leg departs at max(STD/ETD, ready time). Its delay is propagated leg by leg using the scheduled block time + the minimum ground time at its arrival airport.
3. Each leg shows its own connecting passengers.

Example for G9822 → A6-ATC. If the aircraft is back at SHJ only at 12:30Z, the next legs are delayed by:

| Leg | Delay |
|---|---|
| G9181 SHJ-ELQ | +120 min |
| G9182 ELQ-SHJ | +120 min (202 connecting pax) |
| G9821 SHJ-BKK | +35 min |
| G9822 next day | +15 min |

**CREW rows: each operating crew member's next roster duty.** The remaining legs of the *current* duty are already inside legality (`compute_latest_departure` subtracts them). The rows show the rest gap against `min_rest_after_duty_min` and flag a rest conflict if it is too short.

## 11. Workflows (how the API should call the database)

`sql/05_demo_fog_replay.sql` is the executable reference for all of these.

```sql
-- every write transaction
BEGIN; SELECT fogops.set_actor(:user_id); ... COMMIT;

-- (a) feed message
SELECT ingest_flight_event(:scn,'SIM_FEED',:msg_id,:flight_id,'ETA_UPDATE',:event_ts,'{"eta":"2026-11-21T02:55:00Z"}');

-- (b) OCC: SHJ fog status (append a new event; never update)
INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force,
       arrival_capacity_per_hr, effective_from_utc, expected_reopen_utc, quality, entered_by)
VALUES (:scn,'SHJ','CLOSED','FOG',50,TRUE,0,:now,:reopen,'FORECAST',:user_id);

-- (c) station/OCC: alternate availability (required, otherwise the alternate stays "verify")
INSERT INTO airport_status_event (scenario_id, iata, op_status, parking_available, weather_above_minima,
       handling_ok, fuel_ok, lvp_in_force, effective_from_utc, quality, entered_by)
VALUES (:scn,'RKT','OPEN',4,TRUE,TRUE,TRUE,FALSE,:now,'MANUAL',:user_id);

-- (d) dispatch: fuel endurance (quality-labelled)
INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, est_holding_endurance_min, quality, basis, entered_by)
VALUES (:scn,:flight_id,:now,45,'ESTIMATED','{"from":"..."}',:user_id);

-- (e) recompute + recommend
SELECT compute_flight_legality(:scn, :flight_id, 'ui');
SELECT propose_hold_or_divert(:scn, :case_id, :flight_id);           -- as the agent user
SELECT * FROM v_recommendation_options WHERE case_id=:case_id AND flight_id=:flight_id ORDER BY rank;

-- (f) human decision -> approval -> execution
INSERT INTO decision (scenario_id, case_id, flight_id, rec_id, option_id, decision_type, alternate_iata,
       followed_recommendation, rationale, decided_by, decided_role)
VALUES (:scn,:case_id,:flight_id,:rec_id,:option_id,'DIVERT','RKT',TRUE,'...',:dispatcher,'DISPATCH') RETURNING decision_id;
INSERT INTO decision_approval (decision_id, approver_id, approver_role, verdict, comment)
VALUES (:decision_id,:occ_user,'OCC','APPROVED','...');
SELECT execute_diversion(:decision_id);

-- (g) station updates at the alternate
UPDATE diversion SET on_blocks_alt_utc=:t, status='ON_GROUND_ALT', refuel_status='DONE',
       waiting_for='HUB_REOPENING', updated_by=:station_user WHERE diversion_id=:id;
INSERT INTO case_comment (case_id, flight_id, author_id, author_role, body) VALUES (...);

-- (h) crew replacement (Q4)
SELECT * FROM standby_candidates(:scn, :duty_id, 'CP', 'RKT', :leg_seq);
-- record a CREW_REPLACE decision + approval, then:
SELECT swap_crew(:scn, :duty_id, :out_crew, :in_crew, 'reason', :sign_in_utc, 'SHJ', :leg_seq, 'REPLACEMENT');
INSERT INTO crew_replacement (...);
SELECT compute_latest_departure(:scn, :recovery_flight_id);

-- (i) recovery after reopening, report, what-if
SELECT build_recovery_plan(:scn, :case_id, 60);
SELECT generate_report(:case_id, :user_id);
SELECT clone_scenario(1, 'WHATIF_reopen_0400', 'WHATIF', '{"recovery_capacity_per_hr": 10}');
```

### Reassessment loop (backend worker contract)

**Triggers.** The queue is filled by:

| Trigger | Reason code |
|---|---|
| A flight event that changes ETA, ETD, registration, status, diversion, holding or cancellation | `FLIGHT_CHANGED` |
| An airport status event | `AIRPORT_STATUS` |
| A crew assignment insert or update | `CREW_CHANGE` |
| A decision status change to APPROVED, EXECUTED or REVOKED | `DECISION_<status>` |

**Notification.** Each new job sends `NOTIFY fogops_reassess` with payload `{"job_id","scenario_id","reason","entity_type","entity_id"}`.

**Worker steps:**

1. `LISTEN fogops_reassess`.
2. Claim PENDING jobs: `UPDATE ... SET status='RUNNING', picked_at=now() ... FOR UPDATE SKIP LOCKED`.
3. Recompute the affected calculations: `compute_flight_legality`, then `compute_latest_departure` for onward legs, then `propose_hold_or_divert` for airborne case flights.
4. Mark each job DONE or FAILED (`error`).
5. Push the changes to the frontend over WebSocket or SSE.

The worker itself is **not implemented yet** (section 14).

---

## 12. Data loading and findings

| Source file | Target | Notes |
|---|---|---|
| OCC rotation 08:48 | `flight` + BASELINE events | Status column ignored |
| OCC rotation 16:45 | SNAPSHOT_DIFF events | 269 changes; PTD/PTA kept raw |
| Duty sheets 20–23 Nov | crew, qualifications, duties, legs, assignments, standby | Sign-in time and LVP/ETOP/TRN parsed from the `crewName` text; sign-in date rolls back over midnight |
| Duty-sheet legs missing from the rotation | 30 flights created | Flagged `FLIGHT_FROM_DUTY_SHEET_ONLY` |
| Roster (10 days) | `roster_entry` | SHJ local → UTC |
| Crew_FDTL | rule_set v1 (APPROVED) + 216 rules | sha256 stored |
| Connecting pax | `pax_connection` | Direction normalised with `is_in_bound` and the two views merged (see below); connections outside 20–23 Nov skipped |
| Historical flights / fuel | `hist.*` | Builds `block_time_reference`, alternate history, median ground time |

**Connecting-passenger file layout.** Columns A–G hold the "actual" flight, H is `is_in_bound`, I is the passenger count and J–O hold the connecting flight. The meaning of the two flight blocks depends on `is_in_bound`:

| `is_in_bound` | Rows | A–G is | J–O is |
|---|---|---|---|
| TRUE | 5,331 | the flight arriving at the connection station | the onward flight departing from it |
| FALSE | 5,090 | the flight departing from the connection station | the feeder flight arriving there |

The loader treats the file as follows:

- **Normalising direction.** Every row is turned into (inbound → outbound).
- **Merging views.** Most connections appear in both views (4,565 of 5,856 unique connections), so the two views are merged rather than added. Both counts are kept, and `pax_count` is the higher of the two.
- **Disagreements.** 7 connections have different counts in the two views and are logged as `PAX_VIEWS_DISAGREE` (INFO).
- **Checks.** The inbound flight's arrival station must equal the outbound flight's departure station (0 failures). Scheduled connection times range from 40 to 1,495 minutes; the 40-minute minimum is used as the minimum connection time in `v_connection_risk`.
- **Result.** 5,856 unique connections in the file, of which 5,061 (31,548 pax) fall inside the 20–23 Nov rotation. Nearly all connect at SHJ (5,044 connections, 31,454 pax); a few connect at MCT, BAH, CAI and other stations.
- **Verified against a source sample.** G9288 IST→SHJ on 20 Nov has 9 onward connections totalling 44 pax, the same in both views.

**Findings:**

- **The sheet agrees with the rules for UAE starts.** With SHJ-local bands, the duty sheet's `maxFdp` matches the rule set for 98% of crew starting at SHJ/RKT (2,544 of 2,595).
- **Outstation starts mostly disagree** (82 of 545 match), probably because the sheet uses acclimatisation or station local time. Each one is a WARN exception.
- **LVP coverage on 21 Nov:** 122 of 135 captain rows and 69 of 118 first officer rows hold LVP.
- **Aircraft swaps:** 4 flights have a different registration in the duty sheet than in the rotation, so crew are never linked by registration.

**Exception codes in use:**

- `SHEET_MAXFDP_MISMATCH`;
- `PAX_VIEWS_DISAGREE`;
- `DUTY_SHEET_TIME_DIFFERS`;
- `NO_FDP_RULE`;
- `NO_CREW_ASSIGNED`;
- `NO_CREW_PAIRING`;
- `FLIGHT_FROM_DUTY_SHEET_ONLY`;
- `REG_MISMATCH_DUTY_VS_ROTATION`;
- `LEG_NOT_IN_ROTATION`;
- `STATUS_COLUMN_UNRELIABLE`;
- `STANDBY_TIME_BASIS_ASSUMED`;
- `MIN_REST_NOT_SUPPLIED`.

### Alternate reference data (SHJ)

| Alternate | Diversions in 2026 | Median ground time (min) | Return block P90 (min) | Road positioning (min, assumed) |
|---|---|---|---|---|
| FJR | 33 | 139 | 61 | 90 |
| RKT | 18 | 180 | 52 | 60 |
| MCT | 15 | 59 | 68 | — (deadhead) |
| AAN | 9 | 77 | 59 | 120 |
| DWC | 2 | 158 | 50 | 60 |
| AUH | 2 | 97 | 80 | 120 |

---

## 13. Demo replay (what the judges see)

`05_demo_fog_replay.sql` runs on real 21 Nov flights. Fog, fuel and capacities are simulated.

1. A REPLAY scenario is cloned from LIVE at 01:15Z. Five inbound flights are watched: G9588, G9464, G9455, G9621 and G9472.
2. The feed includes a duplicate message (rejected) and a late, out-of-order message (ignored).
3. SHJ goes RESTRICTED, then CLOSED, with LVP in force and reopening forecast for 02:30Z. RKT, FJR and AAN are reported open. AAN has no fuel available.
4. The engine generates recommendations:

| Flight | Recommendation | Why |
|---|---|---|
| G9588 | DIVERT RKT | fuel ~25 min; crew needs discretion |
| G9464 | DIVERT RKT | fuel runs out before reopening |
| G9455 | DIVERT | captain not LVP-qualified |
| G9621 | HOLD | |
| G9472 | HOLD | |

5. The agent user tries to record a decision and is blocked. Dispatch then decides, OCC approves, and both diversions are executed. The extra sector cuts the captain's FDP from 11:15 to 10:30.
6. **Judge change 1:** G9472's ETA moves to 02:55Z, which queues a reassessment.
7. **Judge change 2:** SHJ reopening moves to 02:45Z. The engine re-ranks:
   - G9472 switches from HOLD to DIVERT FJR (fuel spare 10 min, below the 15-min buffer);
   - G9455 switches from RKT to FJR (RKT stands filling up);
   - G9621 keeps holding.
8. **Judge change 3:** G9588's crew time out at RKT. Six standby crew are found; non-LVP pilots are excluded. The swap moves the latest legal departure to 14:28Z.
9. The Q1–Q3 views answer at 02:30Z. Q1 shows the G9464 cockpit crew run out next (legal end 03:30Z). Q2 shows A6-ARJ on ground at RKT, waiting for REPLACEMENT_CREW. Q3 shows G9464 must leave RKT by 02:38Z (8 min left) and G9588 by 14:28Z.
10. SHJ opens at 02:45Z with LVP in force and 12 arrivals/h. Three arrivals fit the first hour. G9455 (LVP) and G9464D (crew) are flagged infeasible, with reasons.
11. The timeline (scenario clock) and report are generated. Edits to the approved rules are blocked.

---

## 14. Known limitations and next steps

| Area | Status | Suggested next step |
|---|---|---|
| Reassessment worker | Not implemented (the queue and NOTIFY exist) | Small Python/Node service using the contract in section 11 |
| API / auth | `set_actor` trusts the caller | API must authenticate and map identity → `app_user`; consider row-level security per role/station |
| Aircraft position | Distances measured from the hub | Add lat/lon/time to the feed payload and use them in `rank_alternates` |
| Alternate weights | Constants in `rank_alternates` | Move to a config table or `rule_set.parameters` |
| Recovery capacity | Fixed interval; arrivals only | Add departure slots and per-runway rates |
| FTL coverage | Single-duty FDP only | Cumulative limits (7/28 days), rest, split duty and acclimatisation need rules from the organizers |
| Replacement crew | Positioning by road only; positioning time is inside the new FDP (sign-in = call-out time) | Model deadhead positioning flights |
| LVP timing | Evaluated against the destination's *current* status | Use the forecast LVP state at the ETA |
| LLM agent | The engine is deterministic | An LLM may explain or propose via `INSERT recommendation`; it must never insert decisions |

## 15. Changelog (enhancement history)

| # | Change | Why |
|---|---|---|
| 1 | Initial schema, loader, views, guardrails, audit, demo | Brief requirements |
| 2 | Fixed the FDP band lookup (23:59 + 1 min wrapped to 00:00, so the 22:00–23:59 band never matched); legs missing from the rotation are created from the duty sheets | Correct sector counts and rule matches |
| 3 | Crew legs and assignments became scenario-scoped; `clone_scenario` copies them | Replays/what-ifs leaked into LIVE |
| 4 | Scenario clock stamping (`scenario_stamp`, `stamp_*` triggers, `audit_log.scenario_time_utc`); clone without audit flood | The timeline mixed wall and simulated time |
| 5 | Fuel endurance measured from the estimate time; whereabouts uses the latest flight; live `departure_legality`; recovery rank = landing order | Correctness of Q2/Q3 and the recovery plan |
| 6 | **Organizer confirmations:** FDP bands on SHJ local (`FIXED_TZ` Asia/Dubai); roster SHJ local for all crew; `sheet_mismatch_policy = WARN` | VERIFICATION_REQUIRED duties fell from 163 to 82 |
| 7 | **LVP enforcement:** `airport_status_event.lvp_in_force`, `crew_type.requires_lvp`, `lvp_in_force()`, `flight_lvp_check()`; applied in the flight watch, standby candidates, the recovery plan and the crew ranking | Organizer rule: LVP required for fog landings |
| 8 | **Alternate engine:** `flight_decision_inputs()`, `rank_alternates()`, `propose_hold_or_divert()`, `v_recommendation_options`, `alternate_airport.hist_median_ground_min`; the demo now uses engine-generated recommendations | Recommendations were hand-written before |
| 9 | **Hold policy:** a feasible hold with ≥ 15 min fuel spare beats a diversion; below the buffer it ranks after executable diversions | Hold and divert were scored on the same scale |
| 11 | `execute_diversion` reuses an existing recovery flight, so the replay can run repeatedly on the same database. Added `06_proposed_extensions.sql` and `07_proposed_triggers.sql`, validated by applying them to a fresh build and running the full replay twice with 0 errors. See `FogOps_Developer_Guide.md` | Team discussion: subscriptions, Teams/email alerts, per-flight discussion, data requests, custom rules, multi-role approvals, deep links, aeroMart trigger |
| 12 | **Time-base rules TB-1 to TB-5** (decision moment by flight phase; diversion maths anchored to it; `duty_started`; `TIME_BASE_INCONSISTENT` check) and **`downstream_impact()`** (aircraft knock-on, crew next duty and rest, connections). The loader now links duty-sheet legs with a revised time to the real rotation flight (`DUTY_SHEET_TIME_DIFFERS`, INFO) instead of creating duplicates: 26 duplicates removed, 4 genuinely missing legs still created | A team screen showed G9822 (departing 21 Nov 01:20Z) evaluated at 20 Nov 17:11Z: crew margin 963 min and "18 h 09 left". The replay outputs are unchanged |
| 10 | **Connecting-pax fix:** the loader now uses `is_in_bound` to orient each row, merges the two views of each connection, and validates the connection station. `pax_connection` gained `connection_iata`, both view counts, `source_view` and `sched_connection_min`. Added `v_connection_risk` | FALSE rows had been stored reversed (5,059 pairs) and every connection was stored twice, doubling the total (60,147 → 31,548 pax). Connecting-pax counts for *arriving* flights, as used by the recovery plan, were already right |

### When you extend the system

1. Put new logic in `02_functions_triggers.sql` **above** the final search_path-pinning `DO` block. If you append it below, re-run that block.
2. Add an audit trigger (`trg_audit('<pk>')`) to any new user-facing table. If the table is written during replays, add a stamp trigger too.
3. Add the new step to `05_demo_fog_replay.sql`, regenerate `05_demo_expected_output.txt`, and keep zero `ERROR`/`UNEXPECTED` lines.
4. Update sections 7–11 and this changelog.

## 16. Open questions for the organizers

1. **What are the FDP limits for SO, SEC and EN crew?** They are not in `Crew_FDTL.xlsx`. SO currently makes 81 duties VERIFICATION_REQUIRED.
2. **Does SO need LVP?** Currently only CP and FO do.
3. **What timezone are the "Standby Details" times in?** Assumed UTC on the sheet date.
4. **What is the minimum rest after duty?** Assumed 12 h, used only for roster-conflict checks.
5. **What do the 0-leg FDP rows mean, and what are PTD/PTA in the 16:45 snapshot?**
6. **Are the duty-sheet `maxFdp` values for outstation starts reference cases?** If yes, an acclimatisation table is missing.
