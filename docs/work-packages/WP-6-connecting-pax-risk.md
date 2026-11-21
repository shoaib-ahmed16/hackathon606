# WP-6: Connecting-passenger risk

**Requirement:** "check the connecting pax info" before diverting, and how close their onward flights are.

**Today:** `pax_connection` holds inbound flight, outbound flight and a passenger count. The flight drawer shows "N connecting passengers affected" as information and the
recovery plan scores passengers at 15%, but the hold-or-divert ranking ignores them. There is no connection time in the table, but it can be derived: outbound departure
minus inbound arrival.

**Data warning:** a database loaded with the old loader has wrong passenger data (9,626 pairs, 5,059 reversed, 5,060 impossible). `db/fogops/fix_pax_connection.sql`
repairs it to 5,044 pairs and 31,454 pax. This package must be built and tested on repaired data.

**Skills:** SQL, Java. **Size:** M. **Depends on:** step 0, the passenger repair applied to the scratch copy used, and one agreement with the teammate who owns `backend/migrations/`.

## Brief to paste into Claude

> You are working on the FogOps Spring Boot backend. First read `CLAUDE.md` at the repo root and `docs/work-packages/README.md` (rules, migration blocks and the fixed
> helper contract). Show me a short plan and wait for my OK before coding.
>
> **Minimum connection time first.** Search the use-case document (`Crew Duty Recovery_Hackathon_Use Case 3.docx`), `backend/README.md` and the data folder for a minimum
> connection time. If none exists, do NOT invent one: store it as `divert_policy` key `min_connection_min` with quality `ASSUMED`, a clear `basis`, and ask me for the number
> to use (a value you propose in the plan is a proposal only). It must be changeable without a migration.
>
> Deliver migration `backend/migrations/005_connection_risk.sql` mirrored byte for byte as `V11__connection_risk.sql` with the fixed helper
> `fogops.connection_risk(p_scenario_id int, p_flight_id bigint, p_arrival_utc timestamptz) RETURNS TABLE (connections_total int, pax_total int, connections_at_risk int,
> pax_at_risk int, tightest_slack_min int, min_connection_min int, quality text, basis text)`:
> - Connections whose inbound flight is `p_flight_id` (and, for a recovery flight, its parent flight, as `build_recovery_plan` does).
> - Outbound departure in this scenario = actual departure, else estimated, else scheduled (`flight_state` then `flight`). Slack = outbound departure minus
>   `p_arrival_utc`. At risk when slack < the minimum connection time, or the outbound has already left.
> - Cancelled outbound flights are reported separately or excluded, say which in `basis`. Unknown data stays NULL.
> - Do NOT change `rank_alternates` or `propose_hold_or_divert`: WP-7 wires it in (including how much weight it gets).
>
> Java package `fogops.pax`: `GET /api/flights/{id}/connections?scenario_id=&arrival_utc=` returns the summary plus the list of connections (outbound flight number,
> departure, passengers, slack, at risk yes or no), most urgent first. No `ConsoleService` edits (WP-7 shows it in the flight detail).

## Acceptance criteria

- On a scratch copy with the repaired passenger table: totals for ten sample flights match a hand-written SQL check shown in the pull request.
- Moving `p_arrival_utc` later increases the passengers at risk monotonically (test on three flights).
- Changing `min_connection_min` in `divert_policy` changes the result without a migration.
- A flight with no connections returns zeros, an unknown flight returns 404 in the API, and null departure data does not crash (`quality` says it is unknown).
- The migration applies, `MigrationMirrorTest` passes, no invented minimum connection time is shipped as fact (it is `ASSUMED` until confirmed).
