"""Built-in guide to the console, used by Ask.

Ask answers "how does the Recovery tab work?" or "what does severity mean?" from THIS file, deterministically: no model call,
no database read, no personal data. Every entry describes behaviour that exists in the code (view names, thresholds and
weights are the real ones); when a rule changes in the product, change it here too.

Each topic: id, title, keywords (lower case; matched as whole words/phrases), the explanation, the screen to open, and related topics.
"""
import re

TOPICS: list[dict] = [
    {
        "id": "overview", "title": "How the console works", "view": "occ",
        "keys": ["console", "how does this app work", "how does the app work", "this app", "overview of the app", "screens", "get started", "getting started", "workflow"],
        "text": """The console is one shared disruption room for OCC, Dispatch, Crew Control, Stations and Recovery.
- Top strip: the case you are working on, the hub airport status and the alternates, the clock, Approvals, the bell (alerts) and Ask.
- Bar below it: the next deadline, the role lenses (OCC, Dispatch, Crew Control, Station, Recovery) and the tools (Rules, Integrations, Audit, What if, Report ...).
- Main area: KPI cards, filters, and the board of flights ordered by how soon a decision is needed. Click a flight to open its panel on the right.
The flow is always: see the flight, understand why, read the engine's recommendation, a person proposes a decision, the required roles approve, OCC executes. The engine only recommends; people decide, and every step is recorded in the audit trail.""",
        "related": ["board", "flight_panel", "approvals", "recommendations"],
    },
    {
        "id": "board", "title": "The board and its lanes", "view": "occ",
        "keys": ["board", "lane", "lanes", "act now", "decide soon", "monitoring lane", "flight list", "flight row", "flights list", "rows"],
        "text": """The board lists every flight on the case, in lanes by urgency of the next deadline:
- Act now: under 15 minutes (or already passed).
- Decide soon: 15 to 45 minutes, or the deadline cannot be computed yet (data missing).
- Monitoring: more than 45 minutes away.
- Recovered: flights that have already arrived.
Inside a lane the order is: priority rules first, then the earliest deadline, then the highest severity.
Each row shows the flight and route, severity and tags, where the aircraft is, a fuel meter and a crew-time meter (values marked * are estimates), the LVP status, what the engine suggests or where the decision stands, and a countdown to the deadline.""",
        "related": ["kpi", "filters", "deadline", "severity"],
    },
    {
        "id": "kpi", "title": "The KPI cards", "view": "occ",
        "keys": ["kpi", "kpis", "cards", "card", "top cards", "tiles", "flights affected", "pax affected", "decisions pending", "diverted / holding", "needs verification"],
        "text": """The eight cards at the top count flights live, and each one is a filter: click it and the board shows exactly those flights (click again to clear).
- Flights affected: flights not yet recovered or cancelled.
- Connecting pax: connecting passengers on those flights, each connection counted once (on-board counts are not in the supplied data). The smaller figure under it is how many are AT RISK: their onward flight leaves less than 45 minutes after the projected arrival (the minimum connection time is 30 minutes: under it the connection is missed, 30 to 45 minutes is tight, and a connection of more than 24 hours is no longer a connection), or their flight diverted or was cancelled.
- High severity: severity 50 or more (the card also shows how many are medium).
- Decisions pending: flights with a decision waiting for approval.
- Next deadline: the most urgent deadline; click to open that flight.
- Diverted / holding: aircraft at an alternate / aircraft in a hold.
- Crew at risk: flights whose own leg has a crew margin under 60 minutes, needs discretion, or is over the limit. The margin is the duty's legal end minus that leg's own projected arrival, so each leg is counted on its own.
- Needs verification: missing or conflicting data (see "Needs verification").""",
        "related": ["filters", "verification", "severity"],
    },
    {
        "id": "filters", "title": "Filters", "view": "occ",
        "keys": ["filter", "filters", "filtering", "saved rules", "saved rule", "watched by me", "waiting for approval filter"],
        "text": """The filter row narrows the board: live status, severity (medium and above / high only), pilots not LVP-qualified, crew at risk, needs verification, waiting for approval, watched by me, and any saved FILTER rule that is in force. Filters combine (all must match). The KPI cards use the same definitions, so a card and its filter always agree. The filter is kept in the web address, so you can share the exact view. "Clear" removes them all. A line above the board says how many flights match.""",
        "related": ["kpi", "rules"],
    },
    {
        "id": "severity", "title": "Severity score", "view": "occ",
        "keys": ["severity", "severity score", "high severity", "medium severity", "sev"],
        "text": """Severity is a 0-100 score per flight that says how much it needs attention:
- 40 points: time to its deadline (closer = more)
- 20 points: crew status (exceeded or needing discretion counts most)
- 15 points: LVP block (LVP in force and a pilot is not qualified)
- 15 points: connecting passengers (scaled up to 200)
- 10 points: unverified data (open exceptions)
50 and above is High, 30 to 49 is Medium. The weights are a first version to be agreed with OCC. Priority rules change the board order but not the score.""",
        "related": ["kpi", "board", "rules"],
    },
    {
        "id": "deadline", "title": "Next deadline and 'Why this time?'", "view": "occ",
        "keys": ["deadline", "deadlines", "next deadline", "why this time", "latest legal departure", "last moment", "countdown"],
        "text": """A flight's deadline is the most urgent moment by which a person must decide:
- Airborne: the last moment to divert on fuel (hold endurance minus the flight time to the alternate).
- At an alternate: the latest legal off-blocks, so the crew can still land inside their legal duty period.
- Not departed: the planned departure that avoids holding in the air.
"Why this time?" in the flight panel lists the calculation step by step: sign-in, duty limit, legal end, block time, buffer. If fuel is not reported the deadline cannot be computed and the flight shows "?" and waits in Decide soon. The bar at the top always shows the next deadline across the case.""",
        "related": ["crew_legality", "missing_data", "flight_panel"],
    },
    {
        "id": "flight_panel", "title": "The flight panel", "view": "occ",
        "keys": ["flight panel", "panel", "flight details", "flight detail", "side panel", "right panel"],
        "text": """Click a flight to open its panel. From top to bottom:
- Header: flight, status, severity; Watch flight (alerts), Tag, and deep links to aeroOps, the crew system and aeroMart.
- Decision: who proposed what, which roles must approve and who already has; the buttons you may use.
- AI recommendations: the engine's rationale, confidence, assumptions and ranked options (blocked ones show why).
- Missing data: "?" items you can ask for or enter.
- Deadline with "Why this time?".
- Crew duty: the duty ribbon, limit, legal end, margin, crew list and Find replacement.
- Fuel and alternates: stands, fuel margin, return time per alternate.
- Flight briefing: everything that happened to this flight. Discussion: comments, questions and answers.""",
        "related": ["approvals", "recommendations", "missing_data", "crew_legality"],
    },
    {
        "id": "approvals", "title": "Decisions and approvals", "view": "approvals",
        "keys": ["approval", "approvals", "approve", "approving", "decision", "decisions", "who approves", "multi role", "execute", "reject", "propose", "proposal"],
        "text": """Only people decide; the engine never does. The path is: propose, approve, execute.
- A person proposes a decision (from an engine option, or "Record another decision"). Choosing something other than the engine's first option needs a reason.
- The required roles approve. Policy: Divert needs OCC and Crew Control; Hold, Delay departure and Depart-alternate need OCC; Commander discretion and Crew replacement need Crew Control. Stations and the engine cannot approve.
- Any rejection rejects the decision and needs a reason. When every required role has approved it becomes Approved.
- Only OCC executes. A divert then creates the recovery flight and recalculates crew legality; an aeroMart entry is queued (a manual task while the integration is off).
The "Approvals" button lists what is waiting for your role. Every step is stored with who, role and time, and a decision's content can never be edited.""",
        "related": ["recommendations", "integrations", "audit"],
    },
    {
        "id": "recommendations", "title": "Engine recommendations (Hold, Divert and more)", "view": "occ",
        "keys": ["engine", "recommendation", "recommendations", "recommend", "suggestion", "suggestions", "suggest", "hold or divert", "no action", "continue as planned", "why does it suggest", "rules engine", "ai recommendation"],
        "text": """The engine is a fixed rules engine (not a trained model). It first looks at the situation, then recommends:
- Continue as planned: the airport is open and nothing is at risk.
- Watch: the airport status is not on record, the flight is still far from arrival (decision point about 90 minutes before arrival), or a margin is thin.
- Hold or Divert: the hub is closed or in LVP and the flight is close in. A hold wins if it is possible with at least 15 minutes of fuel spare; otherwise the best alternate. Options are scored on fuel margin (30%), crew outcome (30%), return time (15%), stands (10%) and history (15%).
- Delay departure: a flight not yet departed whose arrival falls inside the closure.
- Depart the alternate / Replace the crew: for a flight already at an alternate, depending on the latest legal departure.
Every option is checked on five things: (1) station availability, (2) fuel to reach it, (3) passenger connections, (4) crew time and (5) whether the crew could extend duty (commander discretion).
- Station availability: a live status entered for the airport always wins. With none, an alternate uses the flight history: how many past SHJ fog days it landed aircraft (strong, proven or limited evidence), and the most aircraft seen on the ground there at once as its stands (shown with "~"). Alternates with limited history stay "verify first". Entering a status, stands or weather for a station re-ranks the options straight away.
- Fuel: fuel margin on arrival above the 30 minute final reserve (an estimate from route history until the real figure is entered).
- Connections: connecting passengers who would miss (under the 30 minute minimum connection time, or the onward flight more than 24 hours later) or nearly miss (30 to 45 minutes) their onward flight lower an option's score and are listed in its reasons.
- Crew return: for crew whose next flight starts at the hub, a nearer alternate or a quicker way back scores higher; an alternate they cannot return from in time is ranked lowest and flagged. If no crew flies from the hub next, it does not count.
- Crew: margin against the legal end of duty. If only commander discretion makes it work, the option stays available but is flagged with the minutes needed and ranked lower. A delayed departure that lands past the crew's legal end also suggests re-timing or replacing the crew.
An option is blocked, with the reason, when an alternate is closed, has no fuel, cannot be reached, a pilot is not LVP-qualified or the crew would be over the limit. Unknown inputs block an option ("verify first"); they are never treated as safe. A flight that already diverted is never offered a second diversion. Confidence drops with every estimated, forecast or history-based input.""",
        "related": ["alternates", "missing_data", "approvals", "airport_verify"],
    },
    {
        "id": "missing_data", "title": "Missing data and the '?' marks", "view": "occ",
        "keys": ["missing data", "question mark", "verify", "unknown", "data gap", "data gaps", "ask crew", "ask station", "enter value", "data request", "data requests", "unverified"],
        "text": """Unknown is never shown as safe. When an input is missing the panel shows a "?" with what to do:
- Ask crew / Ask station sends a tracked request to the right role; it stays open until answered and the addressed role is alerted.
- Enter value / Enter answer lets the right person type it (for example holding endurance in minutes, or an alternate's status and stands) with a quality label (reported or estimate).
Saving applies the value where the engine reads it and immediately re-ranks the options. Open requests count in the "Needs verification" card.""",
        "related": ["verification", "airport_verify", "recommendations"],
    },
    {
        "id": "verification", "title": "'Needs verification' and 'Verification required'", "view": "data-quality",
        "keys": ["needs verification", "verification required", "verification", "why verification", "data exception", "exceptions"],
        "text": """A flight needs verification when its data is missing or conflicting, so the app refuses to call it legal or safe. It counts when:
- the crew-legality engine could not decide (for example the duty includes a crew type with no duty-time rule, such as the Second Officer in the supplied limits file, or a sign-in time is missing), or
- there is an open data exception on its flight, duty or crew assignment (for example the duty sheet's maximum duty differs from the approved rule), or
- it is airborne with no fuel figure, or someone has an open data request on it.
The "Data quality" page lists every open exception, blocking ones first. Fixing the source data (or answering the request) clears the flag.""",
        "related": ["missing_data", "crew_legality", "kpi"],
    },
    {
        "id": "crew_legality", "title": "Crew legality (duty limits, margin, discretion)", "view": "crew",
        "keys": ["crew legality", "legal", "legality", "fdp", "flight duty period", "duty limit", "margin", "discretion", "commander discretion", "legal end", "sign in", "sign-in", "duty ribbon", "crew time"],
        "text": """Crew legality follows the approved GCAA duty-time table. The FDP (flight duty period) runs from sign-in to the end of the last flight. Its maximum depends on the crew type, the local time of sign-in and the number of sectors; a diversion adds a sector and so shortens the limit.
- Legal end = sign-in + the maximum.
- Margin at landing = legal end minus the projected landing; under 60 minutes is "at risk", negative means the flight needs commander discretion.
- Commander discretion: the captain may extend the duty by up to 3 hours. It is the captain's decision, recorded by Crew Control, and is never assumed by the app.
- Missing or conflicting inputs never give "legal": the status becomes verification required.
The duty ribbon shows sign-in, now, projected landing, legal end and the discretion zone.""",
        "related": ["crew_lens", "replacement", "verification"],
    },
    {
        "id": "crew_lens", "title": "Crew Control view", "view": "crew",
        "keys": ["crew control", "crew tab", "crew view", "crew lens", "who runs out", "runs out of legality", "runway"],
        "text": """The Crew Control tab answers "who runs out of legal duty next?". It lists the operating crew of the case's flights sorted by time to legal end, each with: the flight and sectors, the legal end and a countdown, the duty ribbon (sign-in, now, projected landing, legal end, discretion zone), and the margin at landing. "Find replacement" opens the standby finder for crews with a thin margin; "Open" shows the flight panel. The flight panel stays on the right.""",
        "related": ["crew_legality", "replacement"],
    },
    {
        "id": "replacement", "title": "Finding replacement crew", "view": "crew",
        "keys": ["replacement", "replace crew", "find replacement", "standby", "standby crew", "replace the crew", "crew swap", "swap"],
        "text": """"Find replacement" lists standby crew for a duty. A candidate is only offered when they are: legal for the remaining legs, LVP-qualified when LVP is in force, available (no roster conflict, minimum rest respected) and able to reach the station (positioning time by road is included). Candidates that would break tomorrow's roster or lack LVP are shown greyed with the reason. Selecting candidates proposes a Crew replacement decision; Crew Control approves it, OCC executes it, and the swap closes the old assignment and opens the new one with its own sign-in so the history is kept.""",
        "related": ["approvals", "crew_legality"],
    },
    {
        "id": "station_lens", "title": "Station view", "view": "station",
        "keys": ["station", "station tab", "station view", "station lens", "tablet", "big buttons", "message to occ"],
        "text": """The Station tab is the simple tablet view for a station that is handling a diverted aircraft. It shows one card per aircraft on the ground with what OCC needs from the station. Big buttons record what happened: Landed, On blocks, Refuel done, Passengers on board / disembarked, Crew arrived, Ready to depart. Each tap updates the diversion record with the time and your name and alerts OCC. "Ask or answer OCC" posts a message on the flight, which also alerts OCC. Stations can comment and update status but cannot propose or approve decisions.""",
        "related": ["notifications", "approvals"],
    },
    {
        "id": "recovery_lens", "title": "Recovery tab (arrival plan after reopening)", "view": "recovery",
        "keys": ["recovery", "recovery tab", "recovery view", "recovery lens", "arrival plan", "arrival slots", "slots", "resequence", "re-sequence", "sequencing", "recovery plan", "after reopening"],
        "text": """The Recovery tab plans the order in which flights land at the hub once it reopens.
- Slots: starting at the reopening time (the hub's OPEN time, else the expected reopening), one slot every 60 / capacity minutes. Capacity is the airport's arrivals per hour (20 per hour if none is set). The tab shows 12 slots.
- Who is sequenced: watched flights still inbound (airborne, holding or not yet departed) and the recovery legs of diversions.
- Order: flights are scored 40% fuel urgency, 30% crew urgency, 15% rotation impact (the same aircraft departing again within 8 hours) and 15% passengers (passengers plus twice the connecting passengers). Each feasible flight gets the earliest free slot at or after its own earliest arrival.
- Cannot be sequenced now: a flight is set aside, with the reason, when its fuel ends before its slot (it must divert), its crew's latest legal departure is too early (replacement or discretion needed), or LVP is in force and a pilot is not qualified.
- You can drag a flight to another slot (or select it and click a slot). The server checks fuel, crew legality and LVP and refuses a move that is too early or into a taken slot.
- "Ask the engine to re-sequence" rebuilds the plan with the latest data. The plan is then proposed for OCC approval (Recovery decisions need OCC).
The summary line shows when the hub reopens, how many flights are in the plan and how many land inside the first hour.""",
        "related": ["approvals", "crew_legality", "recommendations", "airport_verify"],
    },
    {
        "id": "alternates", "title": "Fuel and alternates table", "view": "occ",
        "keys": ["alternate", "alternates", "alternate airport", "alternates table", "fuel margin", "stands free", "bingo", "return block"],
        "text": """For an airborne flight the panel lists every alternate the engine considered: stands free (what the station reported, minus one for each diverted aircraft still on the ground there; the stand comes back when it departs), fuel margin on arrival (above the final reserve), the distance and flying time from the hub, the return block time to the hub and whether it is executable. Each option's reasons also show the fuel to reach it in kilograms (trip fuel plus the 30 minute final reserve against the fuel on board) and how the crew would get back to the hub (road, or the next scheduled flight as passengers) and whether they make their next flight. Return time counts in the ranking only for crew whose next flight starts at the hub: a nearer alternate, or one they can get back from in time, scores higher, and one they cannot return from in time scores lowest and is flagged (re-roster or replace the crew). If none of the crew has a next flight from the hub, return time does not affect the ranking. Distances come from the airport coordinates, flying times and trip fuel from the history of real flights; where a pair has too little history the value is generated from a formula and says "synthetic", and the road times are always synthetic. Blocked alternates say why: no fuel, status not confirmed, cannot be reached on fuel, or the alternate is closed. Return times come from the history of real flights (a high percentile, so it is cautious). Alternates that nobody has confirmed show "verify": use the airport verify sheet. A flight never goes back to the airport it already diverted to.""",
        "related": ["airport_verify", "recommendations"],
    },
    {
        "id": "airport_verify", "title": "Verifying an airport (hub and alternates)", "view": "occ",
        "keys": ["airport verify", "verify airport", "verify an airport", "airport status", "hub status", "verify the airport", "not verified", "update airport", "alternate status", "reopening", "lvp in force", "visibility"],
        "text": """The strip at the top shows the hub and the alternates; an alternate's stand count is the free stands reported by the station minus one for every aircraft diverted there that has not left again (hover to see both numbers). An alternate marked "verify" (or a hub showing "Not verified") has no confirmed status, so the engine will not treat it as usable. Click it to open the sheet: status (open, restricted, closed), stands free, fuel, handling and weather above minima; for the hub also LVP in force, visibility, arrivals per hour, the expected reopening time and a reason. Choose the source (reported, forecast or manual) and save. The engine re-ranks every affected flight straight away. Statuses are history (each save adds an event), so what was known when is never lost.""",
        "related": ["recommendations", "recovery_lens", "alternates"],
    },
    {
        "id": "lvp", "title": "LVP (low visibility procedures)", "view": "occ",
        "keys": ["lvp", "low visibility", "rvr", "pilots not lvp", "lvp qualified", "not lvp"],
        "text": """LVP (low visibility procedures) are declared when visibility is very low. In this operation both pilots must be LVP-qualified to land while LVP is in force. A flight whose captain or first officer is not qualified is flagged "LVP x" and cannot be given a hold at the hub: the engine blocks that option and the recovery plan sets the flight aside until the crew is changed or LVP is cancelled. Standby crew are only offered as replacements when they are LVP-qualified.""",
        "related": ["recommendations", "replacement", "recovery_lens"],
    },
    {
        "id": "rules", "title": "Rules & filters (custom rules)", "view": "rules",
        "keys": ["rules", "rule", "custom rule", "custom rules", "rules and filters", "rules & filters", "constraint", "priority rule", "alert rule", "filter rule"],
        "text": """Rules & filters lets managers add their own rules for a time window. A rule is a few conditions (for example "pilots not LVP-qualified" or "crew margin under 45 min"), combined with AND / OR, over a fixed list of fields; it is turned into a safe query, never free text.
- Filter: adds a saved filter you can apply on the board. Active at once.
- Alert: notifies the rule's creator and the flight's watchers when a flight starts matching. Active at once.
- Priority: moves matching flights up the board. Needs OCC approval.
- Constraint: flags matching flights as blocked by the rule. It can only add a block, never relax the approved duty limits. Needs OCC or Crew Control approval.
The builder shows how many flights a rule matches right now before you save. Rules stop at their end time, and retiring a rule keeps its history.""",
        "related": ["filters", "severity", "approvals"],
    },
    {
        "id": "integrations", "title": "Integrations (aeroMart, aeroOps, crew system)", "view": "integrations",
        "keys": ["integration", "integrations", "aeromart", "aeroops", "deep link", "deep links", "outbox", "manual task", "crew system", "open in"],
        "text": """Integrations holds the links to the systems of record. Deep links ("Open in aeroOps / crew system / aeroMart") open the selected flight there with its details filled in; the URL templates are set here by OCC. When a divert is executed, an entry for aeroMart is queued in the outbox (once only, with an idempotency key). While an integration is switched off, no data is sent: the entry becomes a manual task with a link, and someone presses "Mark entered" once it has been keyed in. No connector is shipped; turning a write API on only means the entries stay pending for one.""",
        "related": ["approvals", "flight_panel"],
    },
    {
        "id": "whatif", "title": "What if…", "view": "whatif",
        "keys": ["what if", "whatif", "what-if", "scenario test", "reopening later", "simulate"],
        "text": """What if… tests a different reopening time without touching live operations. It copies the case into a separate what-if scenario (flight state, crew and calculations), shifts the hub's reopening time by the minutes you choose, lets the engine re-run, and compares the result with the current advice flight by flight (changed advice is highlighted). The what-if scenario is framed in magenta and cannot be confused with live data; "Open this scenario" lets you explore it.""",
        "related": ["cases", "recommendations"],
    },
    {
        "id": "report", "title": "Report", "view": "report",
        "keys": ["report", "reports", "disruption report", "generate report"],
        "text": """Report builds the disruption report for the open case from the shared record: the case and hub status history, every flight, diversions, decisions with their approvals, the latest recovery plan, the timeline and open exceptions, plus a marker of the audit trail up to that moment. Generating it stores it as a record; nothing is changed. Use it for the debrief after the event.""",
        "related": ["audit", "approvals"],
    },
    {
        "id": "notifications", "title": "Watching flights, Teams and the bell", "view": "notes",
        "keys": ["notification", "notifications", "bell", "alerts", "watch", "watch flight", "watching", "teams", "subscribe"],
        "text": """Watch flight subscribes you to a flight: you are alerted (bell, top right) on every decision, approval, comment, station update and data request for it, but never about your own actions. "+ Teams alerts" also marks the flight for the Teams channel (the in-app bell works today; Teams delivery is a later step). Besides watching, some alerts go to a role automatically: approvers when a decision needs them, OCC when a decision is fully approved or a station sends a message, the addressed role when data is requested. Click an alert to open that flight; "Mark all read" clears the badge.""",
        "related": ["approvals", "station_lens", "missing_data"],
    },
    {
        "id": "tags", "title": "Tagging a flight (medical, VIP)", "view": "occ",
        "keys": ["tag", "tags", "tagging", "medical", "vip", "high impact"],
        "text": """Tag marks a flight as Medical, VIP or High impact, with a note. The tag shows on the board and the panel, watchers and OCC are alerted, and rules can use it (for example a priority rule "Medical flights first"). Tags can be removed by clicking them in the panel header.""",
        "related": ["rules", "notifications"],
    },
    {
        "id": "cases", "title": "Cases and scenarios (live, replay, what-if)", "view": "occ",
        "keys": ["case", "cases", "scenario", "scenarios", "live", "replay", "new case", "create case", "close case", "pink border", "magenta"],
        "text": """A case is one disruption event with its own watch list of flights (every flight arriving at the airport in a time window). It belongs to a scenario: Live (the real operation), Replay (a recorded event run on its own clock) or What-if (a safe copy for testing). Replay and what-if are framed in magenta and nothing in them affects live operations. A live case starts now and asks only for its end; replay and what-if cases take a start and an end. A case can be closed (kept for the audit trail) or, if nobody has acted on it, deleted. You can also move the hub's reopening forecast from "Case…".""",
        "related": ["whatif", "report", "push"],
    },
    {
        "id": "push", "title": "Push live data (simulated feed)", "view": "occ",
        "keys": ["push live data", "push data", "simulated feed", "feed", "live feed", "simulate data"],
        "text": """Push live data advances the live scenario to the present using a simulated movement feed, so the console can be tested with moving flights. It sends the departures, take-offs, landings and arrivals that should have happened by now through the same ingestion a real feed uses, fills in passengers, moves crew duties from planned to active to completed, releases finished standby slots and adds a labelled SIMULATED fuel figure for airborne flights. It also moves the scenario clock forward with the data. It is safe to press repeatedly. It never invents airport closures: those stay a person's input. A real feed would post the same events instead.""",
        "related": ["cases", "airport_verify"],
    },
    {
        "id": "data_sources", "title": "Data sources toggle", "view": "occ",
        "keys": ["data sources", "data source", "yellow labels", "yellow tags", "which table", "database object"],
        "text": """"Data sources" shows a small yellow label on each block naming the database view or function that feeds it (for example v_flight_watch or rank_alternates()). It is for engineers and reviewers who want to see where every number comes from. Turn it off again with the same button.""",
        "related": ["overview"],
    },
    {
        "id": "audit", "title": "Audit trail", "view": "audit",
        "keys": ["audit", "audit trail", "history", "who did what", "log"],
        "text": """The audit trail is an append-only record of who did what and when: every table change by the database and every action through the API (logins, decisions, approvals, station updates, questions to Ask, refused attempts and more), with the scenario clock. Nothing can be edited or deleted. Open "Audit" to filter by person, case, flight or action.""",
        "related": ["approvals", "report"],
    },
    {
        "id": "data_quality", "title": "Data quality page", "view": "data-quality",
        "keys": ["data quality", "data quality page", "alerts and data", "feed freshness", "stale"],
        "text": """Data quality lists the open data exceptions (blocking first), such as a missing duty-time rule, a duty sheet that disagrees with the approved rule, or a flight that exists only in a duty sheet, and how fresh each data feed is. Blocking exceptions stop a flight from being called legal until fixed; warnings are shown for review.""",
        "related": ["verification", "missing_data"],
    },
    {
        "id": "ask", "title": "The Ask assistant", "view": "ask",
        "keys": ["ask", "assistant", "ask ai", "ai assistant", "what can you do", "what can i ask", "who are you"],
        "text": """Ask answers questions about this disruption and about how the console works. Data questions (crew running out of legality, the next deadline, where an aircraft is, what is waiting for approval, a flight's status, pilots without LVP, missing data) are answered from the live database; free-text questions go to the AI when it is configured, grounded only on this case's data. It is read-only: it cannot approve, decide or change anything. It never shows personal data (crew appear as position and crew number) and refuses other topics. Answers come with the flights involved and buttons that open the screen where a person can act. Every question and refusal is audited.""",
        "related": ["overview", "approvals"],
    },
]

BY_ID = {t["id"]: t for t in TOPICS}

# "how does X work", "explain X", "what does X mean" ... but not "what is the next deadline" (that is a data question)
HELP_INTENT = re.compile(
    r"\b(how (does|do|is|are|can|should|to)|explain|describe|meaning|means?|works?|working|purpose|tell me about|walk me through|"
    r"what (does|do) .{1,40}\b(mean|do|show|work)|what is (a|an)\b|what are the|"
    r"what (is|are|'s) (?!the next\b|next\b|waiting\b|pending\b|my\b|the situation\b|the status\b|the current\b|the latest\b|there\b)|why (is|are|do|does) .{0,30}(shown|used|needed|there)|guide|help me understand|difference between)\b",
    re.I,
)


def find_topics(q: str, limit: int = 3) -> list[dict]:
    """Best matching guide topics for a question (whole-word keyword scoring; longer phrases weigh more)."""
    low = q.lower()
    scored = []
    for t in TOPICS:
        score = 0
        for k in t["keys"]:
            if re.search(r"(?<![a-z0-9])" + re.escape(k) + r"(?![a-z0-9])", low):
                score += 2 + len(k.split()) * 2 + (1 if len(k) > 8 else 0)
        if re.search(r"(?<![a-z0-9])" + re.escape(t["title"].lower().split(" (")[0]) + r"(?![a-z0-9])", low):
            score += 4
        if score:
            scored.append((score, t))
    scored.sort(key=lambda x: -x[0])
    return [t for _, t in scored[:limit]]


def catalogue() -> str:
    return "I can explain: " + "; ".join(t["title"] for t in TOPICS) + "."
