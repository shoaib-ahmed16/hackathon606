# FogOps API (FastAPI) on top of the FogOps Postgres DB

Thin layer: reads come from DB views, actions call DB functions, so every rule (legality, LVP, guardrails,
audit) stays in Postgres. Interactive docs: `http://localhost:8000/docs`. Database handbook: `fogops_db/README.md`.

## Run locally

```bash
cd backend
docker compose up -d db                           # Postgres on 127.0.0.1:5433 (data lives in a volume)
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
export FOGOPS_DSN=postgresql://postgres:postgres@127.0.0.1:5433/fogops
uvicorn app.main:app --reload --port 8000
```

Build the database once from the Excel files (about 2 minutes), then add the daily cases:

```bash
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGPASSWORD=postgres
pip install pandas openpyxl xlrd psycopg2-binary airportsdata
./fogops_db/rebuild.sh ./Hack606_Fog_Ops fogops
psql -d fogops -f fogops_db/sql/05_demo_fog_replay.sql   # optional: the simulated fog replay case
psql -d fogops -f db/init/20_cases.sql                   # one watch-list case per day of real data
```

`scripts/make_db_dump.sh` rebuilds the data and writes `db/init/10_fogops.sql.gz`, which the root
`docker-compose.yml` restores on the server's first start (no Excel files needed there).

## Login

`POST /api/auth/login {username, password}` returns a signed token. Send it as `Authorization: Bearer <token>`
(the event stream takes `?token=`). Every `/api` route except login needs it, and the database sees the real user,
so role guardrails apply. Demo users: `occ.dm`, `dispatch.1`, `crew.ctl.1`, `recovery.1`, `admin`, and station users
`station.rkt/fjr/aan/mct` (after the demo script). Password: `DEMO_PASSWORD` (default `FogOps@2026`).
The `agent` account (the non-human engine) cannot sign in. Set `AUTH_SECRET` in production.

## Database migrations

On startup the API applies any new `backend/migrations/NNN_*.sql` file (see `backend/README.md`, "Database changes").
`GET /health` returns `"migration": "<latest file>"`. A failed migration is logged as `MIGRATION FAILED` and the database
stays at its previous level. `rank_alternates()` (used by deadlines and the flight drawer preview) gained columns
`flight_min_p90, flight_time_basis, final_reserve_min, fuel_basis, bingo_utc, return_arrival_hub_utc`.

## Background worker (reassessment loop)

Runs inside the API process (`WORKER_ENABLED=true`). It follows the contract in `fogops_db/README.md` section 11:
`LISTEN fogops_reassess` -> claim jobs -> recompute crew legality -> latest legal departure of the recovery leg ->
new hold/divert recommendation for airborne flights (skipped while a human decision is pending or approved) ->
mark DONE/FAILED -> `NOTIFY fogops_updated`. It acts as the AGENT user, so it can recommend but never decide.
`GET /api/queue` shows queue health. The UI refreshes from the event stream.

## Source of truth

Every number on every screen comes from the database, which was loaded from the organizers' Excel files by `fogops_db/loader/load_data.py`
(flights, crew duty sheets, roster, FDTL rules, standby, passengers, history). The UI computes nothing operational: legality, deadlines,
options and recommendations are database views and functions. Anything that is not from the files is stored with a quality label
(`ESTIMATED`, `FORECAST`, `MANUAL`, `SIMULATED`, `ASSUMED`) and shown with it. Simulated fog (demo cases, what-if) lives in separate
WHATIF/REPLAY scenarios and is labelled `SIMULATED`.

Times: the data is UTC, crew legality bands use SHJ local (UTC+4). The UI shows both everywhere ("02:38Z / 06:38 SHJ") and counts down live
from the scenario clock.

## Audit

Every action is recorded in the append-only `audit_log`, in two layers: the database records every table change with the acting user
(decisions, approvals, comments, cases, crew swaps, station updates, fuel, airport status), and `app/audit.py` records every state-changing
API call (login/logout, Ask questions, what-if, engine re-runs, case create/close/delete, refused attempts with the status code).
`GET /api/audit` serves it (filters: kind, who, case, text, flight, include engine/import rows); the UI shows it on the Audit trail page and
per flight. Rows cannot be updated or deleted.

## Ask (assistant)

`POST /api/ask {question, case_id}`. Suggested questions (`GET /api/ask/questions`, filled with real flights and tails) are answered
deterministically from the database, with the source named. Free text goes to Claude only when `ANTHROPIC_API_KEY` is set; Claude receives a
compact JSON snapshot of this case's database facts and is told to answer only from it. Default model `claude-opus-5-5` (`ASK_MODEL` to change),
low effort, server-side refusal fallback on. The key never leaves the server. Without a key, free text returns a clear "not configured" message.

**Guard rails (enforced in `routes_ask.py`, before any answer, not only in the prompt)**
- **Read-only.** Requests to delete, update, approve, execute, cancel, divert, send ... (and SQL-like text) are refused. The assistant has no tools and no write path. Its "next step" buttons only navigate (open a flight, approvals, a view).
- **No personal data.** Crew appear as position and crew number. Questions asking for names, phone, e-mail, address, passport etc. are refused, and every answer (predefined or AI) passes a scrubber that masks crew names, e-mail addresses and phone numbers.
- **One domain.** Free text that is not about this disruption is refused without calling the model. The model prompt repeats this and returns JSON (`answer`, `flights`, `out_of_scope`); flight cards are built only for flight numbers that exist in the case.
- **Prompt injection.** Attempts to change the rules, reveal the prompt or ask for keys/passwords are refused. The question is passed to the model as untrusted text.
- **Explains the console.** "How does the Recovery tab work?", "What does severity mean?" and similar are answered from a built-in guide (`app/help_kb.py`, 31 topics: screens, tabs and terms) with no model call and no data read, plus a button that opens the screen. A question that names a flight or tail is treated as a data question instead. Keep the guide in step with the product when a rule changes.
- **Audit.** Every question and every refusal (`ASK_REFUSED`, with the reason) is recorded.
- **Response shape:** `{ mode, answer, source, items: [{ flight_id, flight_no, route, status, chips[], actions[] }], actions[] }`; `mode` is `predefined | ai | refused | fallback | error`.

## Endpoints (scenario-scoped; no `scenario_id` = LIVE)

| Method | Path | Source |
|---|---|---|
| POST | `/api/auth/login`, GET `/api/me` | `app_user`, `app_credential` |
| GET | `/api/scenarios`, `/api/cases`, `/api/users` | scenario, disruption_case, app_user |
| POST | `/api/cases/create` | new case + watch list of every flight arriving at an airport in a time window; optional SIMULATED fog |
| GET | `/api/flights?scenario_id&case_id` | `v_flight_watch` (status, crew legality, LVP, recommendation, decision, latest legal departure) |
| GET | `/api/recommendations/options` | `v_recommendation_options` (ranked HOLD + alternates, blocking constraints) |
| GET | `/api/crew/legality` | Q1 `v_crew_legality_ranking` |
| GET | `/api/aircraft/{reg}` | Q2 `v_aircraft_whereabouts` |
| GET | `/api/crew/standby-candidates` | Q4 `standby_candidates()` |
| GET | `/api/airport/status`, `/recovery/plan`, `/decisions/log`, `/timeline`, `/feed/freshness`, `/exceptions`, `/diversions`, `/comments`, `/fuel`, `/queue`, `/stream` | views and tables |
| POST | `/api/flights/{id}/recommend` | re-run `propose_hold_or_divert()` (as the agent) |
| POST | `/api/events/flight` | `ingest_flight_event()` (dedupe, out-of-order safe) |
| POST | `/api/decisions/{id}/execute-diversion` | `execute_diversion()` |
| POST | `/api/crew/swap` | `swap_crew()` + `crew_replacement`; needs an APPROVED CREW_REPLACE decision |
| PATCH | `/api/diversions/{id}` | station update at the alternate |
| POST | `/api/flights/{id}/recompute`, `/api/recovery/build`, `/api/cases/{id}/report`, `/api/scenarios/clone` | DB functions |
| GET | `/api/deadlines?case_id` | next hard deadline per flight (last moment to divert on fuel, latest legal departure) with the reasoning |
| GET | `/api/flights/{id}/detail?case_id` | recommendation text and assumptions, crew with LVP, FDP breakdown, connecting passengers, what each option would do |
| GET | `/api/briefing?case_id&since` | what changed since the operator last looked |
| POST | `/api/ask`, GET `/api/ask/questions` | the assistant (see above) |
| POST | `/api/whatif {case_id, reopen_shift_min}` | engine run in a separate WHATIF copy, compared with the current advice |
| GET | `/api/audit` | the audit trail |
| POST | `/api/recovery/{plan}/approve`, PATCH `/api/recovery/{plan}/items/{flight}` | approve the plan / move a flight to another slot (refused if impossible) |
| POST | `/api/auth/logout` | records the sign-out |
| POST | `/api/records/{table}` | INSERT into decision, decision_approval, recommendation(_option), case_comment, airport_status_event, disruption_case, case_flight, flight_fuel_estimate, crew_replacement |
| POST | `/api/feed/push {as_of?}` | simulated live feed up to now through `ingest_flight_event` (flight movements, pax, crew duty status, standby release, SIMULATED fuel); idempotent |
| GET | `/api/kpis?case_id` | KPI bar: `v_disruption_kpis` + count of high-severity flights (`v_flight_severity`). `/api/flights` rows also carry `severity_score`, `connecting_pax` |
| GET | `/api/approvals?case_id&flight_id&status&mine` | decisions with required / approved / waiting roles and `can_approve` for the signed-in user (`approval_policy`) |
| POST | `/api/decisions/{id}/approvals {verdict, comment}` | one role's verdict; the DB trigger flips the decision when every required role approved (any rejection rejects; a reason is required) |
| GET | `/api/approval-policy` | who must approve which decision type |
| GET, POST, DELETE | `/api/me/subscriptions`, `/api/flights/{id}/subscriptions` | watch a flight (in-app) |
| GET, POST | `/api/me/notifications`, `/api/notifications/{id}/read`, `/api/me/notifications/read-all` | in-app inbox (PENDING = unread); filled by DB triggers for subscribers (the author is not notified); the SSE stream emits `notify` |
| GET, POST | `/api/data-requests`, `/api/flights/{id}/data-requests`, `/api/data-requests/{id}/answer` | the "?" flow: ask the right role for missing fuel / alternate status; an answer is applied (fuel estimate, airport status, with its quality label) and the options are re-ranked |
| GET | `/api/flights/{id}/links` | "Open in aeroOps / crew system / aeroMart" deep links from `external_system` templates (`configured=false` while a template still has the placeholder host) |
| GET | `/api/flights/{id}/timeline` | per-flight briefing: feed events, decisions, approvals, comments, data requests on one clock |
| POST | `/api/decisions/{id}/execute` | OCC executes an APPROVED decision of any type (DIVERT creates the recovery leg and queues the aeroMart entry; CREW_REPLACE performs the swap) |
| GET | `/api/flights/{id}/alternates` | `rank_alternates()`: stands, fuel margin, return block, crew outcome, why blocked |
| POST, DELETE | `/api/flights/{id}/tags`, `/api/flights/{id}/tags/{tag}` | tag a flight MEDICAL / VIP / HIGH_IMPACT; shown on the board, usable in rules (`tag`), announced to watchers and OCC |
| POST | `/api/flights/{id}/subscriptions {teams}` | also mirror alerts to the Teams channel (`teams: true/false`); `/api/me/subscriptions` returns `teams` per flight |
| GET, PATCH, POST | `/api/integrations`, `/api/integrations/systems/{code}`, `/api/integrations/outbox/{id}/entered` | systems and deep-link templates, the aeroMart outbox, manual tasks while an integration is off |

Database guardrails come back as readable errors (e.g. 403 "decisions must be made by a human user").

## Time

LIVE runs on a fixed scenario clock (the 16:45Z snapshot) until a real feed sets `scenario.sim_clock_utc = NULL`.
Rows that must be visible to the views (airport status, fuel) are stamped with `scenario_now()`.

## Deploy

See the root `docker-compose.yml` and `.env.example` (db + api + web, UI on 8080, API on 8888).

## Data explorer (OCC and ADMIN only, read-only)
A full-screen page (`/data` in the UI) to browse every table and view with its relations, for validating the data end to end.
Every query runs in a READ ONLY transaction with a 10 s statement timeout; table and column names come from the catalog, values are
bound parameters, and columns that look like secrets (password, token, hash, ...) and the credentials table are never returned.

| Endpoint | What it gives |
|---|---|
| `GET /api/explorer/catalog` | every table/view: columns, primary and foreign keys both ways, view lineage, row counts, domain |
| `GET /api/explorer/rows?table=&q=&f=col\|op\|val&sort=&dir=&limit=&offset=` | rows with search, column filters (`eq`, `like`, `null`, `notnull`), sorting, paging |
| `GET /api/explorer/links?table=&row={json}` | for one row: parent rows it points at, child rows that point at it (two levels, with counts) |
| `GET /api/explorer/profile?table=` | per column: empty count, distinct count, min, max |

## Security notes (changed after the demo test report)
* **Session token:** only in the `Authorization: Bearer` header. A `?token=` in the URL is no longer accepted anywhere.
* **Live stream:** `POST /api/stream/ticket` (with the bearer header) returns a random ticket valid for 30 seconds and usable once; open
  `GET /api/stream?ticket=...` with it. Reconnecting means asking for a new ticket.
* **API docs** (`/docs`, `/redoc`, `/openapi.json`) are off unless `ENABLE_DOCS=1` is set in `.env`, and the web container never forwards them.
* **`POST /api/records/{table}`** accepts only `decision`, `case_comment`, `airport_status_event`, `flight_fuel_estimate` and `crew_replacement`,
  each for the roles that work with it. Recommendations, cases and watch lists have their own endpoints.
* **`DELETE /api/cases/{id}`** is admin-only (and still refuses a case that has decisions or comments). OCC closes cases.
* Replacement finder: `crew_replacement_options()` now returns `from_leg_seq` and `report_station` and counts road time before sign-in.

## Alternates manager (OCC and ADMIN)
The airports the engine may divert to are editable from the UI (Alternates, in the tools row). Nothing is deleted: an alternate is switched off, not removed.
| Endpoint | What it does |
|---|---|
| `GET /api/alternates?hub=SHJ` | every alternate, active or not: priority, road time, stands, handling / fuel / customs, history, station logins |
| `GET /api/airport-search?q=` | find an airport by code, name or country (only airports in the database can be added) |
| `POST /api/alternates` | add or change one (OCC, ADMIN). Validates codes, ranges and roles. Re-ranks open cases (trigger `reassess_alternate`, migration 015) |
| `POST /api/alternates/{iata}/station-login` | create `station.<iata>` with the demo password (ADMIN only) |
A new alternate has no status yet, so it appears as "?" and is not executable until OCC or the station enters its status.

## Added after the usability review
| Endpoint | What it does |
|---|---|
| `POST /api/decisions/{id}/withdraw` | the proposer (or OCC/admin) takes back a proposal that is PROPOSED or APPROVED, with a reason. It becomes REVOKED (kept in the record); approvers are told and the flight is re-assessed. `GET /api/approvals` now returns `can_withdraw` |
| `GET /api/flights/{id}/connections` | passengers who connect onward from this flight: onward flight, pax, projected vs planned connection time, status (worst first) |
| `GET /api/flights/{id}/fuel-card` | fuel on board now (kg), burn rate, and per alternate: what the aircraft lands with, kg above the final reserve, and the uplift the return leg needs. The burn rate is the holding burn used as a stand-in for the leg (stated in the response) |
| `GET /api/crew/fdp-preview?duty_id=&report_utc=` | before sign-in: the bracket and maximum FDP a new report time would give. After sign-in: `locked: true`, no preview |
| `GET /api/deadlines` | a diverting aircraft returns kind `diverting` (landing time, no departure countdown); when the crew cannot legally fly the return the kind is `crew` and the text says so, with the options |

Migration `017` gives an aircraft that has just been diverted a real landing time (hub to alternate flight time) and plans the recovery leg from it.
Text built by the database for the briefing and the flight timeline goes through `app/plain.py`: crew ids become names, internal codes become words.

