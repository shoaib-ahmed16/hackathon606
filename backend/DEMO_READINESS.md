# FOOH demo readiness: findings, recommendations and checklist

## 0. Status of this check

| Area | How it was checked | Result |
|---|---|---|
| Live app http://130.61.182.207:8080/ | **Not reachable from Claude's sandbox** (network allowlist). Run `ui/e2e_smoke.py` on your side and share `results/` | Pending your run |
| Live database | Not reachable. Run `db/db_validation.sql` against it and share the output | Pending your run |
| Reference database (fogops_db, same files) | `db_validation.sql`: 66 checks | **66 / 66 PASS** (with 06/07 applied), 61 PASS + 1 WARN without 06/07 |
| Replay (final-challenge script) | `05_demo_fog_replay.sql`, run twice | 0 errors; outputs unchanged by the fixes |
| Test kit | `e2e_smoke.py` run against the v2 mockup | Works: 49 UI steps, 3 scripted flows pass, an intentional failure is caught |
| Your app's screenshots (G9822) | Manual review | 8 issues (section 1) |

## 1. Issues seen in your app (from the shared screenshots)

| # | What you see | Cause | Fix | Severity |
|---|---|---|---|---|
| 1 | G9822 crew margin **963 min**, "18 h 09 left" | Diversion evaluated at the app clock (20 Nov ~17:11Z) for a 21 Nov flight; crew time counted before sign-in | Deploy the latest `02_functions_triggers.sql` and `03_views.sql` (time-base rules TB-1 to TB-5). The UI shows "Duty starts HH:MMZ" when `duty_started = false` | **Blocker** |
| 2 | Deadline "passed 13 min ago (16:58Z)" while fuel shows 776 min and ETA is 08:23Z | Mixed clocks (browser/server "now" vs scenario clock) | Every countdown uses `scenario_now()` from the database (TB-5). Never `Date.now()` for business time | **Blocker** |
| 3 | G9822 shown **Airborne** a day before it departs | Status not derived from actual times, or state written directly | Derive status from ATD/OFF/ON/IN (`derive_flight_status`). Only `ingest_flight_event()` writes flight state. The validation check "no airborne flight before STD−2h" catches this | High |
| 4 | "Act now" lane but **Medium 35** severity | The severity formula's time factor ignores the fuel/decision deadline | Use the next deadline in the severity time factor (as the v2 mockup does) | Medium |
| 5 | "Hold not feasible: REOPENING_TIME_UNKNOWN" | No SHJ status/forecast entered in that scenario | Demo script step: OCC sets SHJ status + forecast reopening first. The UI shows "?" with "Enter reopening time" | Medium (demo) |
| 6 | Approval chips show `CREW_CONTROL · waiting` | Raw role codes | Display labels ("Crew Control"). Agree **one** approval policy: the v2 mockup says DIVERT = OCC + Crew Control; the 06 seed says OCC only | Medium |
| 7 | Rationale shows engine codes ("REOPENING_TIME_UNKNOWN", "P50/P90 of 89…") | Engine text shown verbatim | Map codes to plain words; keep the detail behind "Why?" | Low |
| 8 | Fuel "776 min*" | Unrealistic holding endurance accepted | Validate input (0–240 min above final reserve) and show the quality label | Low |

## 2. Database fixes made today (deploy before the demo)

| Fix | Effect | File |
|---|---|---|
| Time-base rules TB-1 to TB-5 + `duty_started` | No more 963-min margins or pre-sign-in countdowns | `sql/02_functions_triggers.sql`, `sql/03_views.sql` |
| `downstream_impact()` | Same-aircraft knock-on (e.g. A6-ATC: G9181/G9182/G9821) + crew next duty/rest | `sql/02_functions_triggers.sql` |
| Loader: no wrong-day matching; revised duty-sheet times link to the real flight | 26 duplicate flights removed; 4 duties no longer linked to the wrong day (margins of up to 1,870 min) | `loader/load_data.py` |
| Connecting pax direction and de-duplication (earlier) | 31,548 pax (not 60,147); correct direction | `loader/load_data.py` |
| 07 pins its function search_path | Functions behave the same for any caller | `sql/07_proposed_triggers.sql` |

**Deploying means a data reload** (`rebuild.sh`), which resets demo state.

1. Do it on a copy first.
2. Run `db_validation.sql`, then switch the app to the copy.
3. Keep a backup of the current database.

## 3. Recommendations before the demo

### Must
1. Deploy the database fixes (section 2) and run `db_validation.sql`. Expect **0 FAIL**.
2. **One clock.** The API returns `scenario_now()`. The UI shows the scenario clock in the header and uses it for every countdown. For the demo, use a REPLAY scenario with a fixed start (e.g. 21 Nov 01:15Z) so the numbers match the script.
3. **Demo reset button or script.** Clone LIVE into a fresh REPLAY, set the clock, inject the fog status. Rehearse it: any judge-driven change must be undoable.
4. Run `e2e_smoke.py` against the live URL: 0 console errors, 0 HTTP 4xx/5xx, no "NaN/undefined/Invalid Date".
5. Rehearse the brief's **3-minute test** with someone who hasn't seen the app (section 5).

### Should
6. Downstream impact section in the flight panel and in the consequence preview.
7. Plain-language rationale; role labels; "?" for missing reopening time and fuel.
8. Put the app behind HTTPS and a name (not a bare IP on :8080). At minimum, check the venue network can reach port 8080.
9. Fallback: the v2 mockup HTML opened locally, plus a screen recording of the full demo.

### Could
10. Apply 06/07 (multi-role approval, subscriptions, notifications, aeroMart outbox) if the UI uses them. Otherwise leave them out of the demo.
11. Severity uses the next deadline; tune the weights with OCC.

## 4. Demo flow checklist (tick on rehearsal)

| # | Flow | Steps | Expected | ✓ |
|---|---|---|---|---|
| 1 | Reset | Run the reset; open the app | Replay banner; clock at the script start; KPI bar populated | ☐ |
| 2 | Fog onset | OCC sets SHJ CLOSED, LVP, reopening forecast | Board re-sorts; briefing updates; alternates strip shows stands | ☐ |
| 3 | Feed | Inject an ETA change, a duplicate and a late message | Row updates once; duplicate ignored; old message doesn't overwrite | ☐ |
| 4 | Recommendation | Open a holding flight with low fuel | DIVERT #1 with plain reasons; blocked options with reasons; no 900+ min margins | ☐ |
| 5 | Missing data | Flight without fuel | "?" → enter value → options re-rank | ☐ |
| 6 | Propose → approve → execute | Dispatch proposes; approver(s) approve; OCC executes | Consequence preview (incl. downstream impact); recovery flight G9xxxD; +1 sector; latest legal departure shown | ☐ |
| 7 | Guardrail | Try to approve as Station, or as the AI | Refused with a clear message | ☐ |
| 8 | Crew timeout | Diverted crew past the legal limit | "Needs discretion"; standby candidates (LVP, roster-safe); swap → new latest departure | ☐ |
| 9 | Judge change: ETA | Change one inbound ETA | Row, recommendation and deadlines update; "changed because…" shown | ☐ |
| 10 | Judge change: reopening | Move SHJ reopening | Holds re-evaluated (hold → divert if buffer < 15 min) | ☐ |
| 11 | Judge change: crew pairing | Swap one crew member | Legality and latest departure recalculated | ☐ |
| 12 | Recovery | SHJ OPEN at 12/h | Ordered slots; infeasible flights parked with reasons (LVP, crew) | ☐ |
| 13 | Report | Generate report | Flights, decisions, approvals, timeline | ☐ |
| 14 | Mobile/station | Station view on a phone/tablet | Big buttons; no horizontal scroll | ☐ |

## 5. The 3-minute test (stranger, no help)

| Question | Where the answer must be | Pass if |
|---|---|---|
| Which crew runs out of legality next? | Next-deadline bar / crew lens | Answered in < 30 s, correct flight and time |
| Where is aircraft X and what is it waiting for? | Row text or Ask (⌘K) | Location and "waiting for" correct |
| What time must it leave to land legal? | Flight panel deadline | UTC + SHJ time, and the operational target |
| Alternate crew without impacting rosters? | "Find replacement" | Names a roster-safe, LVP-qualified candidate |

## 6. How to send me the results

1. `psql "$DSN" -f db/db_validation.sql > db_validation_report.txt`
2. `python ui/e2e_smoke.py --url http://130.61.182.207:8080/ --out results`, and with `--flows flows.json` once you've adapted the flow texts.
3. Zip `results/` (report.md, results.json, api_calls.csv, screenshots) together with `db_validation_report.txt` and upload them here. I'll turn them into a prioritised fix list.
