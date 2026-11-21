# WP-0: Parity test kit

**Why:** every package must be verified against the teammate's FastAPI backend on throwaway databases. We did this by hand with scripts that lived in
a temporary session folder that no longer exists. Turn the method into a repeatable tool in the repo so every package can run it with one command.

**Skills:** bash, Python 3.12 (standard library only), Docker, a little SQL. No Java. **Size:** M. **Depends on:** step 0.

## Brief to paste into Claude

> You are working on the FogOps repo. First read `CLAUDE.md` at the repo root (especially "Testing against the spec") and `docs/work-packages/README.md`.
> Show me a short plan before you write anything.
>
> Build `hackathonTeamYashasvi/tools/parity/`, a tool that proves the Spring backend behaves like the FastAPI backend in `backend/`:
>
> 1. `run.sh`: one command. It (a) takes a read-only `pg_dump -Fc` of the real database `hackathon_yashasvi` (container `yashasvi-postgres`; use
>    the variables from `hackathonTeamYashasvi/.env`, never print them), (b) creates two scratch databases `scratch_py` and `scratch_sp` and restores
>    the dump into both, (c) deletes `fogops.app_credential` rows in `scratch_py` so FastAPI seeds its own, (d) starts FastAPI from `backend/` on
>    port 8000 with `WORKER_ENABLED=false` against `scratch_py`, and the Spring jar on port 8888 against `scratch_sp` from a neutral working
>    directory, (e) waits for both `/health`, (f) runs every scenario, (g) prints a summary, (h) ALWAYS cleans up (stop both, drop both scratch
>    databases, optionally restart Spring on the real database), even when something fails.
> 2. Scenarios as data files (JSON): a list of requests with the acting user, optional captured values (for example the new `case_id`), and the
>    expected status. Port these existing checks: (i) every GET the UI uses for every case, including `/api/deadlines` and every
>    `/api/flights/{id}/detail`; (ii) the Phase 3 action sequence: clone a REPLAY scenario, create a case, feed events (duplicate and out of order),
>    airport status and fuel records, recommend, a decision authored as the AGENT (must be refused 403), approve, execute diversion, station update,
>    crew swap with every refusal (no decision, unapproved, wrong duty, wrong crew), recovery build, report, case create with simulated fog, close,
>    delete (with and without decisions), unknown table and column, bad token; (iii) feed push (twice, plus a non-OCC user); (iv) recommend for
>    every airborne flight.
> 3. `compare.py`: compares responses (status plus body) and then the resulting table contents of the two databases (one SQL file that hashes
>    selected tables without volatile columns). Normalise: ISO timestamps compare as instants, numbers to 6 decimals, ignore volatile keys
>    (`last_update_utc`, `occurred_at`, `ms`, `created_at`, `last_received_at`), optional order-insensitive comparison for lists.
> 4. `deviations.json`: the deliberate differences, each with a reason, so they are reported as "expected" and anything else fails. Start with the
>    list in `CLAUDE.md` ("Deliberate deviations from FastAPI"): validation `detail` is a string, swap needs an approved matching decision,
>    detail shows "needs verification" instead of 500, feed push is OCC/ADMIN only, `ai:false` on `/ask/questions`.
> 5. A `README.md` in the folder: prerequisites, how to run one scenario, how to add a scenario, how to add a deviation.
>
> Pitfalls we already hit: zsh does not split `$VAR` into words (use functions or arrays); never `pkill -f <pattern>` (it kills your own shell, find the
> PID with `ss -ltnp`); start servers with `setsid nohup ... < /dev/null &`; FastAPI cannot verify Spring's BCrypt hashes; use Python 3.12 (3.8 rejects
> 5-digit fractional seconds); `docker exec -e PGPASSWORD=...` for psql; Spring starts with Flyway on, so scratch copies migrate themselves.
> Never write to the real database. Never print credentials or tokens.

## Acceptance criteria

- `tools/parity/run.sh` on a clean checkout (Docker, JDK 17 and Python 3.12 present) runs all scenarios and ends with a table: scenarios run, requests
  compared, identical, expected deviations, **unexpected differences** (must list each with both responses). Exit code is non-zero when any
  unexpected difference exists.
- It reproduces the known result: all four cases' deadlines and all 410 flight details identical except the two flights FastAPI answers with 500.
- Cleanup leaves no scratch database and no process on 8000 (and restores Spring on 8888 when asked).
- The real database is only read (the dump).
- A new scenario can be added by editing a JSON file, no code.
