# WP-5: Fuel estimate from history and fuel outlook

**Requirements:** "FOB and fuel burn to calculate the available fuel for the next leg or leg + 1 extra (diversion)" and "check the historical fuel burn or
available fuel info from the flight legs to decide whether you can land with the available fuel in SHJ or other alternate airports in UAE".

**Today:** the engine (V8) already compares fuel on board (kg) and the hold burn rate with the diversion leg time plus the 30-minute final reserve, but only when a
fuel estimate row has those values. The real database has none, and `hist.fuel` (65,922 rows, 61,273 plausible, 63,534 joinable to `hist.flight`, median burn about
2,485 kg/h over 58,564 plausible legs) is not read by any function. Teammate's `/api/feed/push` writes `SIMULATED` fuel with its own formula; that must keep working.

**Interpretation to confirm with whoever wrote the requirement:** "next leg" = the leg being flown (landing at SHJ); "leg + 1" = the extra diversion leg to an alternate.

**Skills:** SQL, Java, data analysis. **Size:** L. **Depends on:** step 0 and one agreement with the teammate who owns `backend/migrations/`.

## Brief to paste into Claude

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md` (rules, migration blocks and the
> fixed helper contract). Show me a short plan and wait for my OK before coding.
>
> **Step 1, understand the data (report before you build).** Read the data description in `backend/README.md` and `hackathonTeamYashasvi/db/fogops/README.md`,
> then check on a scratch copy what `hist.fuel.remaining_fuel`, `fuel_onboard_departure`, `fuel_uplift_departure`, `minimum_fuel` and `density` mean (compare with
> block time from `hist.flight`). State your conclusion and every assumption. If the meaning of a column cannot be established from the documents, ask me; do not
> guess. Average burn over a whole block is not hold burn: say how you treat the difference.
>
> **Step 2, migration** `backend/migrations/004_fuel_burn_reference.sql` mirrored byte for byte as `V10__fuel_burn_reference.sql`:
> - `fogops.fuel_burn_reference` (route and fleet-wide fallback, burn kg/h p50 and p90, sample size, source `HISTORICAL` or `ESTIMATED`) built by a
>   `fogops.refresh_fuel_burn_reference()` function from plausible `hist.fuel` rows joined to `hist.flight`; call it at the end of the migration and add a call
>   to the loader's `post_load` (like `refresh_leg_time_reference`). Pairs with too few samples fall back to the fleet figure and are tagged.
> - The fixed helper `fogops.flight_fuel_outlook(p_scenario_id int, p_flight_id bigint, p_at timestamptz) RETURNS TABLE (fuel_on_board_kg numeric,
>   burn_kg_per_hr numeric, hold_minutes numeric, quality text, basis text, fuel_at_dest_min_above_reserve int, dest_iata char(3), remaining_flight_min int)`.
>   Precedence: the latest `flight_fuel_estimate` row that has `fuel_on_board_kg` (keep its stored quality, burn it down to `p_at`) > a history-based
>   estimate for an airborne flight with a known take-off (planned departure fuel less route burn since take-off, quality `ESTIMATED_FROM_HISTORY`) > NULL.
>   It must NEVER override or replace an entered, manual or simulated row. `fuel_at_dest_min_above_reserve` = hold minutes minus remaining flight minutes to
>   the destination minus `divert_policy.final_reserve_min` (30). Not airborne or no take-off time: NULLs, not guesses. Do NOT change `rank_alternates`: WP-7 wires it in.
>
> **Step 3, Java** (`fogops.fuel`, `FogDb` reads): `GET /api/flights/{id}/fuel?scenario_id=` returns the outlook, with quality and basis, 404 for an unknown flight.
> Do not edit `ConsoleService` (WP-7 shows it in the flight detail).

## Acceptance criteria

- A written data note in the pull request: what each `hist.fuel` column means, how many rows were usable and why the rest were not, the burn p50 and p90 overall and for
  the busiest routes, the assumptions, each labelled `ASSUMED` where it is one.
- On a scratch copy: an airborne flight with no estimate gets an `ESTIMATED_FROM_HISTORY` outlook; the same flight after `/api/feed/push` or a manual entry shows
  that row's quality instead (history never overrides); a flight on the ground gets NULLs; a flight whose route has no history uses the fleet figure and says so in `basis`.
- Cross-check a sample of 20 historical legs: the estimated burn minus the actual burn distribution (median and p90 error) is reported.
- The migration applies on a scratch copy, `MigrationMirrorTest` passes, the loader change is checked on an empty scratch database (loader run end to end).
- No crew mobile numbers; every number carries its quality label; the function is `STABLE` and read-only.
