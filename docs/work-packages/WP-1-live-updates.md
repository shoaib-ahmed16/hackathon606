# WP-1: Live updates (Phase 4): SSE stream and reassessment worker

**Why:** today a feed event or fuel entry does not change the advice until someone clicks "re-run", and the UI never refreshes by itself. This package
makes crew legality (current legs and legs + 1) and the hold/divert advice recompute automatically and pushes the refresh to the browser.

**Skills:** Java, Spring MVC (SseEmitter), JDBC, PostgreSQL LISTEN/NOTIFY. **Size:** M. **Depends on:** step 0. Independent of all other packages.

## Brief to paste into Claude

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md`. Show me a short plan
> (files, threads, config, tests, deviations) and wait for my OK before coding.
>
> Port two pieces of the FastAPI backend, which is the executable spec: `backend/app/stream.py` and `backend/app/worker.py` (also read
> `backend/README.md` section 11, the worker contract, and `src/features/ops/useOps.js` in `hackathon-app`, which consumes the stream).
> Put the code in a new package `com.yashasvi.hackathon.fogops.live`.
>
> **`GET /api/stream`** (Server-Sent Events, signed in via header or `?token=`, already handled by `FogopsAuthFilter`):
> on connect send `event: ready` with data `{}`; relay Postgres `NOTIFY fogops_reassess` as `event: reassess` and `fogops_updated` as `event: updated`,
> data `{"payload": "<notify payload>"}`; send a `: keep-alive` comment every 15 s when idle. Use ONE dedicated, non-pooled pgjdbc connection
> that runs `LISTEN` and fans out to all open emitters (do not open one database connection per browser). Reconnect with back-off when the
> connection drops, remove dead emitters, cap the number of emitters, no emitter timeout. nginx already forwards `/ops-api/` unbuffered.
>
> **Reassessment worker** (config `fogops.worker.enabled`, env `WORKER_ENABLED`, default true): runs as the AGENT user through
> `FogTx.as(fogTx.agentUserId(), ...)`. Loop: drain `reassessment_queue` at start, then wait for `LISTEN fogops_reassess` (or a 5 s tick).
> Claim one `PENDING` job with `UPDATE ... SET status='RUNNING', picked_at=now() WHERE job_id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING *`;
> work out the affected flights by `entity_type` (flight, crew_duty, decision, otherwise every watched flight of that scenario); for each flight inside
> a SAVEPOINT (one bad flight must not fail the job): `compute_flight_legality(scn, flight, 'worker')`, `compute_latest_departure` for the recovery
> flight if one exists, and `propose_hold_or_divert` for airborne or holding case flights that have no decision in `PROPOSED/APPROVED/EXECUTED`;
> then mark the job `DONE` and `pg_notify('fogops_updated', '{"job_id":..,"scenario_id":..}')`; on failure mark `FAILED` with the first 500 characters of
> the error and carry on. Several app instances must be safe together (SKIP LOCKED).
>
> Do not change the SQL functions. The AGENT may recommend but never decide (the database enforces it; keep it that way). Do not touch
> `/api/whatif` (WP-2 marks queued jobs done so the worker does not race it; keep the queue semantics intact).

## Acceptance criteria

- On a scratch copy, `POST /api/events/flight` (and `POST /api/feed/push`) enqueue jobs; within a few seconds they are `DONE`, `fdp_calculation` current rows
  and `latest_departure_calc` are refreshed (current legs and legs + 1 without any click) and airborne case flights get a new recommendation, unless a
  human decision is already in flight.
- A `curl -N` or browser `EventSource` on `/api/stream?token=...` receives `ready`, then `updated` after a push, and keep-alive comments while idle.
- The resulting `recommendation`, `recommendation_option` and `reassessment_queue` rows equal the FastAPI worker's on the same input (use WP-0, or two scratch
  databases by hand).
- A job for a nonexistent flight ends `FAILED` with an error text, not stuck `RUNNING`; the next job still runs.
- 50 open streams use one LISTEN connection. Killing the database connection recovers by itself.
- `WORKER_ENABLED=false` disables the worker but not the stream.
- Unit tests for the pure parts (flight selection per entity type is written so it can be tested without a database; SSE formatting). Any test that
  touches a database must refuse to run unless the database name starts with `scratch_`.
- Optional, flag it as an enhancement and keep it off by default: reclaim jobs stuck `RUNNING` for more than N minutes.
