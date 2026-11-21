# WP-4: Stand and slot capacity

**Requirement:** "check the available stand/slot info for diversion (use the historical data to see how many flights were accommodated in those stands per
hour, or add a config screen to assume x slots available per airport)".

**Today:** stands come only from a manual airport-status entry (`parking_available`) minus the diversions already active. `alternate_airport.max_parking_stands`
is NULL for all six alternates. History is thin at the alternates (peak arrivals per hour: RKT 817 hours of history, MCT 512, FJR 11, AAN 4, AUH 8, DWC 1), so a
configured assumption is required and history is only a supporting estimate.

**Skills:** SQL, Java, React (the screen). **Size:** L. **Depends on:** step 0 and one agreement with the teammate who owns `backend/migrations/`. Can be split
between a backend person (database and API) and a React person (screen) once the API shape below is agreed.

## Brief to paste into Claude (database and API part)

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md` (rules, migration blocks and
> the fixed helper contract). Show me a short plan and wait for my OK before coding.
>
> Deliver, as migration `backend/migrations/003_stand_capacity.sql` mirrored byte for byte as `V9__stand_capacity.sql`:
> 1. Table `fogops.airport_capacity (iata char(3) primary key references airport, stands_assumed int check (>= 0), arrivals_per_hr_assumed int check (>= 0),
>    basis text not null, updated_by int references app_user, updated_at timestamptz not null default now())`. No seed numbers: nobody has supplied real
>    capacities, and we do not invent them.
> 2. Policy keys in `fogops.divert_policy` (the table already exists): `min_capacity_sample_hours` (hours of history needed before a history estimate is used;
>    value to propose in the plan, basis `ASSUMED`).
> 3. A function that estimates from `hist.flight` for an airport: peak arrivals per hour, and peak aircraft on the ground at once (arrival to the same
>    registration's next departure), plus the number of hours of history (`sample_n`). **Honesty rule:** a historical peak is a lower bound of what the airport
>    handled, not its limit; say so in `basis`.
> 4. The fixed helper `fogops.alt_stand_capacity(p_scenario_id int, p_iata char(3), p_at timestamptz) RETURNS TABLE (stands_total int, arrivals_per_hr int,
>    quality text, basis text, sample_n int)` with precedence: latest `airport_status_event.parking_available` at or before `p_at` (a person's current figure,
>    quality `MANUAL` or as stored) > `airport_capacity` (quality `ASSUMED`) > history estimate when `sample_n >= min_capacity_sample_hours` (quality
>    `ESTIMATED_FROM_HISTORY`) > NULL row (unknown, quality NULL). Do NOT change `rank_alternates`: WP-7 wires it in.
>
> Java package `fogops.capacity` (use `FogDb` for reads and `FogTx` for writes):
> - `GET /api/airports/capacity` returns one row per hub and alternate with the effective values, the quality and basis of each source (status event, configured,
>   history sample and peak), so the screen can show where each number comes from.
> - `PUT /api/airports/{iata}/capacity` body `{stands_assumed, arrivals_per_hr_assumed, basis}`: OCC or ADMIN only (403 otherwise), `basis` required (who or
>   what says so), values validated (0 to 200), audited (add one line to `AuditSummary`: "Set airport capacity").

## Brief to paste into Claude (React screen part)

> Read `hackathon-app/CLAUDE.md` first (MUI and theme tokens only, RTK Query in `features/ops/opsApi.js`, lazy pages, `npm run check`). Add a page "Airport
> capacity" (route in `src/routes/index.jsx`, menu in `src/config/navigation.jsx`): a table of the hub and alternates with the effective stands, arrivals per hour,
> a chip for the source (`Status entry`, `Assumed`, `From history`, `Unknown`), the history sample and peak, and an edit dialog (OCC and ADMIN only) with a
> required "basis" field. Show a clear note that a historical peak is a minimum, not a limit. Use the API above. Build with
> `cd hackathon-app && docker compose -f docker-compose.spring.yml up -d --build` if npm is not installed locally.

## Acceptance criteria

- The migration applies on a scratch copy of the database; the function returns the right precedence in each case (test with a status entry present, only a
  configured value, only history with enough hours, only history with too few hours, nothing). A table of expected results is in the pull request.
- History values for RKT and MCT are computed from `hist.flight` and can be reproduced with the SQL in the pull request; FJR, AAN, AUH and DWC are NOT used
  from history until their sample passes the policy threshold.
- API: `GET` works for any signed-in user, `PUT` only for OCC and ADMIN, every `PUT` is audited, invalid values give 422 with a string `detail`.
- The screen works in the browser against Spring on port 8888.
- `MigrationMirrorTest` passes. No crew mobile numbers anywhere. No invented capacity numbers in any migration.
