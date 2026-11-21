# FogOps: Product and Operations Guide

**One shared disruption room for OCC, Dispatch, Crew Control and Stations**

| | |
|---|---|
| Audience | Everyone on the team, plus business reviewers: product, operations, data and design |
| Companion document | `FogOps_Developer_Guide.md` (architecture, API, database, backlog) |
| Sources | The hackathon brief (Hack606, fog operations); the organizers' answers; the team discussion (Yashasvi, Datti, Omendra); analysis of the supplied data; what has been built so far (`fogops_db`, `fogops_console_mockup.html`) |

### Status labels

| Label | Meaning |
|---|---|
| **Built** | Working in the database and/or mockup today |
| **Partial** | Foundations exist, but the user-facing part is still to build |
| **MVP** | Agreed for the first release; not built yet |
| **Future** | Valuable, but after the MVP |

---

## 1. The product in one page

During the last disruption, people worked in a "firefighter" group chat:

- the data team posted which passengers were disrupted and which aircraft sat at which airport;
- managers asked questions, gave recommendations and coordinated by message.

It worked, but the facts, options and decisions were scattered across messages.

**FogOps turns that group chat into a product.** It is a single place where OCC and Flight Crew Operations (with Dispatch and the Stations) can:

1. **See** every affected flight in one list, ordered by how soon a decision is needed.
2. **Understand** each flight: crew legal time left, fuel, LVP qualification, alternate airports and their stands, and connecting passengers.
3. **Get a recommendation** from the AI, with the reasons and the 2nd and 3rd options.
4. **Decide and approve.** Humans decide; the right people approve; everyone sees it.
5. **Talk in context.** Each flight has its own timeline, comments and discussion, with alerts to Teams or email for people who aren't in the tool.
6. **Act in the systems of record.** One click opens the flight in aeroOps or the crew system with everything pre-selected; an approved decision can create the matching entry in aeroMart.

**Design stance.** This is our own product, built from first principles for the duty manager under time pressure. The AI prepares the facts and options. People stay responsible for every operational decision.

**MVP stance (agreed).** Keep it lightweight. Finish the core loop first: list → flight detail → recommendation → decision and approval → shared record. Integrations and notifications follow in phases.

---

## 2. Airline operations for newcomers

### 2.1 Who does what during a disruption

| Team | Main job in a disruption | Typical decisions |
|---|---|---|
| **OCC: Operations Control Centre** (Duty Operations Manager) | Owns the overall picture and coordinates every team. The final operational decision-maker on the ground | Approve diversions, delays, cancellations and the recovery order; open and close the disruption |
| **Flight Dispatch / Flight Watch** | Flight plans, fuel, alternates, weather and NOTAMs; monitors airborne flights | Propose hold or divert; choose the alternate; re-dispatch from the alternate |
| **Crew Control / Crew Tracking** (Flight Crew Operations) | Day-of-operation crew: who is on which flight and whether they are legal | Crew swaps, standby call-outs, replacement crew, recording commander discretion, hotels and transport for crew |
| **Crew Planning / Rostering** | Builds pairings and rosters weeks ahead | Usually not in the room; consulted when changes break future rosters |
| **Captain (Pilot in Command, PIC)** | Final authority for the safety of the flight in the air | Accepts or declines holding or diversion; decides on commander discretion |
| **Stations / Ground Operations** (incl. alternates such as RKT and FJR) | Handle the aircraft and passengers on the ground | Report landing, stands, fuel, passengers on board or off, readiness |
| **Maintenance Control (MCC)** | Aircraft serviceability | Confirm an aircraft can fly; approve aircraft swaps (future data) |
| **Customer Service / Reservations** (aeroMart) | Passengers | Re-protect connections, rebook, hotels and meals, notifications |
| **Network / Commercial** | Schedule and revenue impact | Which flights to protect, delay or cancel during recovery |
| **External: MET, Airport, ATC** | Weather, airport status, arrival rate | Declare LVP, close or reopen the runway, set arrival capacity |

### 2.2 Who has authority (the app must respect this)

- **In the air:** the Captain has final authority. OCC and Dispatch advise and coordinate. FogOps shows recommendations; it never instructs an aircraft.
- **On the ground:** OCC (the Duty Ops Manager) approves operational decisions. Dispatch and Crew Control propose within their areas.
- **Crew legality:** the approved FDP rules (supplied GCAA table) decide. Only the Captain can use commander discretion (up to +3 h). Crew Control records it, and it is normally reported afterwards.
- **FogOps never:** issues a clearance or diversion instruction, signs off crew legality, or invents a limit. Missing or conflicting data means "verification required", never "safe".

### 2.3 A fog disruption step by step

| Phase | What happens in real life | What FogOps does |
|---|---|---|
| **1. Before fog** | Met forecasts fog for the early morning. OCC watches arrivals in the fog window | Early warning: flags arrivals in the fog-prone window. **74% of 2026 SHJ diversions had arrival times between 00:00 and 03:59 UTC (04:00–07:59 SHJ).** Flags crews with thin margins, pilots without LVP and heavy connections |
| **2. Onset** | Visibility drops; the airport declares LVP; arrival rate falls or the airport closes | OCC records SHJ status, LVP and forecast reopening. Every exposed flight is reassessed |
| **3. Hold or divert** | For each inbound flight, Dispatch and the Captain weigh fuel against the reopening forecast. Only LVP-qualified crews can land under LVP | Ranks hold and every alternate with the reasons; Dispatch proposes, OCC approves; the recovery flight is created |
| **4. At the alternate** | The station handles the aircraft. Crew Control watches the crew clock; if the crew will time out, standby crew are positioned | Station updates (landed, refuelled, waiting for…); latest legal departure; replacement-crew finder |
| **5. Reopening and recovery** | Runway reopens at reduced capacity; aircraft are sequenced back; connections re-protected; rotations caught up | Recovery order within the capacity; connections at risk; flights that can't be scheduled, with reasons |
| **6. After** | Debrief and reports; discretion reports; lessons learned | One-click report from the shared timeline; history feeds the next forecast |

### 2.4 Key concepts

| Concept | Plain meaning |
|---|---|
| **Sector / leg** | One flight from A to B. A diversion adds a sector (DEL→RKT→SHJ instead of DEL→SHJ) |
| **FDP (Flight Duty Period)** | Crew working time from sign-in to engines-off of the last flight. Its maximum depends on crew type, the SHJ-local time of sign-in and the number of sectors (e.g. a captain signing in at 21:00 SHJ has 11:15 for 2 sectors, 10:30 for 3) |
| **Commander discretion** | The captain may extend FDP by up to 3 hours in unforeseen circumstances. It is a captain decision, never the plan |
| **LVP / RVR** | Low Visibility Procedures are declared when runway visual range (RVR) is low. **Both pilots must be LVP-qualified to land** (confirmed rule) |
| **Alternate** | A diversion airport. For SHJ: RKT, FJR, AAN, DWC, AUH, MCT |
| **Block time** | Gate-to-gate time. We use history, e.g. RKT→SHJ takes 52 min (90th percentile) |
| **Standby** | Crew on call who can replace a crew that has timed out |
| **Roster** | Each crew member's planned duties. A replacement must not break tomorrow's flights |
| **Connection / MCT** | Passengers changing flights at SHJ. Below the minimum connection time (40 min in our data) the connection is at risk |
| **Re-protection** | Rebooking passengers whose connection breaks (done in aeroMart) |
| **Recovery flight** | The flight from the alternate back to SHJ; we suffix it with D (G9588D RKT→SHJ) |

---

## 3. KPIs and data, by team

### 3.1 Top KPI bar (agreed in discussion)

These stay visible at all times above the flight list.

| KPI | Definition | Status |
|---|---|---|
| **Flights affected** | Flights in the disruption case that are airborne, holding, diverted or scheduled into the closure | Built (as a view) |
| **Passengers affected** | Passengers on board plus connecting passengers on affected flights. Today only connecting passengers are reliable, because on-board counts are missing for future flights in the rotation file | Partial: needs aeroMart bookings |
| **Severity** | 0–100 per flight. Blends: <br>• time to deadline (40) <br>• crew status (20) <br>• LVP block (15) <br>• connecting passengers (15) <br>• unverified data (10) <br>The case shows the count of high-severity flights | Built (first formula; to tune with OCC) |
| **Decisions pending** | Proposed decisions waiting for approval | Built |
| **Next deadline** | The most urgent of: fuel decision time, latest legal departure, crew legal end | Built (mockup); proposed database column |
| **Diverted / holding** | Aircraft currently at alternates or holding | Built |
| **Crew at risk** | Duties at risk, needing discretion or over the limit | Built |
| **Needs verification** | Flights with missing or conflicting data | Built |

On the replay at 02:45Z, the case shows:

| Measure | Value |
|---|---|
| Flights watched | 5 |
| Holding | 1 |
| Diverted | 2 |
| Crew at risk | 2 |
| LVP-blocked | 1 |
| Connecting passengers | 656 |

### 3.2 KPIs each team uses

| Team | KPI | Why it matters | Source | Status |
|---|---|---|---|---|
| **OCC** | Flights affected, cancelled, diverted | Size of the problem | Flight watch | Built |
| OCC | Time to decision (from flag to approval) | Speed of control; the brief's 3-minute test | Audit log | Partial |
| OCC | Delay minutes and reactionary delay | Knock-on to the rest of the day | Rotation + feed | Future |
| OCC | On-time performance during recovery | Recovery quality | Feed | Future |
| OCC | Time to normal operations (closure to backlog cleared) | Overall recovery | Recovery plan | Partial |
| **Dispatch** | Holding endurance left per flight (min) | Hold or divert | Fuel estimate | Built (entered or estimated) |
| Dispatch | Alternate stands free; alternate status | Where to send aircraft | Station status | Built (entered) |
| Dispatch | Fuel margin on arrival at each alternate | Safety of the diversion | Ranking engine | Built |
| **Crew Control** | Minutes to legal end per crew; crew at risk | Who times out next (Q1) | Legality engine | Built |
| Crew Control | Discretion used (count and minutes) | Reporting, fatigue | Decisions | Partial |
| Crew Control | Standby remaining by position, with LVP | Replacement capacity. Only about half of standby first officers hold LVP | Standby + qualifications | Partial |
| Crew Control | Rosters broken by replacements | Knock-on to future days | Roster check | Built (per candidate) |
| **Stations** | Aircraft on ground at the station; stands used | Space and handling | Diversions | Built |
| Stations | Time on ground at the alternate; waiting reason | Turnaround progress (history: median 139 min at FJR, 180 at RKT) | Diversions + history | Built |
| **Customer / Commercial** | Connecting passengers at risk or missed | Re-protection workload | Connection-risk view | Built |
| Customer / Commercial | Passengers rebooked, hotel/meal vouchers | Customer care | aeroMart | Future |
| **Recovery** | Arrivals per hour vs capacity; slots used in the window | Recovery throughput | Recovery plan | Built |
| **Data quality** | Feed freshness; open verification items | Trust in the screen | Feed freshness, exceptions | Built |

### 3.3 Data each decision needs

"Have" means it is in the supplied files. "Enter" means a person enters it in the app. "Integrate" means it comes from another system in production.

| Decision | Team | Data needed | Where it comes from |
|---|---|---|---|
| Hold or divert | Dispatch → OCC | Fuel endurance; SHJ status, forecast reopening and LVP; alternate status and stands; distance; crew legal end with +1 sector; pilot LVP | Enter: fuel and status. Have: crew, rules, history. Integrate later: fuel and weather feeds |
| Which alternate | Dispatch | Same as above, plus return block time and the alternate's history | Have: history. Enter: station status |
| Latest legal departure | Crew Control | Sign-in, crew type, sectors, FDP rule, return block time | Have |
| Replacement crew | Crew Control | Standby list, positions, LVP, roster (next days), positioning time, minimum rest | Have: standby and roster. Assumed: road times, 12 h rest |
| Commander discretion | Captain → Crew Control | Projected landing vs legal end, discretion end | Have (computed) |
| Delay at origin | OCC | ETA vs reopening, crew legality, connections | Have |
| Aircraft swap | OCC + MCC | 3-day rotation, aircraft location, serviceability | Have: rotation. Integrate: MCC |
| Recovery order | OCC / Recovery | Capacity, fuel, crew deadlines, rotations, connecting passengers | Enter: capacity. Have: the rest |
| Re-protect connections | Customer Service | Connections, projected connection time | Have. Integrate: aeroMart for rebooking |
| Close the case and report | OCC | Timeline, decisions, open items | Built |

---

## 4. Decisions and approvals

### 4.1 Decision catalogue and approval matrix

> **To confirm.** The client described the real approval flow in a recorded Q&A. That transcript isn't in this pack yet. The matrix below is our working proposal and is configurable in the app. Update it once the client's answer is transcribed. The team's direction was "decisions are approved by all relevant parties", which the multi-approver policy supports.

| Decision | Proposed by | Must approve | Informed | What happens on approval |
|---|---|---|---|---|
| **Divert** | Dispatch (or OCC) | OCC Duty Manager | Crew Control, alternate station, Customer Service; Captain via Dispatch | Recovery flight created; crew get +1 sector and are recalculated; station record opened; aeroMart entry created (integration) |
| **Hold** | Dispatch | OCC (or Dispatch if delegated) | Crew Control | Flight stays in the arrival sequence; fuel deadline tracked |
| **Delay at origin** | OCC / Dispatch | OCC | Origin station, Customer Service | New ETD in aeroOps (integration); crew recalculated |
| **Crew replacement** | Crew Control | Crew Control manager | OCC, station | Crew swapped; standby called out; new legality |
| **Commander discretion** | Captain (recorded by Crew Control) | Crew Control | OCC | Deadline extended up to +3 h; flagged for reporting |
| **Aircraft swap** | OCC / Network | OCC (+ MCC sign-off) | Dispatch, Crew Control, stations | Rotations updated (future) |
| **Recovery plan** | Recovery / OCC | OCC | All teams | Slot order published |
| **Custom rule (constraint)** | Any manager | Ops/Crew management | All | Rule active for its time window |
| **Override of the AI** | Anyone choosing a different option | Same as the decision | Same | Reason chip and text required; recorded as "not following AI" |

### 4.2 Decision lifecycle

```
PROPOSED ──approve(all required roles)──► APPROVED ──execute──► EXECUTED
    │                                          │                    │
    └──reject──► REJECTED                      └──revoke(reason)────┴──► REVOKED
```

These rules are enforced by the database:

- Only humans can propose or approve.
- Station users and the AI cannot approve.
- A decision's content can't be edited; you record a new decision instead.
- Every step is stamped with who, role, time and rationale.

### 4.3 Rules and governance

- **FDP limits** come only from the approved, versioned rule set. A new rulebook means a new version, approval, then automatic recalculation.
- **Custom rules** (from the discussion: "introduce a custom rule for some time frame, with priority") come in four kinds:

| Kind | Example | Effect |
|---|---|---|
| Filter | "Show flights where both pilots are not LVP-qualified" | Changes the view only; no approval needed |
| Alert | "Alert when crew margin < 45 min tonight" | Notifications only; no approval needed |
| Priority | "Medical flights first" | Changes sort and recovery weighting |
| Constraint | "Tonight, no crew beyond 10 h FDP" | May **only tighten** limits, never relax approved rules. Needs approval before it becomes active |

  Every custom rule has a valid-from/valid-to window and a priority.

---

## 5. The application: how it works

### 5.1 Design principles

1. One screen, one truth: the board is home, and flight detail opens beside it.
2. Sort by severity and time to decide, not by flight number.
3. **The decision area sits at the top of the flight panel, with recommendations below it** (agreed change; the current mockup shows the AI card first).
4. Unknown is never green: missing data shows a "?" with an action to fix it.
5. Every number can answer "Why?" by showing its calculation and inputs.
6. Countdowns for deadlines; UTC and SHJ local for absolute times.
7. Replay and what-if scenarios are framed in magenta and can't be confused with live.
8. Lightweight first: the MVP covers the core loop, and integrations are layered on.

### 5.2 Screen map

| Screen | Who | Purpose | Status |
|---|---|---|---|
| **Disruption board** (home) | All | KPI bar plus the flight list by severity and deadline, with filters | Built (mockup) |
| **Flight detail panel** | All | Decision area, AI options, crew, fuel, alternates, timeline, discussion, links | Built (mockup); layout change in MVP |
| **Approvals** | Approvers | Queue of proposed decisions with consequence previews | Built (mockup) |
| **Crew Control view** | Crew Control | Who times out next; replacement finder | Built (mockup) |
| **Station view** (tablet) | Stations | Big-button updates for aircraft at the station | Built (mockup) |
| **Recovery planner** | OCC / Recovery | Arrival slots after reopening; drag with feasibility checks | Built (mockup) |
| **Briefing and timeline** | All | "Since you last looked"; full case timeline | Built (overall); per-flight in MVP |
| **Ask (AI)** | All | Plain-language questions answered from live data | Built (mockup, scripted) |
| **What-if** | OCC | Compare scenarios side by side | Partial |
| **Rules and filters** | Managers | Saved filters, alerts, custom rules | MVP (filters); Future (constraints) |
| **Report** | OCC | Disruption report from the record | Built (database) |

### 5.3 Disruption board

- **KPI bar** (section 3.1): flights affected, passengers affected, severity, decisions pending, next deadline, diverted/holding, crew at risk, needs verification.
- **Flight list.** Grouped as Act now (< 15 min), Decide soon (15–45), Monitoring and Recovered. Within a group, sorted by deadline and then severity. Each row shows:
  - flight, route and registration;
  - **live status** (scheduled, airborne, holding, diverting, at the alternate, landed, recovered);
  - fuel and crew bars;
  - LVP badge;
  - AI chip;
  - countdown.
- **Filters** (discussion), all combinable and savable:
  - live status;
  - severity;
  - "pilots not LVP-qualified";
  - crew at risk;
  - needs verification;
  - diverted to X;
  - waiting for approval;
  - subscribed by me;
  - rule-based filters (custom rules).
- **LVP alert.** A flight whose captain or first officer isn't LVP-qualified while SHJ has LVP in force is flagged, with "must divert or wait for LVP cancellation". This is already enforced in the recommendation and recovery logic.

### 5.4 Flight detail panel (top to bottom)

1. **Header:** flight, route, registration, owner, last update, live status, the **Subscribe** button, and **Open in aeroOps / crew system / aeroMart** buttons (deep links with the flight pre-selected).
2. **Decision area (top).**
   - Who has proposed what.
   - Approval status per required role.
   - Buttons: approve or reject (approvers), propose (others).
   - The consequence preview: what will change if this is approved.
3. **AI recommendations (below the decision area).** Ranked options #1, #2, #3, each showing:
   - the action;
   - confidence;
   - the **rationale in plain words**, for example: *"RKT is the nearest open alternate with 2 stands free; the crew can still return to SHJ legally if they leave by 02:38Z (RKT→SHJ takes 52 min by history); fuel margin on arrival 17 min."*;
   - assumptions labelled forecast, estimated or measured;
   - blocked options with the reason ("AAN: no fuel"; "DWC: status not confirmed").
4. **Data gaps:** any missing input shows **?**. For example, "Fuel endurance not available. Ask crew / Enter value". Requests are tracked until answered, and the value is saved with a quality label.
5. **Deadline:** countdown with **Why this time?**, which shows the calculation chain.
6. **Crew:** a duty bar (sign-in, now, projected landing, legal end, discretion zone); limit, sectors, band and rule number; crew list with LVP badges; **Find replacement**.
7. **Fuel and alternates:** endurance and fuel margin per alternate; stands free; return block time.
8. **Flight briefing:** actions taken and comments for **this flight**. (The overall briefing exists; the per-flight view is MVP.)
9. **Discussion:** per-flight thread (questions, answers, recommendations, data requests), optionally mirrored to Teams.

### 5.5 How the AI recommends (plain words)

For each airborne flight, the engine compares **holding** with **every alternate**.

- **Hard checks.** Any failure makes an option non-executable, with the reason shown:
  - is the alternate open, with weather above minima?
  - are stands, fuel and handling available?
  - can the aircraft reach it on its fuel?
  - can the pilots land there under LVP?
  - is the crew still legal?
- **Unknown data blocks an option.** It is shown as "verify first", never as executable.
- **Scoring** of the options that pass: fuel margin (30%), crew outcome (30%), return time (15%), stands (10%), history (15%).

  The crew outcome is scored in this order:
  1. the crew can return legally;
  2. needs discretion;
  3. needs a replacement by road;
  4. needs a deadhead flight.
- **Hold policy.** Holding wins if it is feasible with at least 15 min of fuel to spare at landing.
- **Confidence** drops when inputs are estimated or forecast.
- **Commander discretion** appears as an explicit option (e.g. "depart under discretion by 05:38Z"). It is never assumed.
- **When something changes** (ETA, reopening time, crew), the recommendation is regenerated. The old one is kept and the change is announced ("Hold → Divert FJR because…").

### 5.6 Collaboration and notifications

| Feature | Description | Status |
|---|---|---|
| Overall briefing | "Since you last looked": what changed, what's urgent, who decided what | Built (mockup) |
| Per-flight timeline | Every event, decision, comment and station update for the flight | Built (database); MVP (UI) |
| Per-flight discussion | Questions, answers and recommendations in context | MVP |
| **Subscribe to a flight** | E.g. a medical emergency: everyone who subscribes is alerted on every update | MVP (in-app); Future (Teams/email) |
| Teams / email alerts | Push key events (decisions, approvals, deadlines, data requests) to a Teams channel or email, for people without portal access | Future (needs Teams webhook/Graph access) |
| Role and recipient rules | Per flight or decision type: who must be notified | MVP |

### 5.7 Integrations (phased)

| Integration | What it does | Phase |
|---|---|---|
| **Deep links** to aeroOps, the crew system and aeroMart | "Open in aeroOps" opens the selected flight directly; parameters (flight number, date, departure, arrival, registration) are passed in the link, so nobody re-selects | MVP (templates ready) |
| **aeroMart entry on decision** | An approved and executed diversion (e.g. to RKT) creates the corresponding entry automatically, via an outbox with retry and a manual fallback | Future (needs the API) |
| **Teams** | Alerts and discussion mirrored to a channel | Future |
| **Live feeds** (movements, fuel, weather) | Replace manual entry and simulated data | Future |

> System names were heard on the call as "aeroMart", "aeroOps" and "aeroLine" (crew). Confirm the exact product names and which one handles crew management.

---

## 6. Key flows

The full catalogue of 29 flows is in the developer guide; these are the ones every user meets.

**F1. Fog onset → triage**
1. OCC sets SHJ to Closed, with LVP in force and reopening forecast at 02:30Z.
2. All exposed flights are recalculated.
3. The board reorders by deadline.
4. The briefing summarises the changes.

**F2. Hold or divert**
1. Dispatch opens the flight.
2. The AI shows #1 Divert RKT with its reasons.
3. Dispatch proposes it (or overrides with a reason).
4. OCC sees the consequence preview and approves.
5. On execution:
   - the recovery flight G9xxxD is created;
   - the crew get +1 sector and are recalculated;
   - the station and subscribers are notified;
   - the aeroMart entry is queued.

**F3. Missing data**
1. The AI cannot rank options because fuel is unknown, so the options show "verify".
2. Dispatch clicks **?** → "Ask crew".
3. The fuel is entered with its source (crew-reported).
4. The options are re-ranked.

**F4. Crew will time out at the alternate**
1. Crew Control sees "needs discretion" on the duty bar.
2. **Find replacement** shows standby crew who are legal, LVP-qualified and roster-safe.
3. Crew Control proposes the replacement and the Crew Control manager approves it.
4. The crew are swapped and the new latest departure is shown.
   *Alternative:* the Captain agrees to discretion, Crew Control records it, and the deadline is extended.

**F5. Station updates**
1. The RKT station taps Landed, On blocks, Refuel done or Crew arrived.
2. OCC sees what the aircraft is waiting for.

**F6. Watch a critical flight**
1. Anyone subscribes, for example to a medical emergency flight.
2. Every update reaches the subscribers in the app (and later in Teams or email).

**F7. Reopening and recovery**
1. SHJ opens at 12 arrivals per hour.
2. The recovery planner proposes the order, and flights that can't be scheduled are set aside with reasons (e.g. "captain not LVP").
3. OCC adjusts and approves the plan.
4. Connections at risk are listed for re-protection.

**F8. Close and report**
1. Open items are reviewed.
2. The report is generated from the timeline.
3. The case is closed.

---

## 7. Built today, MVP and future

| Capability | Today | MVP | Future |
|---|---|---|---|
| Data model, legality engine, latest departure, LVP, alternate ranking, recovery plan, audit, replay | **Built** (database, tested) | Serve through the API | |
| Clickable UI concept (board, panel, approvals, crew, station, recovery, Ask, what-if) | **Built** (mockup) | Build in the real frontend; **decision area above recommendations** | |
| KPI bar, severity score | Validated views | Ship, then tune the weights with OCC | Learned severity from history |
| Filters (status, LVP, severity, risk) | | **MVP** | Saved and shared filters |
| Per-flight briefing, discussion, subscriptions | Timeline built | **MVP** (in-app) | Teams/email mirroring |
| "?" data requests | Exceptions built | **MVP** | Auto-request through ACARS/crew messaging |
| Multi-role approval policy | Single approval built | **MVP** | Delegation, escalation timers |
| Deep links to aeroOps, crew system, aeroMart | Templates validated | **MVP** | |
| Custom rules (filter, alert, priority) | | **MVP** | Constraint rules with approval |
| aeroMart entry on decision; Teams; live feeds | | | **Future** |
| Aircraft swap, hold at origin, connection actions, early warning | Data available | | **Future** |

---

## 8. Data: what we have, simulate or need

| Item | Today | Production source |
|---|---|---|
| Flights, rotations, actual times | Two OCC snapshots (20–23 Nov), replayed as a feed | Live movement feed (aeroOps) |
| Crew duties, sign-in, LVP, standby | Duty sheets 20–23 Nov | Crew system |
| Roster (10 days, SHJ local) | Supplied | Crew system |
| FDP rules | Crew_FDTL (approved v1); SHJ-local bands confirmed | Versioned rulebook |
| Connecting passengers | Supplied. Two views per connection, normalised to 5,061 connections and 31,548 passengers | aeroMart |
| Passengers on board | **Mostly missing** (only 60 of 887 flights have a count) | aeroMart bookings / check-in |
| Fuel endurance | Entered or estimated from history | ACARS / flight-planning system |
| Weather, LVP, reopening | Entered by OCC | Met / airport feed |
| Alternate status and stands | Entered by stations | Station systems |
| History (diversions, block and ground times, fuel) | Jan–Nov 2026 | Data warehouse |

---

## 9. Open questions

1. **Approval flow:** transcribe the client's answer from the recorded Q&A and update section 4.1.
2. **System names and APIs:** confirm aeroMart, aeroOps and the crew system; deep-link URL formats; whether an API exists to create diversion entries.
3. **Teams:** is a channel webhook allowed? Which channel? Who receives alerts?
4. **Access:** which managers get portal access, and which roles are only informed through Teams or email?
5. **Severity weights:** agree the formula with OCC.
6. **Crew rules not supplied:** limits for SO, SEC and EN crew; minimum rest; acclimatisation for outstation starts; whether the Second Officer needs LVP.
7. **Standby timezone; meaning of PTD/PTA; 0-leg FDP rows.**

---

## 10. Glossary

| Term | Meaning |
|---|---|
| ACARS | Datalink messaging between aircraft and the airline |
| AT_RISK | Crew margin under 60 min, or connection under 40 min |
| Case | One disruption event (e.g. "SHJ fog 21 Nov") |
| Consequence preview | What will change if the decision is approved |
| Deep link | A URL that opens another system on the selected flight |
| IROPS | Irregular operations, i.e. disruption management |
| MCC | Maintenance Control Centre |
| OCC | Operations Control Centre |
| PIC | Pilot in Command (the Captain) |
| Recovery flight | The alternate→SHJ flight created on diversion (suffix D) |
| Scenario | LIVE, REPLAY or WHAT-IF copy of the operation |
| Verification required | Data is missing or conflicting, so no legal or safe claim is made |
