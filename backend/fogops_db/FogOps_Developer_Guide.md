# FogOps: Developer Guide

**How to build the FogOps disruption app on the existing database**

| | |
|---|---|
| Audience | Frontend, backend, data and AI engineers, and coding agents |
| Read with | `FogOps_Product_and_Operations_Guide.md` (what and why), `fogops_db/README.md` (database reference: tables, functions, invariants), `fogops_app_mockup_v2.html` (clickable UI reference with every MVP feature; v1 `fogops_console_mockup.html` kept for history) |
| Status labels | **Built** = in the repository and tested. **Validated** = proposed SQL in this guide, run end to end on PostgreSQL 16 with the replay data inside a rolled-back transaction. **Spec** = described here, not yet written. |

---

## 0. TL;DR for engineers and agents

1. **The database is the brain.** Legality, latest departure, LVP, the alternate ranking, the recovery plan, the audit trail and the guardrails already live in PostgreSQL (`fogops` schema). The API is thin: it authenticates, calls `set_actor()`, calls functions or views, and pushes events.
2. **Humans decide.** The AI and the rules engine only write `recommendation` rows. Decisions require human roles; the database refuses anything else.
3. **The UI layout rule from the team discussion:** in the flight panel, the **decision and approval area sits above** the AI recommendations.
4. **The MVP is lightweight:** board + KPI bar + filters → flight panel → recommendation → propose / approve / execute → per-flight timeline, discussion and subscriptions → deep links. Teams, aeroMart writes and live feeds come after.
5. **New database objects for the MVP** are in Appendix A (tables and views) and Appendix B (triggers). Both are **validated**. They also ship as `fogops_db/sql/06_proposed_extensions.sql` and `07_proposed_triggers.sql`.

---

## 1. What exists today

| Asset | Contents | Status |
|---|---|---|
| `fogops_db/sql/01–04` | Schema (43 tables incl. history), 12 views, 29 callable functions plus triggers; seed roles and users | Built |
| `fogops_db/loader/load_data.py` | Loads all organizer files: rotation snapshots → feed events; duty sheets; roster; FDTL; connecting pax (direction-normalised); history | Built |
| `fogops_db/sql/05_demo_fog_replay.sql` | The final-challenge replay; doubles as the end-to-end test and the reference for API calls | Built (0 errors) |
| `fogops_db/README.md` | Full database reference, algorithms, workflows, changelog | Built |
| `fogops_app_mockup_v2.html` | Clickable UI covering the discussion features: KPI bar, filters, severity, decision-first panel, multi-role approvals, "?" data requests, watch/notifications, per-flight discussion, deep links, rules & filters, integrations outbox, plus the Crew, Station, Recovery, Ask and what-if views. The "Data sources" overlay maps each component to the database | Built (UI reference) |
| Appendix A/B of this guide | Subscriptions, notifications, per-flight discussion, data requests, custom rules, approval policy, external systems, integration outbox, KPI and severity views, triggers | Validated |

---

## 2. Architecture

```
                     ┌──────────────── Browser (SPA) ─────────────────┐
                     │ Board · Flight panel · Approvals · Crew · Station│
                     │ Recovery · Rules/Filters · Ask · Report          │
                     └───────────────┬─────────────────▲───────────────┘
                              HTTPS REST                │ WebSocket (events)
                     ┌───────────────▼─────────────────┴───────────────┐
                     │ API service                                      │
                     │  auth (Entra ID) → app_user → set_actor()        │
                     │  REST → SQL functions / views (no business logic)│
                     │  WS hub ← LISTEN fogops_reassess / fogops_notify │
                     └───────────────┬─────────────────────────────────┘
                                     │ SQL
┌────────────────────────────────────▼──────────────────────────────────────────┐
│ PostgreSQL 14+ (schema fogops + hist)                                         │
│ events → state → calculations → recommendations → decisions → operations      │
│ audit_log · reassessment_queue · notification_outbox · integration_outbox     │
└───▲───────────────▲────────────────────▲────────────────────▲─────────────────┘
    │               │                    │                    │
┌───┴──────────┐ ┌──┴──────────────┐ ┌───┴──────────────┐ ┌───┴─────────────────┐
│ Feed adapter │ │ Reassessment    │ │ Notification     │ │ Integration worker  │
│ (snapshots → │ │ worker          │ │ worker           │ │ outbox → aeroMart / │
│ events; live │ │ recompute +     │ │ outbox → Teams / │ │ aeroOps APIs; retry;│
│ feed later)  │ │ propose_hold_or_│ │ email; retry     │ │ MANUAL fallback     │
│              │ │ divert()        │ │                  │ │                     │
└──────────────┘ └──┬──────────────┘ └──────────────────┘ └─────────────────────┘
                    │ optional
              ┌─────▼─────────────┐
              │ AI service (LLM)  │  explains, briefs, answers; never decides
              └───────────────────┘
```

| Component | Responsibility | Must not |
|---|---|---|
| SPA | Render views, collect input, show previews, subscribe to events | Compute legality or rankings itself |
| API | Auth, role mapping, `set_actor`, call database objects, map database errors to HTTP | Hold business rules duplicated from the database |
| Reassessment worker | Process `reassessment_queue`; recompute; regenerate recommendations; emit WebSocket events | Create decisions |
| Notification worker | Send `notification_outbox` rows (in-app, Teams, email) | Change operational state |
| Integration worker | Send `integration_outbox` rows to aeroMart / aeroOps; record the response | Retry forever; after N failures mark MANUAL |
| AI service | Rationale text, briefing, Ask answers, message drafts from database facts | Invent numbers; write decisions |

---

## 3. Suggested stack and layout

These are suggestions. The database contract matters more than the framework.

| Layer | Suggestion | Why |
|---|---|---|
| Frontend | React + TypeScript, TanStack Query, a WebSocket client; design tokens from the mockup | Real-time board; typed contracts |
| API | Python FastAPI + psycopg 3 (or Node/NestJS) | The team's Python skills; async LISTEN support |
| Workers | Python processes (same codebase as the API) | Shared database access layer |
| Auth | Microsoft Entra ID (SSO) → `app_user.username` | Microsoft estate; Teams later |
| Database | PostgreSQL 16 (Azure Database for PostgreSQL in production) | Already built and tested |
| Packaging | Docker Compose: `db`, `api`, `worker-reassess`, `worker-notify`, `worker-integration`, `web` | One-command environment |

```
repo/
  db/            ← fogops_db (sql/01..07, loader, rebuild.sh, README)
  api/           ← routes, db access, ws hub, error mapping
  workers/       ← reassess.py, notify.py, integrate.py, ai.py
  web/           ← SPA (use fogops_console_mockup.html as the visual spec)
  docs/          ← this guide + product guide
```

---

## 4. Data layer

### 4.1 Non-negotiable rules (enforced by the database; full list in `fogops_db/README.md` §3)

- **Set the actor.** Start every write transaction with `SELECT fogops.set_actor(:user_id)`.
- **Flight changes go through the feed function.** Change flights only via `ingest_flight_event()`; never `UPDATE flight_state`.
- **Decision lifecycle.** Decisions start as `PROPOSED` and change state only through `decision_approval` and the defined transitions. Their content is immutable, and only human roles can decide or approve.
- **Rules are frozen once approved.** Approved `rule_set`/`fdp_rule` rows are immutable; a change means a new version.
- **Append-only tables.** `audit_log`, `airport_status_event`, `decision_approval` and `case_comment` are append-only.
- **Missing data is never "legal".** Missing or conflicting data gives `VERIFICATION_REQUIRED` or a blocking `verify` constraint.
- **Always filter by scenario.** Everything is scenario-scoped; LIVE is `scenario_id = 1`.
- **Time.** Store UTC `TIMESTAMPTZ`; derive local time with `airport.tz`. FDP bands use SHJ local time (confirmed).

### 4.2 Features and the database objects behind them

| Feature | Read | Write / function |
|---|---|---|
| KPI bar | `v_disruption_kpis` (A) | — |
| Board rows | `v_flight_watch` + `v_flight_severity` (A) | — |
| Flight panel: decision area | `v_decision_log`, `decision_approval`, `approval_policy` (A) | `INSERT decision`, `INSERT decision_approval`, `execute_diversion()`, `swap_crew()` |
| Flight panel: options | `v_recommendation_options`, `rank_alternates()` | `propose_hold_or_divert()` |
| Crew | `v_crew_legality_ranking`, `fdp_calculation.inputs` | `compute_flight_legality()`, `standby_candidates()` |
| Deadlines and "Why?" | `latest_departure_calc`, `fdp_calculation.inputs` | `compute_latest_departure()` |
| "?" data requests | `data_request` (A), `v_open_exceptions` | `INSERT data_request`, then `INSERT flight_fuel_estimate` / `airport_status_event` |
| Per-flight timeline | `v_case_timeline` filtered by flight | — |
| Per-flight discussion | `case_comment` (+ `kind`, A) | `INSERT case_comment` |
| Subscriptions | `flight_subscription` (A) | insert/update |
| Notifications | `notification_outbox` (A) | triggers (B) + worker |
| Deep links | `deep_link(system, flight, scenario)` (A) | — |
| aeroMart write | `integration_outbox` (A) | trigger on EXECUTED DIVERT (B) + worker |
| Station view | `v_aircraft_whereabouts`, `diversion` | `UPDATE diversion`, `ingest_flight_event()` |
| Recovery | `v_recovery_plan_current` | `build_recovery_plan()` |
| Connections | `v_connection_risk` | — |
| Rules and filters | `ops_rule` (A) | API evaluates the DSL (§9) |
| Report | `report` | `generate_report()` |
| What-if | any view with another `scenario_id` | `clone_scenario()` |

### 4.3 MVP additions (Appendix A and B, validated)

| ID | Object | Purpose |
|---|---|---|
| E1 | `flight_subscription` | Watch a flight (in-app / Teams / email), e.g. a medical emergency |
| E2 | `notification_outbox` | Durable queue of alerts for the notification worker |
| E3 | `case_comment.kind`, `external_ref` | Per-flight discussion types (question, answer, recommendation, data request) and the Teams message id |
| E4 | `data_request` | The "?" flow: ask crew or station for missing data, track until answered |
| E5 | `ops_rule` | Custom filter, alert, priority and constraint rules with a validity window and priority; constraint rules need approval |
| E6 | `approval_policy` | Which roles must approve each decision type ("approved by all relevant parties") |
| E7 | `external_system`, `integration_outbox`, `deep_link()` | Deep links with parameters; outbox for aeroMart and aeroOps writes |
| E8 | `v_flight_severity`, `v_disruption_kpis` | Severity 0–100 and the KPI bar |
| T1 | `trg_decision_approval` (replaces the existing one) | Multi-role approval; role must be in the policy; any rejection rejects |
| T2 | `notify_flight()`, `trg_flight_notify` | Fan out decision, comment, diversion and data-request events to subscribers (not to the author) and `NOTIFY fogops_notify` |
| T3 | `trg_integration_outbox` | An EXECUTED DIVERT queues `AEROMART / CREATE_DIVERSION_ENTRY` with idempotency key `DIVERT-<id>` |

**Validation runs**

There were two runs:

1. Inside a rolled-back transaction on the replay scenario; results in the table below.
2. Applying 06 and 07 to a fresh `rebuild.sh` database and running the full `05_demo_fog_replay.sql` twice: 0 errors, each run queuing its 2 aeroMart diversion entries.

| Check | Result |
|---|---|
| DIVERT policy = OCC + CREW_CONTROL | Stays `PROPOSED` after OCC, becomes `APPROVED` after Crew Control |
| Approval by a role outside the policy | Refused |
| Executing the diversion | Queued one aeroMart message |
| Subscribers (2 users + 1 Teams channel) | Received 9 notifications across PROPOSED, APPROVED, DIVERTING and EXECUTED; the acting user was skipped |
| KPI view on the replay | 5 flights watched, 2 diverted, 1 holding, 2 crew at risk, 1 LVP-blocked, 656 connecting pax |
| Severity ranking | G9464 66, G9472 36, G9455 36, G9621 18, G9588 10 |

**Migration steps**

1. Apply `06_proposed_extensions.sql`, then `07_proposed_triggers.sql`, after `04_seed_reference.sql`.
2. Re-run the `search_path` pinning block at the end of `02_functions_triggers.sql`, so the new functions are pinned too.
3. Add `06` and `07` to `rebuild.sh`.
4. Extend `05_demo_fog_replay.sql` with subscription, notification and outbox assertions.

### 4.4 Time-base rules (TB-1 to TB-5)

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

### 4.5 Downstream impact (aircraft rotation, crew next duty, connections)

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

### 4.6 Data caveats engineers must handle

| Caveat | How to handle it |
|---|---|
| Passengers on board | Only 60 of 887 flights have a passenger count. Show connecting passengers (reliable) and mark on-board passengers as "not available" until aeroMart bookings are integrated |
| Fuel, weather, alternate status | Entered by people or estimated; always display `quality` |
| Second Officer (SO) | Not in the FDTL file, so their duties are `VERIFICATION_REQUIRED` (81 duties). Display it; never hide it |
| Standby times | The timezone is assumed UTC |
| Replay clock | Use `scenario_now()` and `scenario_stamp()`; never `now()` in queries for replay views |

---

## 5. API specification

### 5.1 Conventions

| Topic | Rule |
|---|---|
| Format | JSON; timestamps ISO-8601 UTC (`2026-11-21T02:38:00Z`); the client renders SHJ local time |
| Scenario | Header `X-Scenario-Id` (default `1` = LIVE) |
| Auth | Bearer token (Entra ID) → `app_user` by username → role |
| Transactions | Every write runs `BEGIN; SELECT fogops.set_actor(:uid); …; COMMIT;` |
| Errors | `403` = guardrail (role, human-only, not an approver); `409` = state conflict (already approved, immutable, illegal transition); `422` = validation (missing reason, unknown option); `404` = not found. Pass the database message as `detail` |
| Idempotency | `Idempotency-Key` header on POSTs that execute actions |
| Pagination | `?limit=&cursor=` on list endpoints |

### 5.2 Endpoints

| Area | Method and path | Roles | Database call | Notes |
|---|---|---|---|---|
| Session | `GET /me` | all | `app_user` | role, station, permissions |
| KPIs | `GET /cases/{id}/kpis` | all | `v_disruption_kpis` | the KPI bar |
| Board | `GET /cases/{id}/flights?status=&lvp_blocked=&severity_min=&rule_id=&subscribed=` | all | `v_flight_watch` ⨝ `v_flight_severity` | lanes and sort client-side, or `?sort=deadline` |
| Flight | `GET /flights/{id}` | all | `v_flight_watch` + crew + whereabouts | panel header and facts |
| Why | `GET /flights/{id}/explain` | all | `fdp_calculation.inputs`, `latest_departure_calc.assumptions` | the "Why this time?" chain |
| Options | `GET /flights/{id}/recommendation` | all | `v_recommendation_options` | ranked options with constraints |
| Re-rank | `POST /flights/{id}/recommendation:refresh` | OCC, DISPATCH, system | `propose_hold_or_divert()` | returns the new `rec_id` |
| Alternates (live) | `GET /flights/{id}/alternates` | all | `rank_alternates()` | read-only, no write |
| Decide | `POST /decisions` | human roles | `INSERT decision` | body: `flight_id, decision_type, option_id?, alternate_iata?, rationale, followed_recommendation, override_reason?` |
| Preview | `POST /decisions:preview` | human roles | spec: `preview_decision()` | consequence list, no writes (§7.4) |
| Approve | `POST /decisions/{id}/approvals` | approver roles | `INSERT decision_approval` | `verdict, comment` |
| Execute | `POST /decisions/{id}:execute` | OCC (or per policy) | `execute_diversion()` / `swap_crew()` / status update | idempotent |
| Revoke | `POST /decisions/{id}:revoke` | OCC | `UPDATE decision` (REVOKED + reason) | |
| Approvals queue | `GET /approvals?mine=true` | approvers | `decision` (PROPOSED) ⨝ `approval_policy` | |
| Hub status | `POST /airports/{iata}/status` | OCC, STATION (own) | `INSERT airport_status_event` | LVP, capacity, reopening |
| Fuel | `POST /flights/{id}/fuel` | DISPATCH | `INSERT flight_fuel_estimate` | quality required |
| Data request | `POST /flights/{id}/data-requests` · `POST /data-requests/{id}:answer` | all · target role | `data_request` + apply the value | the "?" flow |
| Crew | `GET /crew/legality?scenario=` | all | `v_crew_legality_ranking` | Q1 |
| Replacement | `GET /duties/{id}/standby?position=&station=&from_leg=` | CREW_CONTROL | `standby_candidates()` | Q4 |
| Station | `GET /stations/{iata}/aircraft` · `PATCH /diversions/{id}` | STATION | `v_aircraft_whereabouts`, `UPDATE diversion` | |
| Recovery | `POST /cases/{id}/recovery-plans` · `GET /recovery-plans/{id}` | OCC, RECOVERY | `build_recovery_plan()`, `v_recovery_plan_current` | |
| Connections | `GET /flights/{id}/connections` | all | `v_connection_risk` | |
| Downstream | `GET /flights/{id}/downstream?ready_at=` | all | `downstream_impact()` | aircraft knock-on + crew next duty; `ready_at` = what-if return time |
| Timeline | `GET /flights/{id}/timeline` · `GET /cases/{id}/timeline?since=` | all | `v_case_timeline` | `since` = briefing |
| Discussion | `GET/POST /flights/{id}/comments` | all | `case_comment` | `kind` |
| Subscribe | `POST/DELETE /flights/{id}/subscriptions` | all | `flight_subscription` | channel, target |
| Notifications | `GET /me/notifications` · `POST /notifications/{id}:read` | all | `notification_outbox` (IN_APP) | |
| Deep link | `GET /flights/{id}/links` | all | `deep_link()` per enabled system | buttons in the panel header |
| Rules | `GET/POST /rules` · `POST /rules/{id}:approve` | managers | `ops_rule` | §9 |
| Scenarios | `POST /scenarios` (clone) · `PATCH /scenarios/{id}` (clock) | OCC, ADMIN | `clone_scenario()` | |
| Report | `POST /cases/{id}/reports` | OCC | `generate_report()` | JSON → PDF in the API |
| Ask | `POST /ask` | all | AI service over whitelisted views | §8 |

### 5.3 Examples

```http
POST /decisions
X-Scenario-Id: 2
{ "flight_id": 412, "decision_type": "DIVERT", "option_id": 88, "alternate_iata": "FJR",
  "followed_recommendation": true,
  "rationale": "Captain not LVP-qualified; FJR has stands and fuel." }
→ 201 { "decision_id": 34, "status": "PROPOSED",
        "required_approvals": ["OCC","CREW_CONTROL"], "approved_by": [] }

POST /decisions/34/approvals          (as OCC)
{ "verdict": "APPROVED", "comment": "Go." }
→ 201 { "decision_id": 34, "status": "PROPOSED", "approved_by": ["OCC"], "waiting_for": ["CREW_CONTROL"] }

POST /decisions/34/approvals          (as station user)
→ 403 { "detail": "Guardrail: user 8 (STATION) is not authorised to approve decisions" }
```

---

## 6. Real-time and workers

### 6.1 Channels and WebSocket events

| Database channel | Raised by | Worker |
|---|---|---|
| `fogops_reassess` | flight changes, airport status, crew changes, decision status (existing triggers) | Reassessment |
| `fogops_notify` | `notify_flight()` (T2) | Notification |

| WebSocket event (server → client) | Payload | UI reaction |
|---|---|---|
| `flight.updated` | `{flight_id, fields[]}` | refresh the row and the panel if open |
| `recommendation.changed` | `{flight_id, rec_id, from, to, reason}` | pulse the row; show the "changed" note |
| `decision.updated` | `{decision_id, flight_id, status, waiting_for[]}` | update the decision area and the approvals badge |
| `kpis.updated` | `{case_id}` | refresh the KPI bar |
| `notification.new` | `{notification_id, title, severity}` | toast and inbox |
| `airport.updated` | `{iata, op_status, lvp_in_force, expected_reopen_utc}` | refresh the situation strip |

### 6.2 Reassessment worker

```python
LISTEN fogops_reassess
loop:
  jobs = claim("UPDATE reassessment_queue SET status='RUNNING', picked_at=now()
                WHERE job_id IN (SELECT job_id FROM reassessment_queue WHERE status='PENDING'
                                 ORDER BY enqueued_at FOR UPDATE SKIP LOCKED LIMIT 50)
                RETURNING *")
  for scenario, group in coalesce_by_scenario(jobs):          # debounce bursts (~2 s)
      flights = affected_flights(group)                       # flight / airport→case flights / duty→legs
      with tx(actor=SYSTEM_AGENT_USER):
          for f in flights:
              compute_flight_legality(scn, f, reason)
              for onward in onward_legs(f): compute_latest_departure(scn, onward)
              if status(f) in ('AIRBORNE','HOLDING'): propose_hold_or_divert(scn, case, f)
      emit(flight.updated / recommendation.changed / kpis.updated)
      mark DONE (or FAILED with error, retry ×3)
```

Use the seeded `agent` user (role `AGENT`) as the actor for engine writes. The database blocks that role from deciding.

### 6.3 Notification worker

- Claim `notification_outbox` rows with `status='PENDING'`, using `FOR UPDATE SKIP LOCKED`.
- **IN_APP:** nothing to send. Rows are read through `/me/notifications`; mark them `SENT` on delivery over WebSocket.
- **TEAMS:** post to a channel through an Incoming Webhook or Workflows URL, kept in a secret store and keyed by `target`. Include deep links to the app and to aeroOps. Store the message id in `case_comment.external_ref` when mirroring a discussion.
- **EMAIL:** Graph `sendMail` or SMTP.
- **Failures:** retry with backoff 30 s, 2 min and 10 min, then mark `FAILED` and show an exception in the app. Throttle per channel.
- **Who gets what** comes from `flight_subscription` plus `approval_policy.notify_roles`. For role-based fan-out, extend `notify_flight()` with an app setting that maps each role to a channel.

### 6.4 Integration worker (aeroMart / aeroOps)

- Process `integration_outbox` rows in `PENDING` state.
- Call the target API with `idempotency_key`.
- On success, store `response` and set `ACKED`.
- After 3 failures, set `MANUAL`. The panel then shows *"aeroMart entry not created automatically: open aeroMart"* with the deep link, and creates a `data_exception`.
- Integrations stay disabled until `external_system.enabled = true`. Until then, rows remain `PENDING` and the UI shows the deep link.

---

## 7. Frontend specification

### 7.1 Layout (from the team discussion; the mockup is the visual reference)

```
┌ Situation strip: scenario · SHJ status/LVP/reopening · alternates · clock · approvals · Ask ┐
├ KPI bar: flights affected · pax affected · severity(high) · decisions pending · next deadline│
│          · diverted/holding · crew at risk · needs verification                             │
├ Filters: status · severity · LVP-blocked · crew risk · verify · subscribed · saved rules ───┤
│ Board (lanes by deadline, sorted by deadline → severity) │ Flight panel                     │
│                                                          │ 1 Header + Subscribe + Open in…  │
│                                                          │ 2 DECISION AREA (top)            │
│                                                          │ 3 AI recommendations #1 #2 #3    │
│                                                          │ 4 Data gaps "?"                  │
│                                                          │ 5 Deadline + Why                 │
│                                                          │ 6 Crew duty bar + replacement    │
│                                                          │ 7 Fuel & alternates              │
│                                                          │ 8 Flight briefing (timeline)     │
│                                                          │ 9 Discussion                     │
└──────────────────────────────────────────────────────────┴──────────────────────────────────┘
```

> **Implemented in the v2 mockup.** The decision area (proposals, approval status per role, approve/reject/propose buttons) sits above the recommendations.

### 7.2 Components

| Component | Data | Behaviour |
|---|---|---|
| `KpiBar` | `/cases/{id}/kpis` | Each tile clickable → applies the matching filter |
| `FlightBoard` | `/cases/{id}/flights` | Lanes: Act now < 15 min, Decide soon 15–45, Monitoring > 45, Recovered. Unknown deadline → Decide soon. Keyboard J/K/Enter |
| `FlightRow` | row | Live status, fuel and crew bars, LVP badge, AI chip, countdown, severity dot |
| `FilterBar` | query params; `/rules` | Combinable; saved as `ops_rule(kind=FILTER)` |
| `DecisionArea` | `/flights/{id}` + decisions + `approval_policy` | Shows proposer, rationale, approvals per required role (✓/⏳/✕), actions by role |
| `RecommendationList` | `/flights/{id}/recommendation` | Ranked options; rationale; quality chips; blocked options with reasons; choosing #2/#3 requires an override reason |
| `ConsequencePreview` | `/decisions:preview` | Shown before propose, approve and execute |
| `DataGap` | missing fields, `data_request` | Shows **?**, "Ask crew/station", and "Enter value" (with quality) |
| `DeadlineCard` | `/flights/{id}/explain` | Countdown, UTC and SHJ local time, "Why?" chain |
| `DownstreamImpact` | `/flights/{id}/downstream` | Next legs of the same aircraft with projected delay and connecting pax; crew next duty and rest. Also shown inside the consequence preview |
| `CrewDutyBar` | crew legality | Sign-in → now → projected landing → legal end → discretion zone; legend, not overlapping labels. **If `duty_started=false`, show "Duty starts HH:MMZ" (TB-3)** |
| `AlternatesTable` | `/flights/{id}/alternates` | Status, stands, fuel margin, return block, crew outcome, blocking reasons |
| `FlightTimeline` | `/flights/{id}/timeline` | Per-flight briefing |
| `Discussion` | `/flights/{id}/comments` | Kinds; mentions; mirrored to Teams when enabled |
| `SubscribeButton` | `/flights/{id}/subscriptions` | In-app by default; Teams/email when enabled |
| `ExternalLinks` | `/flights/{id}/links` | "Open in aeroOps / crew system / aeroMart" with parameters |
| `ApprovalsDrawer`, `CrewView`, `StationView`, `RecoveryPlanner`, `AskPalette`, `WhatIf` | see the mockup | as in the mockup |

### 7.3 UX rules

- **Status cues:** never colour alone (colour + icon + word). Unknown values use grey, dashed lines and "?".
- **Times:** countdowns for deadlines; `02:38Z / 06:38 SHJ` for absolute times; tabular numerals.
- **Replay and what-if:** magenta frame and banner.
- **Accessibility:** dark theme by default plus a light theme; keyboard first; minimum 14–16 px text.
- **Stale data:** shown as faded with its age.
- **Optimistic UI:** never for decisions or approvals. Always wait for the database result.

### 7.4 Consequence preview (spec)

`preview_decision(draft)` returns, without persisting anything:

- the recovery flight to be created;
- the crew whose legs and legal end change (before → after);
- the alternate's stands before → after;
- connecting passengers affected (`v_connection_risk`);
- the integrations that will be queued;
- who must approve and who will be notified.

**Implementation option:** in the API, open a transaction, `SAVEPOINT p`, run the real function (e.g. `execute_diversion` on a temporary decision), read the deltas, then `ROLLBACK TO p`. Check that no external side effects escape. In particular, confirm that `NOTIFY` issued inside a rolled-back savepoint is discarded, and add a test for it.

---

## 8. AI layer

| Task | Input (facts only) | Output | Guardrails |
|---|---|---|---|
| Recommendation rationale | Rank-1..3 rows from `v_recommendation_options` and `rank_alternates()` | ≤ 60 words per option, in plain language | Use only numbers present in the input; name the assumptions and their quality |
| Briefing ("since you last looked") | `v_case_timeline` since the user's last seen time + KPIs | 3–6 bullets | No advice beyond the recorded recommendations |
| Ask (Q&A) | Tool calls to whitelisted read-only endpoints (Q1–Q4, connections, whereabouts) | Answer + source view name | Read-only; refuse to decide |
| Message drafts | Decision + flight facts | Teams, station or ACARS text | A human sends it |
| Change explanation | Old vs new recommendation and their `input_snapshot` | "Hold → Divert FJR because …" | Must reference the changed input |

**Prompt contract (example)**

```
SYSTEM: You explain airline disruption options. Use ONLY the JSON facts. Never invent numbers,
limits or approvals. If a value is missing, say "not available". Humans decide.
INPUT: {"flight":"G9472","options":[{"rank":1,"action":"DIVERT","alt":"FJR","fuel_margin_min":12,
        "crew_outcome":"NEEDS_COMMANDER_DISCRETION","stands_left":6,"assumptions":["fuel ESTIMATED",
        "reopening FORECAST"]}, ...]}
OUTPUT: {"rank":1,"rationale":"..."}
```

**Evaluation**

- Every number in the output appears in the input (automated check).
- The output contains no imperative instruction to crew or ATC.
- Assumptions are always mentioned when present.

---

## 9. Rules and filters DSL (`ops_rule.definition`)

```json
{ "all": [ { "field": "lvp_required", "op": "eq", "value": true },
           { "field": "lvp_crew_ok",  "op": "neq", "value": true } ] }
```

**Grammar.** Conditions combine with `all` and `any`, which can be nested. Each condition is `{field, op, value}`, with `op` one of `eq neq lt lte gt gte in is_null not_null`.

**Fields.** Only a whitelist is allowed:

- from `v_flight_watch`: `status`, `crew_status`, `crew_margin_min`, `lvp_required`, `lvp_crew_ok`, `diverted_to`, `fog_exposure`, `open_exceptions`, `minutes_to_latest_legal_departure`, `recommendation`, `decision_status`;
- from `v_flight_severity`: `severity_score`, `connecting_pax`.

**Evaluation.** The API compiles the rule to **parameterised** SQL from the whitelist. Never concatenate user text.

**Rule kinds**

| Kind | Example from the discussion | Effect | Approval |
|---|---|---|---|
| FILTER | "Flights where the pilots are not LVP-qualified" | Board filter | No |
| ALERT | "Alert when crew margin < 45 min tonight" | Notifications to subscribers/roles when the rule starts matching a flight | No |
| PRIORITY | "Medical emergency flights first" | Sort boost; recovery weight | OCC |
| CONSTRAINT | "No crew beyond 10 h FDP tonight" | Applied as an extra blocking constraint; **may only tighten** the approved FDP rules | Required |

**Lifecycle.** `DRAFT` → `ACTIVE` (within `valid_from`/`valid_to`) → `EXPIRED`, set by a scheduler. Approval is required for CONSTRAINT rules (database check).

---

## 10. Flow catalogue (engineering view)

| # | Flow | Trigger | Main database/API objects | Status |
|---|---|---|---|---|
| 1 | Initial load | deploy | `rebuild.sh`, loader | Built |
| 2 | Flight feed | message / snapshot | `ingest_flight_event` | Built (simulated feed) |
| 3 | Reassessment | queue/NOTIFY | worker §6.2 | Partial (worker = spec) |
| 4 | Data verification | exception / "?" | `data_exception`, `data_request` | Partial (A) |
| 5 | Early warning (pre-fog) | Met forecast entered | new view: fog-window arrivals × risk | Spec |
| 6 | Hub status change | OCC input | `airport_status_event` | Built |
| 7 | Hold/divert | airborne + hub restricted | `propose_hold_or_divert`, decisions | Built |
| 8 | Hold at origin | not departed + closure | `decision(DELAY)` + engine extension | Spec |
| 9 | Alternate station ops | diversion | `diversion`, station endpoints | Built |
| 10 | Crew legality watch (Q1) | any change | `v_crew_legality_ranking` | Built |
| 11 | Latest legal departure (Q3) | diversion/crew change | `compute_latest_departure` | Built |
| 12 | Crew replacement (Q4) | crew at risk | `standby_candidates`, `swap_crew` | Built |
| 13 | Commander discretion | crew > legal end | `decision(COMMANDER_DISCRETION)` | Partial |
| 14 | SHJ outbound crew erosion | departure delays | legality + alert rule | Partial |
| 15 | Aircraft rotation / swap | aircraft late or stuck at an alternate | `downstream_impact()` (knock-on); `decision(AIRCRAFT_SWAP)` | Partial (knock-on built; swap proposal = spec) |
| 16 | Connection protection | ETA change / diversion | `v_connection_risk` + aeroMart | Partial |
| 17 | Recovery sequencing | hub OPEN | `build_recovery_plan` | Built |
| 18 | Close and report | OCC | `generate_report` | Built |
| 19 | Decision lifecycle | user | `decision`, `decision_approval` (T1) | Built (+T1 validated) |
| 20 | AI override | user picks a non-top option | `followed_recommendation=false` + reason | Built |
| 21 | Ownership, comments, discussion | user | `case_flight`, `case_comment` (+E3) | Built / validated |
| 22 | Rule-set version | new FDTL | `rule_set`, `fdp_rule` | Built (no UI) |
| 23 | Replay | demo | `clone_scenario`, sim clock | Built |
| 24 | What-if comparison | user | clone + diff endpoint | Partial |
| 25 | Historical fog-day replay | demo | `hist.flight` | Partial (no crew history) |
| 26 | Alternate performance | load | `alternate_airport` | Built |
| 27 | Fuel estimate pre-fill | flight enters the watch | `hist.fuel` → `flight_fuel_estimate (ESTIMATED)` | Spec |
| 28 | Fog pattern analytics | batch | `hist.flight` | Spec |
| 29 | Crew fog readiness (LVP coverage) | daily | standby + qualifications | Spec |
| 30 | **Subscribe / notify** | user / event | E1, E2, T2, notification worker | Validated (database); worker = spec |
| 31 | **Deep link to aeroOps/crew/aeroMart** | user click | E7 `deep_link()` | Validated |
| 32 | **aeroMart entry on executed diversion** | decision EXECUTED | T3 + integration worker | Validated (database); worker = spec |
| 33 | **Custom rules and filters** | manager | E5 + DSL §9 | Validated (table); evaluator = spec |

---

## 11. Testing

| Level | What | How |
|---|---|---|
| Database end-to-end | Final-challenge replay | `psql -f 05_demo_fog_replay.sql`; 0 `ERROR`/`UNEXPECTED`; compare with `05_demo_expected_output.txt` |
| Guardrails | Human-only decisions, immutability, append-only, rule-set freeze, station cannot approve, policy roles | Scripted negative tests (see the README and the T1 validation) |
| New objects | Subscriptions, notifications, outbox, multi-approval | Port the validation in §4.3 into `08_tests.sql` |
| API | Contract tests per endpoint; error mapping (403/409/422) | pytest + a test database built by `rebuild.sh` |
| Rules DSL | Whitelist, injection attempts, tighten-only constraints | Unit tests |
| Workers | Idempotency, retry, MANUAL fallback, debounce | Integration tests with fake Teams/aeroMart servers |
| UI | Lanes, filters, decision-first layout, preview, keyboard, light/dark, mobile station view | Playwright (the mockup was verified this way) |
| Acceptance | The brief's 3-minute test (Q1–Q4 from the screen) and the final challenge | Scripted demo run |

---

## 12. Security, privacy and audit

- **Authentication:** Entra ID SSO, with an `app_user` mapping and role from directory groups. No shared accounts.
- **Authorisation:** the API checks roles, and the database re-checks (defence in depth). Consider row-level security for `STATION` users so they see only their airport's diversions.
- **Audit:** `audit_log` is append-only; reports carry an `audit_watermark_id`. Never delete operational rows; use status changes instead.
- **Secrets:** Teams webhooks and integration credentials live in a vault; nothing secret goes in `external_system`.
- **Personal data:** the supplied crew names and phone numbers are synthetic. In production, minimise crew personal data in notifications (use crew ID and role) and restrict phone numbers to Crew Control.
- **AI:** send the LLM only operational facts, no personal data; log prompts and outputs with the `rec_id`.

---

## 13. Environments and deployment

```bash
# local
docker compose up db
export PGHOST=127.0.0.1 PGUSER=postgres
./db/rebuild.sh ./data fogops                       # schema + seed + loader (~1 min)
psql -d fogops -f db/sql/06_proposed_extensions.sql
psql -d fogops -f db/sql/07_proposed_triggers.sql   # then re-run search_path pin block
psql -d fogops -f db/sql/05_demo_fog_replay.sql     # e2e check
docker compose up api worker-reassess worker-notify worker-integration web
```

| Variable | Purpose |
|---|---|
| `FOGOPS_DSN` | database connection |
| `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID` | SSO |
| `TEAMS_WEBHOOK_<TARGET>` | Teams channels |
| `AEROMART_API_URL`, `AEROMART_TOKEN` | integration (disabled by default) |
| `LLM_ENDPOINT`, `LLM_MODEL` | AI service |
| `FEATURE_TEAMS`, `FEATURE_AEROMART_WRITE`, `FEATURE_AI_ASK` | feature flags |

---

## 14. MVP backlog

### P0: MVP (agreed scope: lightweight, core loop first)

| # | Story | Acceptance criteria |
|---|---|---|
| 1 | **KPI bar** | Shows flights affected, passengers (connecting, with "on-board n/a"), high-severity count, decisions pending, next deadline, diverted/holding, crew at risk, needs verification; tiles filter the board |
| 2 | **Board with severity and deadline** | Lanes by deadline; sort deadline → severity; live status per row; updates within 5 s of a database change |
| 3 | **Filters** | Status, severity ≥ N, LVP-blocked, crew risk, verify, subscribed; combinable; the URL reflects the filter |
| 4 | **Flight panel, decision area first** | Proposals and approval status per required role above the recommendations; role-based buttons |
| 5 | **AI recommendations with rationale** | #1–#3 with plain-language reasons, quality chips and blocked reasons; override requires a reason |
| 6 | **"?" data requests** | Missing fuel or alternate status shows "?"; Ask/Enter; the answer is stored with quality; options re-rank |
| 7 | **Multi-role approvals (T1)** | Policy-driven required roles; approvals queue; consequence preview before approve and execute |
| 8 | **Per-flight briefing and discussion (E3)** | Timeline filtered to the flight; comments with kinds; visible to all roles |
| 9 | **Subscribe to a flight (E1, E2, T2)** | In-app notifications on decision, comment, diversion and data-request events; the author is not notified |
| 10 | **Deep links (E7)** | "Open in aeroOps / crew system / aeroMart" with the flight pre-selected (templates configurable) |
| 11 | **Crew, Station, Recovery views** | As in the mockup, backed by the existing views and functions |
| 12 | **Reassessment worker** | ETA, airport and crew changes recompute and re-recommend within 10 s; the change is announced in the row |

### P1: next

| # | Story |
|---|---|
| 13 | Teams channel notifications and discussion mirroring |
| 14 | Custom ALERT and PRIORITY rules; saved filters shared across users |
| 15 | What-if side-by-side comparison |
| 16 | Connection-protection actions (export to aeroMart / Customer Service list) |
| 17 | Fuel estimate pre-fill from history (ESTIMATED) |
| 18 | Report PDF export and a handover summary (AI) |

### P2: future

| # | Story |
|---|---|
| 19 | aeroMart entry on executed diversion (integration worker) |
| 20 | CONSTRAINT rules with approval |
| 21 | Aircraft swap/rotation recovery; hold-at-origin proposals; early warning |
| 22 | Live feeds (movements, fuel/ACARS, Met) |
| 23 | Email notifications; escalation timers for unapproved decisions |

---

## 15. Open questions (engineering)

1. **Approval flow:** the client's recorded answer is needed to seed `approval_policy`; the current seed is a proposal.
2. **System names and APIs:** exact deep-link URL formats and parameters for aeroOps, the crew system and aeroMart; is there a write API for diversion entries?
3. **Teams:** webhook vs Graph; tenant policy; channel per case or one fixed channel.
4. **Identity:** directory groups → `app_role` mapping; which users get portal access vs notifications only.
5. **Preview implementation:** savepoint approach vs a dedicated read-only function (test `NOTIFY` behaviour).
6. **Severity weights and lane thresholds:** confirm with OCC.

---

## Appendix A: `06_proposed_extensions.sql` (validated)

```sql
SET search_path = fogops, public;

-- E1. Watch / subscribe to a flight
CREATE TABLE flight_subscription (
    subscription_id  BIGSERIAL PRIMARY KEY,
    scenario_id      INT NOT NULL REFERENCES scenario,
    flight_id        BIGINT NOT NULL REFERENCES flight,
    user_id          INT REFERENCES app_user,          -- NULL when the target is a channel/address
    channel          TEXT NOT NULL CHECK (channel IN ('IN_APP','TEAMS','EMAIL')),
    target           TEXT,                              -- Teams channel id / email when not a user
    reason           TEXT,                              -- MEDICAL, VIP, HIGH_IMPACT, OWNER ...
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_by       INT REFERENCES app_user,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (user_id IS NOT NULL OR target IS NOT NULL)
);
CREATE UNIQUE INDEX ux_subscription ON flight_subscription
    (scenario_id, flight_id, coalesce(user_id, 0), channel, coalesce(target, '')) WHERE active;

-- E2. Notification outbox (in-app, Teams, email) - filled by triggers, sent by a worker
CREATE TABLE notification_outbox (
    notification_id  BIGSERIAL PRIMARY KEY,
    scenario_id      INT NOT NULL REFERENCES scenario,
    case_id          INT REFERENCES disruption_case,
    flight_id        BIGINT REFERENCES flight,
    channel          TEXT NOT NULL CHECK (channel IN ('IN_APP','TEAMS','EMAIL')),
    recipient        TEXT NOT NULL,
    severity         severity_level NOT NULL DEFAULT 'INFO',
    title            TEXT NOT NULL,
    body             TEXT NOT NULL,
    source_entity    TEXT,
    source_id        TEXT,
    status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','FAILED','SUPPRESSED')),
    attempts         INT NOT NULL DEFAULT 0,
    last_error       TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at          TIMESTAMPTZ
);
CREATE INDEX ix_notification_pending ON notification_outbox (status, created_at) WHERE status = 'PENDING';

-- E3. Flight discussion thread: extend case_comment
ALTER TABLE case_comment
    ADD COLUMN kind TEXT NOT NULL DEFAULT 'COMMENT'
        CHECK (kind IN ('COMMENT','QUESTION','ANSWER','RECOMMENDATION','DATA_REQUEST','SYSTEM')),
    ADD COLUMN external_ref TEXT;                       -- Teams message id when mirrored

-- E4. "?" data requests (fuel not available -> ask crew -> enter)
CREATE TABLE data_request (
    request_id          BIGSERIAL PRIMARY KEY,
    scenario_id         INT NOT NULL REFERENCES scenario,
    flight_id           BIGINT REFERENCES flight,
    iata                CHAR(3) REFERENCES airport,      -- for alternate-status requests
    field               TEXT NOT NULL CHECK (field IN ('FUEL_ENDURANCE','ALTERNATE_STATUS','ALTERNATE_STANDS',
                                                       'CREW_SIGN_IN','CREW_QUALIFICATION','ETA','OTHER')),
    question            TEXT NOT NULL,
    requested_from_role TEXT REFERENCES app_role,
    requested_by        INT NOT NULL REFERENCES app_user,
    status              TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ANSWERED','CANCELLED')),
    answer              JSONB,
    answered_by         INT REFERENCES app_user,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    answered_at         TIMESTAMPTZ
);

-- E5. Custom operational rules with a validity window and priority
--     FILTER/ALERT/PRIORITY rules change what users see; CONSTRAINT rules may only TIGHTEN limits,
--     never relax the approved FDP rule set, and need approval before they become ACTIVE.
CREATE TABLE ops_rule (
    rule_id      SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('FILTER','ALERT','PRIORITY','CONSTRAINT')),
    description  TEXT NOT NULL,
    definition   JSONB NOT NULL,     -- e.g. {"all":[{"field":"lvp_crew_ok","op":"eq","value":false}]}
    priority     SMALLINT NOT NULL DEFAULT 100,
    valid_from   TIMESTAMPTZ NOT NULL,
    valid_to     TIMESTAMPTZ,
    status       TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','EXPIRED','REJECTED')),
    created_by   INT NOT NULL REFERENCES app_user,
    approved_by  INT REFERENCES app_user,
    approved_at  TIMESTAMPTZ,
    CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (kind <> 'CONSTRAINT' OR status <> 'ACTIVE' OR approved_by IS NOT NULL)
);

-- E6. Approval policy: which roles must approve which decision type ("approved by all")
CREATE TABLE approval_policy (
    decision_type  decision_type NOT NULL,
    approver_role  TEXT NOT NULL REFERENCES app_role,
    required       BOOLEAN NOT NULL DEFAULT TRUE,
    notify_roles   TEXT[] NOT NULL DEFAULT '{}',
    PRIMARY KEY (decision_type, approver_role)
);
INSERT INTO approval_policy VALUES
 ('DIVERT','OCC',TRUE,'{DISPATCH,CREW_CONTROL,STATION}'),
 ('CREW_REPLACE','CREW_CONTROL',TRUE,'{OCC,STATION}'),
 ('COMMANDER_DISCRETION','CREW_CONTROL',TRUE,'{OCC}'),
 ('AIRCRAFT_SWAP','OCC',TRUE,'{DISPATCH,CREW_CONTROL,STATION}'),
 ('DELAY','OCC',TRUE,'{DISPATCH,STATION}'),
 ('RECOVER','OCC',TRUE,'{RECOVERY,STATION}');

-- E7. External systems (aeroMart / aeroOps / crew system): deep links + integration outbox
CREATE TABLE external_system (
    code                TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    purpose             TEXT,
    deep_link_template  TEXT,          -- placeholders: {flight_no} {flight_date} {dep} {arr} {reg} {crew_id}
    api_base_url        TEXT,
    enabled             BOOLEAN NOT NULL DEFAULT FALSE
);
INSERT INTO external_system (code, name, purpose, deep_link_template) VALUES
 ('AEROMART','aeroMart','Reservations / inventory: diversion and re-protection entries',
  'https://aeromart.example/flight?flt={flight_no}&date={flight_date}&dep={dep}'),
 ('AEROOPS','aeroOps','Operations / movement control',
  'https://aeroops.example/flight?flt={flight_no}&date={flight_date}&dep={dep}&arr={arr}&reg={reg}'),
 ('CREW_SYSTEM','Crew management system (name to confirm)','Crew tracking / rostering',
  'https://crew.example/duty?flt={flight_no}&date={flight_date}');

CREATE TABLE integration_outbox (
    message_id       BIGSERIAL PRIMARY KEY,
    system_code      TEXT NOT NULL REFERENCES external_system,
    scenario_id      INT NOT NULL REFERENCES scenario,
    decision_id      BIGINT REFERENCES decision,
    flight_id        BIGINT REFERENCES flight,
    action           TEXT NOT NULL,          -- CREATE_DIVERSION_ENTRY, UPDATE_ETD, CREW_CHANGE ...
    payload          JSONB NOT NULL,
    idempotency_key  TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','ACKED','FAILED','MANUAL')),
    attempts         INT NOT NULL DEFAULT 0,
    response         JSONB,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at          TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION deep_link(p_system TEXT, p_flight_id BIGINT, p_scenario_id INT DEFAULT 1)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT replace(replace(replace(replace(replace(es.deep_link_template,
             '{flight_no}', f.flight_no), '{flight_date}', f.flight_date::text),
             '{dep}', f.dep_iata), '{arr}', coalesce(s.actual_arr_iata, f.arr_iata)),
             '{reg}', coalesce(s.registration, f.registration_planned, ''))
      FROM external_system es, flight f
      LEFT JOIN flight_state s ON s.flight_id = f.flight_id AND s.scenario_id = p_scenario_id
     WHERE es.code = p_system AND f.flight_id = p_flight_id
$$;

-- E8. KPI bar (per case) and severity score (per flight)
CREATE OR REPLACE VIEW v_flight_severity AS
SELECT w.case_id, w.scenario_id, w.flight_id, w.flight_no,
       coalesce((SELECT sum(pc.pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = w.flight_id), 0) AS connecting_pax,
       least(100, round(
           40 * CASE WHEN w.minutes_to_latest_legal_departure IS NOT NULL
                     THEN greatest(0, 1 - w.minutes_to_latest_legal_departure / 120.0) ELSE 0.3 END
         + 20 * CASE w.crew_status WHEN 'EXCEEDED' THEN 1 WHEN 'DISCRETION_REQUIRED' THEN .8
                                   WHEN 'AT_RISK' THEN .6 WHEN 'VERIFICATION_REQUIRED' THEN .5 ELSE 0 END
         + 15 * CASE WHEN w.lvp_required AND w.lvp_crew_ok IS NOT TRUE THEN 1 ELSE 0 END
         + 15 * least(1, coalesce((SELECT sum(pc.pax_count) FROM pax_connection pc WHERE pc.inbound_flight_id = w.flight_id), 0) / 200.0)
         + 10 * CASE WHEN w.open_exceptions > 0 THEN 1 ELSE 0 END))::int AS severity_score
  FROM v_flight_watch w;

CREATE OR REPLACE VIEW v_disruption_kpis AS
SELECT w.case_id, w.scenario_id,
       count(*)                                                               AS flights_watched,
       count(*) FILTER (WHERE w.status IN ('AIRBORNE','HOLDING','DIVERTING') OR w.diverted_to IS NOT NULL
                          OR w.status = 'SCHEDULED')                          AS flights_affected,
       count(*) FILTER (WHERE w.status = 'HOLDING')                           AS holding,
       count(*) FILTER (WHERE w.diverted_to IS NOT NULL)                      AS diverted,
       count(*) FILTER (WHERE w.crew_status IN ('AT_RISK','DISCRETION_REQUIRED','EXCEEDED')) AS crew_at_risk,
       count(*) FILTER (WHERE w.lvp_required AND w.lvp_crew_ok IS NOT TRUE)   AS lvp_blocked,
       count(*) FILTER (WHERE w.crew_status = 'VERIFICATION_REQUIRED' OR w.open_exceptions > 0) AS needs_verification,
       (SELECT count(*) FROM decision d WHERE d.case_id = w.case_id AND d.status = 'PROPOSED') AS decisions_pending,
       sum(coalesce(fs.pax, 0))                                               AS pax_on_board,
       sum(sv.connecting_pax)                                                 AS connecting_pax,
       min(w.minutes_to_latest_legal_departure)                               AS next_departure_deadline_min
  FROM v_flight_watch w
  LEFT JOIN flight_state fs ON fs.flight_id = w.flight_id AND fs.scenario_id = w.scenario_id
  LEFT JOIN v_flight_severity sv ON sv.case_id = w.case_id AND sv.flight_id = w.flight_id
 GROUP BY w.case_id, w.scenario_id;
```

## Appendix B: `07_proposed_triggers.sql` (validated)

`trg_decision_approval` **replaces** the existing function of the same name (same trigger, multi-role logic).

```sql
SET search_path = fogops, public;

-- T1. Multi-role approval: a decision becomes APPROVED only when every required role in
--     approval_policy has approved; any REJECTED verdict rejects it. No policy rows = any approver.
CREATE OR REPLACE FUNCTION trg_decision_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_ok BOOLEAN; v_user_role TEXT; d decision%ROWTYPE; v_has_policy BOOLEAN; v_missing INT;
BEGIN
    SELECT u.role_code, (r.is_human AND r.can_approve) INTO v_user_role, v_ok
      FROM app_user u JOIN app_role r ON r.code = u.role_code WHERE u.user_id = NEW.approver_id;
    IF NOT coalesce(v_ok, FALSE) THEN
        RAISE EXCEPTION 'Guardrail: user % (%) is not authorised to approve decisions', NEW.approver_id, v_user_role;
    END IF;
    IF NEW.approver_role <> v_user_role THEN
        RAISE EXCEPTION 'approver_role % does not match user role %', NEW.approver_role, v_user_role;
    END IF;
    SELECT * INTO d FROM decision WHERE decision_id = NEW.decision_id FOR UPDATE;
    IF d.status <> 'PROPOSED' THEN RAISE EXCEPTION 'Decision % is already %', d.decision_id, d.status; END IF;

    SELECT EXISTS (SELECT 1 FROM approval_policy WHERE decision_type = d.decision_type) INTO v_has_policy;
    IF v_has_policy AND NOT EXISTS (SELECT 1 FROM approval_policy
                                     WHERE decision_type = d.decision_type AND approver_role = NEW.approver_role) THEN
        RAISE EXCEPTION 'Role % is not an approver for % decisions', NEW.approver_role, d.decision_type;
    END IF;

    IF NEW.verdict = 'REJECTED' THEN
        UPDATE decision SET status = 'REJECTED' WHERE decision_id = d.decision_id;
    ELSE
        SELECT count(*) INTO v_missing FROM approval_policy p
         WHERE p.decision_type = d.decision_type AND p.required
           AND NOT EXISTS (SELECT 1 FROM decision_approval a
                            WHERE a.decision_id = d.decision_id AND a.approver_role = p.approver_role
                              AND a.verdict = 'APPROVED');
        IF NOT v_has_policy OR v_missing = 0 THEN
            UPDATE decision SET status = 'APPROVED' WHERE decision_id = d.decision_id;
        END IF;
    END IF;
    IF d.rec_id IS NOT NULL THEN
        UPDATE recommendation
           SET status = CASE WHEN NEW.verdict = 'REJECTED' THEN 'REJECTED'::rec_status
                             WHEN coalesce(d.followed_recommendation, TRUE) THEN 'ACCEPTED'::rec_status
                             ELSE 'REJECTED'::rec_status END
         WHERE rec_id = d.rec_id AND status = 'PROPOSED'
           AND (NEW.verdict = 'REJECTED' OR (SELECT status FROM decision WHERE decision_id = d.decision_id) = 'APPROVED');
    END IF;
    RETURN NEW;
END $$;

-- T2. Notification fan-out to flight subscribers (+ NOTIFY for the notification worker)
CREATE OR REPLACE FUNCTION notify_flight(p_scenario_id INT, p_flight_id BIGINT, p_case_id INT,
                                         p_title TEXT, p_body TEXT, p_sev severity_level,
                                         p_entity TEXT, p_entity_id TEXT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
    INSERT INTO notification_outbox (scenario_id, case_id, flight_id, channel, recipient, severity, title, body,
                                     source_entity, source_id)
    SELECT p_scenario_id, p_case_id, p_flight_id, s.channel,
           coalesce(s.target, (SELECT username FROM app_user WHERE user_id = s.user_id)),
           p_sev, p_title, p_body, p_entity, p_entity_id
      FROM flight_subscription s
     WHERE s.active AND s.scenario_id = p_scenario_id AND s.flight_id = p_flight_id
       AND (s.user_id IS NULL OR s.user_id IS DISTINCT FROM actor_user_id());   -- don't notify the author
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
        PERFORM pg_notify('fogops_notify', json_build_object('flight_id', p_flight_id, 'count', n)::text);
    END IF;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION trg_flight_notify() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v JSONB := to_jsonb(NEW); o JSONB := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END;
        v_flight BIGINT; v_scn INT; v_case INT; v_title TEXT; v_body TEXT; v_sev severity_level := 'INFO'; v_no TEXT;
BEGIN
    v_flight := coalesce((v->>'flight_id')::bigint, (v->>'original_flight_id')::bigint);
    v_case   := (v->>'case_id')::int;
    v_scn    := coalesce((v->>'scenario_id')::int, (SELECT scenario_id FROM disruption_case WHERE case_id = v_case));
    IF v_flight IS NULL OR v_scn IS NULL THEN RETURN NEW; END IF;
    SELECT flight_no INTO v_no FROM flight WHERE flight_id = v_flight;
    CASE TG_TABLE_NAME
      WHEN 'decision' THEN
        IF TG_OP = 'UPDATE' AND o->>'status' = v->>'status' THEN RETURN NEW; END IF;
        v_title := format('%s: %s %s', v_no, v->>'decision_type', v->>'status');
        v_body  := v->>'rationale';
        v_sev   := CASE WHEN v->>'status' IN ('PROPOSED','APPROVED') THEN 'WARN' ELSE 'INFO' END;
      WHEN 'case_comment' THEN
        v_title := format('%s: new %s', v_no, lower(coalesce(v->>'kind', 'comment')));
        v_body  := v->>'body';
      WHEN 'diversion' THEN
        IF TG_OP = 'UPDATE' AND (o->>'status', o->>'waiting_for') IS NOT DISTINCT FROM (v->>'status', v->>'waiting_for') THEN
            RETURN NEW; END IF;
        v_title := format('%s at %s: %s', v_no, v->>'alternate_iata', v->>'status');
        v_body  := 'Waiting for ' || (v->>'waiting_for');
      WHEN 'data_request' THEN
        v_title := format('%s: data request %s', v_no, v->>'status');
        v_body  := v->>'question';
        v_sev   := 'WARN';
      ELSE RETURN NEW;
    END CASE;
    PERFORM notify_flight(v_scn, v_flight, v_case, v_title, v_body, v_sev, TG_TABLE_NAME, coalesce(v->>'decision_id', v->>'comment_id', v->>'diversion_id', v->>'request_id'));
    RETURN NEW;
END $$;
CREATE TRIGGER notify_decision  AFTER INSERT OR UPDATE ON decision     FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_comment   AFTER INSERT           ON case_comment FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_diversion AFTER INSERT OR UPDATE ON diversion    FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();
CREATE TRIGGER notify_request   AFTER INSERT OR UPDATE ON data_request FOR EACH ROW EXECUTE FUNCTION trg_flight_notify();

-- T3. Integration outbox: an EXECUTED diversion queues the aeroMart entry (idempotent)
CREATE OR REPLACE FUNCTION trg_integration_outbox() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE f flight%ROWTYPE;
BEGIN
    IF NEW.status = 'EXECUTED' AND OLD.status IS DISTINCT FROM 'EXECUTED' AND NEW.decision_type = 'DIVERT' THEN
        SELECT * INTO f FROM flight WHERE flight_id = NEW.flight_id;
        INSERT INTO integration_outbox (system_code, scenario_id, decision_id, flight_id, action, payload, idempotency_key)
        VALUES ('AEROMART', NEW.scenario_id, NEW.decision_id, NEW.flight_id, 'CREATE_DIVERSION_ENTRY',
                jsonb_build_object('flight_no', f.flight_no, 'flight_date', f.flight_date, 'dep', f.dep_iata,
                                   'planned_arr', f.arr_iata, 'diverted_to', NEW.alternate_iata,
                                   'recovery_flight_id', NEW.details->>'recovery_flight_id',
                                   'decided_by', NEW.decided_by, 'decision_id', NEW.decision_id),
                'DIVERT-' || NEW.decision_id)
        ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER integration_on_execute AFTER UPDATE ON decision FOR EACH ROW EXECUTE FUNCTION trg_integration_outbox();
```
