# FOOH! Console: Knowledge Transfer (Business View)

This guide explains **what the screens do and why**, in plain language. It has no code. It is for operations people, product owners, judges and new team members who need to understand the product quickly.

---

## 1. What this product is

When fog closes or restricts Sharjah (SHJ) airport, aircraft are held in the air or diverted to other airports, and crews may run out of legal duty hours. Operations staff have to decide, quickly and correctly, **who holds, who diverts, who gets replaced, and in what order aircraft land once the airport reopens**.

The FOOH! Console puts the facts for those decisions on one screen:

- which flights are affected and how much time is left for each,
- whether the fuel and the crew still allow waiting,
- what the system recommends, and why,
- who approved what, and when (a permanent record).

**The principle:** the system *recommends and explains*. **People decide.** Nothing important happens without a named person recording it, and risky choices need a second person with the right role to approve.

---

## 2. The five pages (left menu)

| Page | What it is for |
|---|---|
| **Console** | The control room: urgent flights, role-based views, the next deadline, a "what changed" briefing, and the what-if tool. |
| **Flights** | The full table of every flight on the case, with filters and sorting. |
| **Audit trail** | The permanent record of who did what, when, and with what result. |
| **Alerts & data** | Data problems and "please verify" items. Anything unverified is shown here instead of being guessed. |
| **Reports** | Decision counts, the decision log, and report generation. |

Everything requires login. The top right shows who you are. Your name and role are attached to every decision, approval and comment you make.

---

## 3. The header you see on every page

- **Case picker.** Pick which disruption case you are looking at. The newest case opens first and your choice is remembered. Each entry shows its type: **LIVE**, **REPLAY** or **WHAT-IF** (see section 7).
- **Airport status (SHJ).** Open, Restricted or Closed. A badge shows when **low-visibility procedures (LVP)** are in force, with the visibility in metres, the expected reopening time and how many arrivals per hour are allowed.
- **Alternate airports.** One chip per diversion airport:
  - **Green:** usable (open, with stands available).
  - **Red:** closed, restricted or out of fuel.
  - **Grey "?":** nobody has entered a status. The system will **not** treat that airport as usable until someone confirms it.
- **Clock.** A large UTC clock, with Sharjah local time beside it. See section 8 for exactly what "now" means.
- **Approvals button.** Shows how many decisions are waiting for approval.
- **Ask button** (shortcut Ctrl+K). Ask questions in plain English (section 9).
- **New case**, and for OCC and Admin users a **case menu** (close, delete, move the reopening forecast 30 minutes earlier or later).
- If the case is not LIVE, the header turns amber and says **"nothing here affects live operations"**.

---

## 4. The Console page

### 4.1 Top bar
- **Next deadline:** the most urgent time on the whole case, with a live countdown, the flight and the reason. If everything is overdue, it says **Overdue**.
- An amber warning appears when some flights **cannot show a deadline because fuel has not been reported**.
- **"Since you last looked"** toggles the Briefing panel (4.2).
- **Role lens** (OCC, Dispatch, Crew Control, Station, Recovery): switches the page to the view that role needs (4.3 to 4.6). These are *views*, not locks: anyone can switch.
- **What if...** opens the what-if tool (section 7).
- **Data sources:** shows small yellow tags on each block naming the database view behind it. Meant for judges and engineers who want to see where a number comes from.

### 4.2 Briefing: "what changed since I last looked"
A short list of recent decisions, status changes, diversions and comments, with the time and the person. Use it at shift handover or when returning to the screen.

### 4.3 OCC and Dispatch lens: the flight board
Flights are sorted into lanes by **how much time is left before the flight's next hard deadline**:

| Lane | Meaning |
|---|---|
| **Act now** | Less than 15 minutes left, or already passed. |
| **Decide soon** | 15 to 45 minutes left, or the deadline is unknown (needs checking). |
| **Monitoring** | More than 45 minutes left, or no deadline. |
| **Arrived / recovered** | Landed or on blocks. Collapsed by default. (Hidden in the Dispatch lens.) |

Each flight row shows:

- **Flight number and date**, route (the diversion airport if diverted) and the aircraft tail.
- **Status** and either what the aircraft is waiting for or its estimated arrival, and how old the latest data is.
- **Fuel meter:** minutes of holding fuel left. Green is 45 minutes or more, amber under 45, red under 20. **"? verify"** means no fuel figure was entered. This is **never treated as safe**. "On ground" applies once landed or diverted.
- **Crew meter:** time left before the crew's legal duty limit. Green is 60 minutes or more, amber under 60, red when the limit is already passed ("Needs discretion").
- **LVP chip:** only shown when low-visibility procedures apply at the destination: ✓ crew qualified, ✕ not qualified, ? unknown.
- **System recommendation or decision state**, for example "Engine: divert XXX" or "Waiting for approval: divert".
- **Deadline countdown**, or "Verify fuel" when it cannot be calculated.

**Finding things:** search by flight, tail, airport or captain; filter by owner; and use the quick filters *Needs approval*, *Crew at risk*, *No LVP*, *Fuel unverified*, *Holding*, *Diverted*. Click a row to open the **Flight drawer** (section 5).

### 4.4 Crew Control lens: "who runs out of legality next"
One row per crew duty, soonest legal end first. It shows the legs flown, who the most limited crew member is, the maximum duty length, a countdown, and a red flag if a pilot is **not LVP-qualified**. Buttons: **Open** the flight, or **Find replacement** (the standby search, section 6.2).

The small timeline bar reads like this: green is time already used, the red line is the legal end, the blue line is now, and the hatched area is the **commander's discretion zone** (up to 3 extra hours, a captain's decision). Crew types without approved duty rules show **Verify** and are never treated as legal.

### 4.5 Station lens: for the ground team at an alternate airport
Built for a tablet. The user picks their station and sees each aircraft diverted there, with a clear instruction such as *"OCC needs: confirm the aircraft is ready. It must leave by HH:MMZ."* Large buttons record progress: **Landed, On blocks, Refuel done, Passengers on board, Passengers disembarked, Crew arrived, Ready to depart, Add a note.**

Every tap updates the diversion record **and** posts a message to the case timeline for OCC, with the time and the user's name.

### 4.6 Recovery lens: landing order after the airport reopens
- Click **Build recovery plan** and the system sequences arrivals into slots, spaced by the airport's arrivals-per-hour capacity.
- Four cards show: when the hub reopens, arrival capacity, flights in the plan, and how many fit inside the window.
- **Drag a flight to a different slot** to adjust. The system refuses impossible moves (a slot earlier than the aircraft can arrive, or one already taken) and says why.
- Flights that cannot be sequenced are listed separately with the reason.
- **Approve plan** (while it is proposed) lets Stations and Dispatch act on it. **Ask the engine to re-sequence** recalculates.

---

## 5. The Flight drawer (click any flight)

This is where one flight is understood and decided. From top to bottom:

1. **Header:** flight, tail, **date**, status, route, captain.
2. **LVP alerts:** a red banner if a named pilot is not qualified for low-visibility landing; amber if pilots are not linked to the leg and need checking.
3. **Deadline:** the countdown, in both UTC and SHJ time, with a **"Why this time?"** button that lists the reasoning step by step.
4. **Flight facts:** scheduled and estimated departure and arrival, delay, fog exposure, what the aircraft is waiting for, data age, owner. Buttons to nudge the arrival estimate by +15, +30 or -15 minutes (a simulated feed update).
5. **Hold fuel:** the current figure and its quality. You can type a fuel-endurance estimate yourself; it is saved as *manual* and the recommendations re-rank.
6. **Crew legality:** status, the limiting crew member, legs counted, legal duty end, **the end with commander's discretion (+3 hours)**, the latest legal departure time and the operational target. A warning appears if there are open data problems: *"Treat legality as unverified."*
7. **Ranked options and the decision:**
   - Each option (for example "Hold at SHJ" or "Divert to XXX") shows a rank, **Executable** or **Blocked**, a score, fuel margin, crew margin, arrival time and the reasons it is blocked.
   - For a diversion, the reasons also say **how long the flight to that alternate takes** (typical and conservative, from real 2026 flights), **how much fuel is left on arrival above the 30-minute legal final reserve**, **the latest time to leave the hold** for that alternate, and **when the aircraft would be back at SHJ**. See section 16.
   - **Assumption chips** show how trustworthy each input is: *Measured* (green), *Forecast or Estimated* (amber), *Simulated or Assumed* (blue), *Manual* (grey).
   - A **"What will happen" preview** lists the consequences of choosing an option (✓ fine, ! caution, ✕ problem, ? verify).
8. **Recording a decision:** choose the type (Hold, Divert, Recover, Cancel, Delay, Crew replace, Commander's discretion, Aircraft swap, Override, Other) and **write a rationale (required)**.
   - If you choose something other than the system's #1 recommendation, it is recorded as an **override** and you must pick a reason: *Station capacity, ATC restriction, Crew preference, Commercial / connections, Fuel information, or Other*.
   - The decision starts as **Proposed**.
9. **After a decision exists:** a banner shows it. While Proposed, an authorised person can **Approve** or **Reject**. Once approved, **Execute diversion** or **Execute crew swap** carries it out and recalculates crew legality.
10. **Station update** (diverted flights): update what the aircraft is waiting for, its status and the refuel state.
11. **Standby cover:** up to five standby crew candidates (read-only here).
12. **History, comments and activity:** every decision with its approvals, a shared comment thread, and the latest audit entries for this flight.

---

## 6. Decisions, approvals and crew replacement

### 6.1 How a decision flows
1. The system recommends (and explains).
2. A person **proposes** a decision with a written reason.
3. A person with an **approver role** approves or rejects. The approval rule is enforced by the database; if your role is not allowed, you see a clear refusal.
4. A person **executes** it (for example the diversion), and the effects are recalculated.
5. Everything is in the **audit trail**.

The **Approvals** button in the header lists every decision waiting for approval, with who proposed it and whether it *matches* or *differs from* the system's recommendation. **Review and approve** opens the flight.

### 6.2 Replacing a crew member
From Crew Control, **Find replacement** checks standby crew for rest, roster conflicts, LVP qualification and positioning time, and lists a verdict for each. **Propose swap** is only enabled when the verdict is exactly **CANDIDATE**. It creates a *Proposed* crew-replace decision, which must then be approved and executed in the flight drawer. Nobody can swap crew without an approved decision.

---

## 7. Cases and scenarios

| Type | Meaning |
|---|---|
| **LIVE** | The real operational picture. |
| **REPLAY** | A recorded fog event replayed for practice or demonstration. Shown as SIMULATED. |
| **WHAT-IF** | A separate copy created to test a question. It never changes live operations. |

**Creating a case ("New case"):** choose an airport (default SHJ), a time window (entered in Dubai time, default the whole day), an optional title, and optionally **Simulate fog at this airport** (with "Fog clears after N minutes"). The case's **watch list** is every scheduled flight arriving at that airport in the window, with its real crew and legality. The result is *"Case created with N flights, M recommendations"*.

**Closing and deleting:** *Close* keeps all history. *Delete* is only possible if nobody has decided or commented on the case.

**What-if ("What if SHJ stays closed longer?"):** a slider moves the reopening forecast from 1 hour earlier to 4 hours later (default +60 minutes; if the airport is open it asks "close it again for"). The system runs its full logic in a separate copy and shows **how many flights' advice changes** and a Flight / Now / What-if table. **Open this scenario** switches the console to the copy. Live operations are untouched.

---

## 8. Dates and times: what you are looking at

- All stored times are **UTC**. Screens show **UTC (marked Z)** and, in most places, **Sharjah local time (UTC+4, no daylight saving)** next to it, for example `21 Nov 01:55Z / 05:55 SHJ`. The Sharjah date is added only when it differs from the UTC date.
- **Flights always show their date** (for example "21 Nov") on the board, the Flights table, the flight drawer, the Station lens and the Recovery tiles. The date is the flight's scheduled arrival date in UTC.
- **"Now" is the scenario clock, not necessarily the real clock.** The demo data uses a fixed stored time that then ticks forward from when you opened the page: the live demo scenario starts at **20 Nov 2026 16:45Z** and the fog replay at **21 Nov 2026 02:45Z**. All countdowns and "passed ... ago" labels use this clock, so they are consistent with the data. "Data refreshed N s ago" uses the real wall clock.
- **Countdown colours:** red under 15 minutes, amber under 45, green above. "Verify" means there is no target to count down to.

---

## 9. The Ask assistant (Ctrl+K)

- **Suggested questions** are answered **directly from the data**, with the source named. They cost nothing and are always available. Examples: *which crew runs out of legality next, what is the next deadline, where is an aircraft, what time must a flight leave, who can replace a captain, what is waiting for approval, summarise the situation, draft a message to a station.* Typing just a flight number or tail also gives a status card.
- **Free-text questions** are sent to an AI only when the server has an API key. The AI is given **only this case's data**, so it cannot invent flights, times or crew. It may say it does not have the information.
- **Cost controls (set up on the server):** a cheaper model, short answers, repeated questions answered from memory, a limit per user per minute and a daily limit.
- **Read-only:** the assistant cannot approve, decide or change anything. Every question is recorded in the audit trail.

---

## 10. Alerts, audit and reports

- **Alerts & data:** data-quality and "verification required" items, filterable by severity: **Blocking** (red), **Warning** (amber), **Info** (blue). Nothing unverified is hidden or assumed to be fine.
- **Audit trail:** a permanent, read-only record of every action (including refused attempts and Ask questions) and every data change, with who, when and the outcome (**OK** or **Refused**). Filter by who, search, limit to this case, switch machine activity on or off, expand a row to see before and after values, and **Export CSV**.
- **Reports:** counters for decisions, approved/executed, pending approval and open exceptions; **Export decision log (CSV)**; **Generate report**, which stores a reproducible report in the database. Below are the decision table and the case timeline.

---

## 11. Colour and status meanings

| Colour | General meaning |
|---|---|
| Red | Act now, illegal, blocked, closed. |
| Amber | Tight margin, waiting, needs a check or approval. |
| Green | Fine, legal, feasible, open. |
| Blue / grey | Information, or finished. |

**Crew legality:** *Legal* (green); *At risk* (amber); *Discretion needed* (amber: the legal limit is passed but the commander may extend by up to 3 hours); *Exceeded* (red); *Verify* (amber: not enough verified data, so it is **never treated as legal**).

**Decision status:** *Proposed* (waiting for an approver); *Approved* and *Executed* (done); *Rejected, Revoked, Superseded, Expired* (closed).

**Flight status:** Scheduled, Taxi out, Airborne, Holding, Diverting, Landed, On blocks, Cancelled.

**Recommendation types:** Hold, Divert, Monitor, Recover, Replace crew, Delay departure, No action.

---

## 12. Glossary

| Term | Meaning |
|---|---|
| **LVP** | Low-visibility procedures. Only specially qualified pilots may land under them. |
| **FDP / FDP margin** | Flight duty period; the margin is the minutes left before the crew's duty legally ends. |
| **Latest legal off-blocks** | The last time the aircraft can leave the gate and still keep the crew legal. |
| **Operational target** | The planned departure time. |
| **Commander's discretion** | The captain may extend the duty by up to 3 hours. It is a human decision, never automatic. |
| **Hub** | The main airport of the case (SHJ). |
| **Alternate** | A diversion airport. |
| **Standby crew** | Crew held in reserve who can replace someone. |
| **Case** | One disruption being managed, with its watch list of flights. |
| **Scenario** | The data world a case lives in: LIVE, REPLAY or WHAT-IF. |
| **OCC** | Operations Control Centre. |

---

## 13. Who can do what

- Everyone signs in with a username and password; the demo users include OCC, Dispatch, Crew Control, Recovery, Admin and station users.
- On screen, only **OCC and Admin** see the case menu (close, delete, move the reopening forecast).
- **Approvals and executions are enforced by the database**, not the screen. The flight drawer shows the approver role required, and any refusal appears as a clear message.
- Role lenses change what is emphasised; they do not restrict access.

---

## 14. Known limits and open questions (good to know before a demo)

1. **The what-if needs airport status data.** The live demo scenario currently has **no airport-status entries for SHJ**, so "What if..." returns *"SHJ has no airport status in this scenario"* on LIVE cases. It works on the fog replay case. This needs data (or a backend change) before being shown on live cases.
2. **"Now" is simulated** in the demo data (section 8), so it will not match a wall clock.
3. **Which role may approve which decision type** is not visible from the screens. It is enforced in the database; confirm the rules with the business owner.
4. **Feed freshness** is shown per flight ("data N min old", "no live feed"), but there is no single screen listing every data feed's freshness.
5. **Crew duty times in local time** are stored without a time zone in one part of the data; confirm they are not shown directly anywhere without conversion.
6. **Unused or template parts.** A four-card summary (next crew expiry, aircraft locator, latest-legal departure, standby crew) exists in the code but is not on any screen. The pages *Posts* and *Realtime* are starter-kit demos, not part of the operations product, and are not in the menu.
7. **Fuel unknown is never "safe".** Where fuel or crew data is missing, the screens say *verify*, and the system will not mark such flights as legal or executable. This is deliberate.
8. **Database changes no longer need a dump and restore.** Changes are numbered files applied automatically when the API starts. The current level shows in the API health check. Engineers: see `backend/README.md`.
9. **The new diversion details (bingo time, return-to-SHJ arrival, flight-time basis) are in the data but not yet shown as their own fields in the flight drawer;** they appear in the option's reasons text.
10. **Two local databases exist** (one for the full stack, one from `backend/docker-compose.yml`) with separate data. Check which one you are looking at.

---

## 15. Where the data comes from

- **Everything comes from the supplied Excel files**: the OCC flight rotation (two snapshots), crew duty sheets, crew roster, the FDP rules table, connecting passengers, historical flights (Jan to Nov 2026) and historical fuel.
- **Simulated data is allowed, but it must keep the same structure as the Excel files** (same sheets, columns, time zones and keys) and be marked as simulated, so the same loader reads it and nobody mistakes it for real data.
- **Anything not in the Excel files is an assumption and is labelled** (for example road time from SHJ to an alternate, and the hold burn rate). Section 16 lists the decisions made.

## 16. Diversion: how the system judges it (plain language)

For each alternate airport the system asks four questions, in this order:

1. **How long is the flight there?** From real flights between SHJ and that airport in 2026. It uses the *typical* time for the arrival estimate and the *conservative* time (the slower one in 9 of 10 flights) for the fuel check. If there are fewer than 5 real flights (today only **DWC**), it estimates from distance and says **ESTIMATED**.
2. **Is there enough fuel?** Fuel on board, reduced for the time since it was reported, must cover the flight **plus the 30-minute final reserve** that aviation rules require the aircraft to land with. If not, the alternate is blocked: "cannot reach with fuel". If fuel was never entered, it says **verify** and the option is not executable.
3. **When must the aircraft leave?** The **latest time to leave the hold** for this alternate and still land with the reserve. This is the time operations act on.
4. **What then?** The time to fly back to SHJ (typical for the arrival time, conservative for crew legality), plus the ground time at the alternate, and whether the crew can legally fly the return, need commander's discretion, or need replacing. The earliest return cannot be before SHJ's forecast reopening.

**Decisions made without the organizers** (the files do not say, so these follow aviation practice and the data):

| Decision | Plain reason |
|---|---|
| Final reserve is 30 minutes | The international minimum for jet aircraft. If the airline has a stricter figure, it can be changed in one place. |
| Hold burn rate stays at 2,400 kg/h | The 2026 fuel history implies about 2,300 to 2,600 kg/h, so it is realistic. |
| Fuel checks use the conservative flight time | A fuel decision must not be optimistic. |
| Old fuel figures are reduced to "now" | A 90-minute-old estimate must not look current. |
| The old "2,300 kg minimum diversion fuel" is no longer subtracted | It was an assumption, and it counted the flight time twice. Diversion margins are now about 20 to 45 minutes less pessimistic than before. |
| Historical diversions are not used for timing | Most were flights leaving SHJ that diverted elsewhere, so they do not describe SHJ arrivals diverting here. |
| Road time from SHJ to each alternate stays an assumption | It is not in the Excel files. |

Open questions for the airline: does it have a **company minimum landing fuel** above the legal 30 minutes, and what are the **real hold burn rate and fuel on board** per flight (the Excel files give fuel at departure only)?
