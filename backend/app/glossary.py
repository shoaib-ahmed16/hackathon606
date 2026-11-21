"""Foooh! glossary: the terms, rules and numbers of the product, in plain words, for the Ask assistant.

Each entry is {id, term, keys (spellings the user may type), text}. The text is what the system actually does today: when behaviour changes,
change the entry. Two uses:
  * a "what is / what does ... mean" question that names a term is answered straight from here (no model, always available);
  * the best matching entries are given to the language model as KNOWLEDGE, so it can answer any question about Foooh! itself.
"""
import re

TERMS: list[dict] = [
    {"id": "foooh", "term": "Foooh!", "keys": ["foooh", "fooh", "this app", "this console", "this product"],
     "text": "Foooh! is the control room for airline fog disruption at Sharjah (SHJ). It shows which flights are affected, whether crews are still legal, which alternate airport can take a diverting aircraft, and who must decide what by when. The system recommends and explains; people decide, and every decision carries a name, a reason and a time."},
    {"id": "occ", "term": "OCC", "keys": ["occ", "operations control centre", "operations control center", "duty manager"],
     "text": "Operations Control Centre: the team that runs the disruption. OCC proposes and executes decisions, approves diversions together with Crew Control, and is the only role that can execute a decision. OCC and admin also manage alternates, rules, integrations and the scenario clock."},
    {"id": "roles", "term": "Roles", "keys": ["roles", "role", "permissions", "dispatch", "crew control", "station user"],
     "text": "OCC and admin run the case. Dispatch proposes decisions, works fuel and files the flight plan. Crew Control approves diversions and crew changes and moves crew report times. Recovery plans landings after reopening. Station users work at an alternate airport: landed, on blocks, refuelled, load sheet ready, ready to depart. Station users and the AI can never approve."},
    {"id": "shj", "term": "SHJ", "keys": ["shj", "sharjah", "hub"],
     "text": "Sharjah International Airport, the hub. Times are stored in UTC (marked Z); Sharjah is UTC+4 with no daylight saving, and crew duty brackets use SHJ local time."},
    {"id": "alternate", "term": "Alternate airport", "keys": ["alternate", "alternates", "alternate airport", "rkt", "fjr", "aan", "dwc", "auh", "mct"],
     "text": "An airport the engine may divert to when SHJ is closed or restricted: RKT, FJR, AAN, DWC, AUH, MCT and any OCC adds. OCC and admin can add, edit or switch one off (nothing is deleted). A grey '?' chip means nobody has entered its status, so it is not treated as usable until someone confirms."},
    {"id": "lvp", "term": "LVP", "keys": ["lvp", "low visibility", "low visibility procedures", "lvp qualified", "lvp-qualified"],
     "text": "Low Visibility Procedures, in force when fog cuts visibility. Landing needs both pilots LVP-qualified; a flight whose pilot is not qualified cannot land at that airport and needs a different crew. Foooh! shows a red banner naming the position, never the person."},
    {"id": "rvr", "term": "RVR", "keys": ["rvr", "runway visual range", "visibility"],
     "text": "Runway Visual Range: how far a pilot can see along the runway, in metres. It is shown with the airport status and is one of the inputs that decides whether an airport can be used."},
    {"id": "fdp", "term": "FDP (flight duty period)", "keys": ["fdp", "flight duty period", "duty limit", "duty time", "maximum fdp", "duty period"],
     "text": "The maximum time a crew may be on duty, taken from the approved GCAA table (216 rules). It depends on crew type, the sign-in time in SHJ local time (a bracket such as 18:00 to 21:59) and the number of sectors. Legal end = sign-in + maximum FDP. The table is law, not a Foooh! setting."},
    {"id": "gcaa", "term": "GCAA", "keys": ["gcaa", "regulator", "general civil aviation authority"],
     "text": "The UAE General Civil Aviation Authority. Its duty-time table is loaded as the rule set Foooh! uses to decide whether a crew is legal."},
    {"id": "signin", "term": "Sign-in, bracket and the report-time lock", "keys": ["sign-in", "sign in", "signin", "report time", "bracket", "report-time", "bracket lock", "lock"],
     "text": "Duty starts at sign-in, and the duty-time bracket is fixed by the sign-in time. Before sign-in, Crew Control can move the report time (with a reason, at most 12 hours, not into the past) and the limit may change. After sign-in the database refuses the change: only the number of sectors can still move the limit. A padlock shows once a crew has signed in."},
    {"id": "legality", "term": "Legal, at risk, discretion, exceeded, verify", "keys": ["legal", "at risk", "discretion required", "exceeded", "crew status", "crew margin", "legality"],
     "text": "Crew status from the margin between the legal end and the projected landing: Legal (over 60 minutes spare), At risk (under 60), Discretion required (past the limit but within 3 hours), Exceeded (past that), and Verify (not enough verified data, never treated as legal)."},
    {"id": "discretion", "term": "Commander's discretion", "keys": ["discretion", "commander discretion", "commander's discretion", "extend duty"],
     "text": "The commander may extend a duty by up to 3 hours beyond the table limit. Foooh! shows that zone and records the decision, which Crew Control approves. It is never assumed or automatic."},
    {"id": "n1", "term": "N and N+1", "keys": ["n+1", "n + 1", "n and n+1", "one more sector", "extra sector", "sector"],
     "text": "Each crew member is checked for the flights they are on (N) and with one more sector (N+1). A diversion adds a sector, which usually tightens the limit, so N+1 shows the risk of diverting before anyone decides."},
    {"id": "hold", "term": "Hold", "keys": ["hold", "holding", "hold or divert", "hold vs divert", "hold versus divert"],
     "text": "The aircraft circles near SHJ until it reopens. A feasible hold with at least 15 minutes of spare fuel is preferred over a diversion: it adds no sector, keeps the aircraft where the schedule needs it and costs the crew no extra duty."},
    {"id": "divert", "term": "Divert", "keys": ["divert", "diversion", "diverting", "diverted"],
     "text": "Send the aircraft to an alternate. It needs OCC and Crew Control approval and OCC executes it. Executing marks the flight Diverting with a landing time, creates the recovery leg back to SHJ, counts the extra sector for the crew and queues a manual aeroMart entry. The alternate's stand and arrival slot are claimed from approval onward."},
    {"id": "executable", "term": "Executable", "keys": ["executable", "not executable", "blocked", "blocker"],
     "text": "An alternate is executable when nothing blocks it: status known and open, weather and parking confirmed, fuel and handling available, enough fuel to arrive with the 30-minute reserve, no LVP problem and the flight has not already diverted. A missing fact is a 'verify' blocker, not a pass."},
    {"id": "reserve", "term": "Final reserve", "keys": ["final reserve", "reserve", "fuel reserve", "30 minute", "30 minutes reserve", "at reserve"],
     "text": "The fuel that must still be on board at landing: 30 minutes, the international minimum for jets (a company figure can be set in one place). A flight whose estimated fuel is at or below it shows 'At reserve' and sits in Act now. The fuel estimate stops at the moment of crossing, so no countdown is shown."},
    {"id": "fuel", "term": "Fuel and endurance", "keys": ["fuel", "endurance", "fuel on board", "burn", "burn rate", "hold burn", "fuel estimate", "estimated fuel"],
     "text": "Fuel now is worked out from fuel at take-off for the route (from history) minus the burn since take-off, at the scenario clock. Hold burn is assumed at 2,400 kg/h for every aircraft. Endurance is the minutes left to final reserve. Where no fuel is known the screen says 'verify'; it is never treated as safe."},
    {"id": "p50p90", "term": "P50 and P90", "keys": ["p50", "p90", "percentile", "typical time", "conservative time"],
     "text": "From the 2026 flights: P50 is the typical flight time and P90 the slow case (slower than 9 in 10 flights). Arrival estimates use P50; fuel checks use P90 because a fuel decision must not be optimistic. Below 5 flights for a pair the time is estimated from distance and labelled so."},
    {"id": "deadline", "term": "Deadline and the lanes", "keys": ["deadline", "next deadline", "lane", "lanes", "act now", "decide soon", "monitoring", "latest legal departure", "last moment"],
     "text": "A flight's deadline is the next moment someone must act: the last moment to divert on fuel for a flight in the air, the latest legal departure for one at an alternate. The board groups flights into Act now (under 15 minutes or passed), Decide soon (15 to 45 minutes or unknown) and Monitoring (more than 45)."},
    {"id": "severity", "term": "Severity score", "keys": ["severity", "severity score"],
     "text": "A 0 to 100 score used to order flights and flag the unusual: deadline 40, crew 20, LVP 15, connecting passengers 15, unverified data 10. High is 50 and over, medium 30 to 49. The weights are a first proposal to agree with OCC; the deadline, not the score, drives the lanes."},
    {"id": "confidence", "term": "Confidence", "keys": ["confidence", "confidence percentage", "how sure"],
     "text": "The percentage beside a recommendation shows how complete the inputs are, not a probability. It is a fixed value per situation (for example 0.85 for continue as planned) or 0.90 minus penalties for estimated fuel, a forecast reopening or unknown crew legality. It has not been checked against outcomes."},
    {"id": "ai", "term": "Is it AI?", "keys": ["is it ai", "machine learning", "recommendation engine", "rules engine", "how are recommendations", "how does the engine", "ai recommendation", "ai recommendations"],
     "text": "The recommendation is a transparent rules engine that uses statistics from history (flight and block times, past use of each alternate). It is not trained and does not learn. The Ask assistant is the only language model: it explains and answers, and it can never decide, approve or change anything."},
    {"id": "weights", "term": "Alternate ranking weights", "keys": ["weights", "ranking", "rank", "score weights", "how are alternates ranked"],
     "text": "Executable alternates are scored: fuel 30%, crew 30%, return flight 15%, stands 10%, history 15%. They are hand-set, not fitted to past decisions, and meant to be agreed with OCC. Ties are marked, and the one needing the decision sooner (smaller fuel margin) is named."},
    {"id": "verify", "term": "Verify and the '?' marks", "keys": ["verify", "verification", "question mark", "needs verification", "missing data", "data gap"],
     "text": "Foooh! never guesses: a missing or unconfirmed value shows '?' or 'verify' and blocks anything that depends on it. Needs verification counts unverified crew, open data problems, unknown fuel, an overdue ETA and open requests."},
    {"id": "etaoverdue", "term": "ETA overdue", "keys": ["eta overdue", "overdue eta", "eta"],
     "text": "A flight still in the air whose ETA has passed cannot land in the past. Its landing is set to now, it is flagged ETA overdue and its crew legality becomes 'verification required' instead of looking safer than it is."},
    {"id": "scenario", "term": "Case, scenario, live, replay, what-if", "keys": ["case", "scenario", "live", "replay", "what-if", "what if", "whatif", "simulation"],
     "text": "A case is one disruption window. LIVE is the real picture, REPLAY is a recorded fog event replayed for practice, WHAT-IF is a separate copy to test a question such as 'SHJ stays closed longer'. Replay and what-if turn the top bar magenta: nothing there affects live operations."},
    {"id": "clock", "term": "Scenario clock", "keys": ["clock", "scenario clock", "paused", "run the clock", "advance the clock"],
     "text": "'Now' is the scenario clock, paused by default (live demo 20 Nov 2026 16:45Z, replay 21 Nov 02:45Z). OCC and admin can run it in real time, pause it or step 15 minutes. The screen and the database share it, so every record is stamped with the scenario time you see."},
    {"id": "paxatrisk", "term": "Connecting pax and pax at risk", "keys": ["pax", "passengers", "connecting pax", "pax at risk", "connections", "connecting passengers", "missed connection"],
     "text": "Connecting pax are passengers connecting at SHJ onto other flights, each connection counted once (on-board and non-connecting passengers are not in the data). Pax at risk are those whose onward flight is missed, leaves under 45 minutes after the projected arrival (minimum connection is 40), or is on a diverted or cancelled flight."},
    {"id": "mct", "term": "Minimum connection time", "keys": ["minimum connection", "minimum connection time", "min connection"],
     "text": "The smallest time a passenger needs to change flights. 40 minutes in Foooh! (the smallest scheduled connection in the data), 30 in the recovery plan. It is an assumption, labelled wherever used."},
    {"id": "recovery", "term": "Recovery", "keys": ["recovery", "recovery leg", "recovery plan", "landing order", "slots"],
     "text": "The plan after SHJ reopens: the landing order (drag a flight to another slot; impossible moves are refused with a reason), and for each diverted aircraft when it can leave the alternate, whether its crew can legally fly the return, standby replacements and which connecting passengers would miss their flight. The recovery leg is the alternate-to-SHJ flight created when a diversion is executed."},
    {"id": "replacement", "term": "Replacement crew and standby", "keys": ["replacement", "replace crew", "standby", "deadhead", "replacement crew", "candidate"],
     "text": "Find replacement checks rest, roster conflicts, LVP qualification and the road time to where the aircraft is: a candidate cannot sign in before they arrive, and their limit is for the legs they will fly. A swap can be proposed only for a CANDIDATE. Deadhead means travelling as a passenger to reach the aircraft."},
    {"id": "approvals", "term": "Decisions and approvals", "keys": ["approval", "approvals", "approve", "decision", "decisions", "who approves", "withdraw", "execute"],
     "text": "Recommend, propose (a person with a written reason), approve (each required role), execute (OCC only), audit. Divert needs OCC and Crew Control; hold, recover, delay, cancel and aircraft swap need OCC; crew replacement and commander discretion need Crew Control. A proposer can withdraw before execution. The rule is enforced by the database."},
    {"id": "capacity", "term": "Airport capacity", "keys": ["capacity", "stands", "stand", "airport capacity", "arrivals per hour", "diverted in", "stands free", "history floor", "parking"],
     "text": "Stands and arrivals per hour for the hub and alternates, with the source of each number: a person's status entry, an OCC assumption, or a history floor (marked ≥, the most ever seen, never a limit). Stands free = stands minus aircraft on the ground at the end of the hour, so it can go negative. 'Diverted in' counts approved or sent diversions not yet landed."},
    {"id": "checklist", "term": "Return-leg checklist", "keys": ["flight plan", "load sheet", "checklist", "ready to depart", "return leg", "return-leg"],
     "text": "After a diversion lands, two items must be done before 'Ready to depart': the flight plan filed (Dispatch, OCC or admin) and the load sheet ready (Station, OCC or admin). Each records who and when; OCC can ask for either, and ticking the item answers the request."},
    {"id": "rulesfilters", "term": "Rules and filters", "keys": ["rules", "filter rule", "custom rule", "priority rule", "constraint rule", "rules and filters", "alert rule"],
     "text": "Managers add their own rules from a fixed list of fields: a filter (chip on the board), an alert, a priority (changes order) or a constraint (blocks something). A priority or constraint needs approval, and a rule can only add a block, never relax a duty limit. The builder shows how many flights match before saving."},
    {"id": "integrations", "term": "aeroMart, aeroOps and the crew system", "keys": ["aeromart", "aeroops", "crew system", "integration", "integrations", "outbox", "deep link", "manual task"],
     "text": "The systems of record. Foooh! only links to them: 'Open in aeroOps / crew system / aeroMart' opens that system's page in your browser with the flight selected. Nothing is sent to or read from them. An executed diversion becomes a manual task in the outbox for OCC to enter in aeroMart."},
    {"id": "feed", "term": "Feed, events and data sources", "keys": ["feed", "push live data", "data source", "data sources", "flight event", "flight events"],
     "text": "A flight's state is never edited directly: every change is an event (OUT, OFF, ON, IN, ETA, DIVERT, CANCEL), duplicates are ignored, older messages cannot overwrite newer facts, and the status is derived from the actual times. Push live data feeds the simulated live picture."},
    {"id": "audit", "term": "Audit trail", "keys": ["audit", "audit trail", "history of actions", "who did what"],
     "text": "A permanent, append-only record of who did what, in which role, at which scenario time, with what result (refusals and Ask questions included). Nothing is edited or deleted."},
    {"id": "ask", "term": "The Ask assistant", "keys": ["assistant", "chatbot", "ask foooh", "ask assistant", "this chat", "ctrl+k"],
     "text": "Ask answers questions about the case (flights, crew, airports, deadlines, passengers) and about Foooh! itself (terms, rules, screens). It is read-only, never shows crew names, and only sees this case's data and the Foooh! guide. It refuses to change anything: a person acts in the flight panel."},
    {"id": "connection", "term": "Connection interrupted bar", "keys": ["connection interrupted", "retrying", "banner", "offline"],
     "text": "If a refresh fails (network or API restart), the screen keeps the last data it received and shows a thin bar saying the connection was interrupted and that it is retrying. It clears by itself when the server answers."},
]

BY_TERM = {t["id"]: t for t in TERMS}

# "what is X", "what does X mean", "define X", "explain X": the WHOLE question is a definition request for a term (not "what is the next deadline")
DEFINE = re.compile(
    r"^\s*(?:what\s*(?:'s|is|are|does|do)|whats|define|explain|meaning of|tell me about)\s+(?:an?\s+|the\s+)?(?P<x>.+?)(?:\s+(?:mean|means|stand for|stands for|do|work|works))?\s*\??\s*$", re.I)
DYNAMIC = re.compile(r"\b(next|my|current|currently|waiting|pending|latest|now|today|situation|status of|right now|affected|at risk right)\b", re.I)


def _hit(low: str, key: str) -> bool:
    return bool(re.search(r"(?<![a-z0-9])" + re.escape(key) + r"(?![a-z0-9])", low))


def find_terms(q: str, limit: int = 3) -> list[dict]:
    """Glossary entries whose key appears in the text as a whole word; longer keys weigh more, the term's own name most."""
    low = q.lower()
    scored = []
    for t in TERMS:
        score = 0
        for k in t["keys"]:
            if len(k) < 2:
                continue
            if _hit(low, k):
                score += 2 + len(k.split()) * 2 + (1 if len(k) > 6 else 0)
        if _hit(low, t["term"].lower().split(" (")[0]):
            score += 3
        if score:
            scored.append((score, t))
    scored.sort(key=lambda x: -x[0])
    return [t for _, t in scored[:limit]]


def answer_for(q: str):
    """(text, related) when the whole question asks what a known term is or means, else None (so data questions never land here)."""
    m = DEFINE.match(q.strip())
    if not m or DYNAMIC.search(q):
        return None
    x = m.group("x").strip()
    if len(x.split()) > 5:
        return None
    hits = find_terms(x, 3)
    if not hits:
        return None
    top = hits[0]
    return f"{top['term']}: {top['text']}", [{"id": h["id"], "title": h["term"], "question": f"What is {h['term'].split(' (')[0]}?"} for h in hits[1:]]
