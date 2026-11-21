# WP-2: Recovery plan edits and what-if (Phase 5)

**Why:** the Recovery lens (approve a plan, move a flight to another arrival slot) and the "What if..." dialog return 404 today.

**Skills:** Java, JDBC, PostgreSQL. **Size:** M. **Depends on:** step 0. Independent of all other packages.

## Brief to paste into Claude

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md`. Show me a short
> plan and wait for my OK before coding.
>
> Port three endpoints from `backend/app/routes_console.py` (lines 169 to 270, the executable spec). New package
> `com.yashasvi.hackathon.fogops.recovery`; use `FogTx` for every write (see `write/WriteController.java` for the pattern) and `Times` for dates.
>
> 1. `POST /api/whatif` body `{scenario_id?, case_id, reopen_shift_min=45, name?}`. It runs the engine in a separate WHATIF copy with the hub reopening
>    moved and compares with the current picture. Nothing in the live scenario may change. Three transactions as in the original: (a) as the user:
>    load the case (404 `Unknown case`), read `v_airport_status_current` for the hub (409 when there is none), `clone_scenario(..., 'WHATIF')`, mark the
>    clone's `PENDING` queue jobs `DONE` with the error text `what-if clone baseline` so the worker does not race; (b) as the user: insert the
>    shifted `airport_status_event` (quality `SIMULATED`; an open airport is closed again until now + shift with LVP in force), copy the fuel estimates,
>    create the what-if case and copy its `case_flight` rows, mark queued jobs `DONE` again; (c) as the AGENT (`fogTx.agentUserId()`): for every airborne or
>    holding case flight run `compute_flight_legality(..., 'whatif')` and `propose_hold_or_divert`. Then compare rank 1 of `v_recommendation_options`
>    between the live scenario and the clone and return `{scenario_id, case_id, shift_min, new_reopen_utc, had_forecast, rows[{flight_no, current, what_if,
>    changed}], changed}` with changed rows first, then by flight number.
> 2. `POST /api/recovery/{planId}/approve`: 403 `Your role cannot approve recovery plans` unless `app_role.can_approve` for the user's role; only a
>    `PROPOSED` plan can be approved, else 409 `Plan is not in PROPOSED status`; sets `approved_by`, `approved_at`; returns the updated row.
> 3. `PATCH /api/recovery/{planId}/items/{flightId}` body `{proposed_slot_utc}`: 404 `Flight is not in this plan`; 409 `Only a PROPOSED plan can be edited`;
>    409 when the slot is before `earliest_arrival_utc` (message `Not possible: this flight cannot arrive before HH:MMZ`); 409 `That slot is already taken
>    (one arrival per slot)`; returns the updated item.
>
> Check `hackathon-app/src/components/ops/WhatIfDialog.jsx` and `components/ops/lenses/RecoveryLens.jsx` for exactly what the UI sends and reads.
> Errors are `{"detail": "<string>"}` (see `ApiExceptionHandler`). Do not edit `AuditSummary` (the wording for these paths already exists).

## Acceptance criteria

- The Recovery lens approves a plan and moves a slot; the What-if dialog shows the comparison, in the browser (build the UI with
  `docker compose -f docker-compose.spring.yml up -d --build`) and by API.
- On two scratch copies (FastAPI and Spring, same inputs) the responses and the resulting table contents are identical for: a what-if with the default
  shift and with a negative shift, a hub with no status (409), unknown case (404), approve as OCC (ok), as dispatch (403), approve twice (409), a slot too
  early, a taken slot, a slot on an approved plan.
- **A what-if never changes the LIVE scenario:** hash the LIVE rows of `airport_status_event`, `flight_fuel_estimate`, `recommendation`, `case_flight`
  before and after and show they are equal.
- Guardrails: the what-if's recommendations are written by the AGENT, never a decision; every call is audited by the existing filter; no crew mobile numbers.
- Unit tests for the pure parts (response comparison and ordering, slot validation). Database-touching tests refuse to run unless the database name starts
  with `scratch_`.
- Report every deviation from FastAPI (expected: none besides string `detail` on validation errors).
