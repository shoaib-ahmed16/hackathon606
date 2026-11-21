# WP-7: Engine integration

**Why:** WP-4, WP-5 and WP-6 each deliver one read-only helper function with a fixed contract. This package is the only one allowed to change
`rank_alternates` and `propose_hold_or_divert`, so three people never overwrite each other's version of the same function. It also makes the new facts
visible in the flight drawer and deadlines.

**Skills:** SQL (plpgsql), Java. **Size:** L. **Depends on:** the helper contracts in `docs/work-packages/README.md`. It can start at once against stub
versions of the three functions (same signatures, fixed return values) and is merged last of the engine set.

## Brief to paste into Claude

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md`, then the current
> `rank_alternates` (migration `V8__rank_alternates_fuel_policy.sql`) and `propose_hold_or_divert` (in `V3__fogops_functions_triggers.sql`). Show me a short plan,
> including the weights, and wait for my OK before coding.
>
> Deliver migration `backend/migrations/006_engine_integration.sql` mirrored byte for byte as `V12__engine_integration.sql`:
> 1. **Stands (WP-4 helper `alt_stand_capacity`).** Where the latest status event has no `parking_available`, use the helper's `stands_total`; `stands_left` = total minus
>    diversions already occupying the alternate. A configured or history-based capacity is shown with its quality. If the capacity is unknown the alternate gets the
>    `verify` blocking constraint `STAND_CAPACITY_UNKNOWN` (never a silent "free"). `NO_PARKING` keeps blocking.
> 2. **Fuel (WP-5 helper `flight_fuel_outlook`).** When the flight has no entered fuel estimate with kg, use the outlook's fuel on board and burn (quality shown in
>    `fuel_basis`); an entered, manual or simulated value always wins. Show `fuel_at_dest_min_above_reserve` for landing at the hub (the "can it land at SHJ" answer)
>    in the HOLD option as well.
> 3. **Passengers (WP-6 helper `connection_risk`).** For each alternate use the option's estimated arrival at the hub after the return, or the diversion arrival, and for HOLD
>    the landing time after reopening. Expose `pax_at_risk` and `connections_at_risk` as new columns and as a reason line. Add a score factor whose weight lives in
>    `divert_policy` (propose a low default in the plan, for example 0.10, and rebalance so the weights still sum to 1). Passenger risk must never make an
>    alternate executable or non-executable by itself: it only orders options that are already feasible (safety and feasibility first).
> 4. **Same function name and arguments, new columns appended at the END** of the result (as V8 did) so existing callers keep working. Extend `score_breakdown` and
>    `reasons`. Leave the executability rules (blocking constraints) otherwise unchanged. Document every policy key and weight in `docs/engine-policy.md`.
>
> Java: in `console/ConsoleService.java` (you are the only package allowed to edit it) show the new facts in `/api/flights/{id}/detail` consequences, `/api/deadlines`
> reasons, and the flight detail `why` lines: stands source and number, fuel basis and margin, passengers at risk and tightest slack. Update the `askQuestions` facts note
> only if WP-3 has merged. Keep every existing key and line that the UI reads.

## Acceptance criteria

- With the three helpers merged, on a scratch copy: for twenty airborne flights, the old and new option lists differ only where a new fact applies, and each difference is
  explained in the pull request (stand unknown, fuel from history, passenger order).
- Executability is unchanged except for the new `verify` constraint on unknown stand capacity and nothing else; show a before and after table.
- Passenger weight at 0 reproduces the previous ranking exactly (test).
- The flight drawer in the browser shows the new lines; nothing the UI read before is missing (diff the JSON keys of `/api/flights/{id}/detail`, `/api/deadlines`,
  `/api/recommendations/options` before and after).
- The teammate who owns FastAPI is told these responses now differ on purpose: list them in the pull request (parity is no longer expected for them; add them to
  `tools/parity/deviations.json` if WP-0 has merged).
- `MigrationMirrorTest` passes, build passes, unit tests for the new text lines.
