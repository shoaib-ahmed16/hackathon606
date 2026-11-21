"""Ask: questions about the live picture.
 * Predefined questions are answered deterministically from the database (Q1-Q4 plus deadlines, approvals, summary, message drafts).
 * Free text goes to Claude when ANTHROPIC_API_KEY is set, grounded ONLY on facts read from the database; otherwise a clear
   fallback lists what can be asked. Nothing the assistant says is stored as data, and every question is audited.
"""
import json
import re
from datetime import timedelta

import anthropic
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from . import config
from .db import fetch, live_scenario_id, view
from .deps import actor
from .routes_console import deadlines, local, now_utc, scn, z

r = APIRouter(prefix="/api", tags=["ask"])
REG = re.compile(r"\bA6-?[A-Z]{3}\b", re.I)
FLT = re.compile(r"\bG9\d{3,4}D?\b", re.I)


class Ask(BaseModel):
    question: str
    scenario_id: int | None = None
    case_id: int | None = None


def _flights(s, c):
    return view("v_flight_watch", {"scenario_id": s, "case_id": c}, limit=2000)


def _find(flights, q):
    m = FLT.search(q)
    if m:
        return next((f for f in flights if f["flight_no"].upper() == m.group(0).upper()), None)
    m = REG.search(q)
    if m:
        reg = m.group(0).upper().replace("A6", "A6-").replace("A6--", "A6-")
        return next((f for f in flights if (f["registration"] or "").upper() == reg), None)
    return None


# ---- predefined answers: each returns (text, source)
def a_crew_next(s, c, q, flights):
    rows = fetch("SELECT * FROM v_crew_legality_ranking v WHERE v.scenario_id = %s AND v.minutes_until_legal_end >= 0 AND v.duty_id IN (SELECT l.duty_id FROM crew_duty_leg l JOIN case_flight cf ON cf.flight_id = l.flight_id WHERE l.scenario_id = %s AND l.is_active AND cf.case_id = %s)", (s, s, c))
    seen, uniq = set(), []
    for x in sorted(rows, key=lambda x: (x["minutes_until_legal_end"], ["CP", "FO", "SO", "CS", "CC"].index(x["position_code"]) if x["position_code"] in ["CP", "FO", "SO", "CS", "CC"] else 9)):
        if x["duty_id"] not in seen:
            seen.add(x["duty_id"]); uniq.append(x)
    rows = uniq[:3]
    if not rows:
        return "No crew on this case's flights is approaching its legal limit right now.", "v_crew_legality_ranking"
    lines = [f"{x['position_code']} {x['full_name']} on {x['duty_legs']}: legal end {z(x['legal_end_utc'])} ({local(x['legal_end_utc'])} SHJ) in {x['minutes_until_legal_end']} min, margin {x['margin_hhmm']}, status {x['status']}" for x in rows]
    return "Crew running out of legal duty next:\n" + "\n".join(f"{i + 1}. {t}" for i, t in enumerate(lines)), "v_crew_legality_ranking ORDER BY minutes_until_legal_end"


def a_aircraft(s, c, q, flights):
    m = REG.search(q)
    if not m:
        return "Tell me the registration, for example: Where is A6-ARJ and what is it waiting for?", "v_aircraft_whereabouts"
    reg = m.group(0).upper().replace("A6-", "A6").replace("A6", "A6-")
    rows = fetch("SELECT * FROM v_aircraft_whereabouts WHERE scenario_id = %s AND registration = %s", (s, reg))
    if not rows:
        return f"I have no position record for {reg} in this scenario.", "v_aircraft_whereabouts"
    x = rows[0]
    t = f"{reg}: {x['position_text']}. Waiting for: {str(x['waiting_for']).replace('_', ' ').lower()}."
    if x["next_flight"]:
        t += f" Next flight {x['next_flight']} {x['next_dep']} to {x['next_arr']}" + (f", latest legal departure {z(x['next_latest_legal_departure_utc'])}." if x["next_latest_legal_departure_utc"] else ".")
    if x["position_unverified"]:
        t += " Warning: the position has not been confirmed for over 30 minutes after its ETA."
    return t, "v_aircraft_whereabouts"


def a_leave_by(s, c, q, flights):
    f = _find(flights, q)
    if not f:
        return "Tell me the flight, for example: What time must G9464 leave to land legal?", "v_flight_watch"
    if not f["latest_legal_offblocks_utc"]:
        return f"{f['flight_no']} has no latest-departure calculation yet (it may not need one, or crew data is missing).", "v_flight_watch"
    t = f"{f['flight_no']} must be off-blocks by {z(f['latest_legal_offblocks_utc'])} ({local(f['latest_legal_offblocks_utc'])} SHJ)"
    if f["operational_target_utc"]:
        t += f"; operational target {z(f['operational_target_utc'])}"
    if f["discretion_end_utc"]:
        t += f"; crew legal end {z(f['legal_end_utc'])}, with commander discretion until {z(f['discretion_end_utc'])}"
    return t + ".", "v_flight_watch.latest_legal_offblocks_utc"


def a_replace(s, c, q, flights):
    f = _find(flights, q)
    if not f or not f["duty_id"]:
        return "Tell me the flight, for example: Who can replace the G9464 captain without breaking rosters?", "standby_candidates()"
    pos = "FO" if re.search(r"\b(f/?o|first officer)\b", q, re.I) else "CP"
    st = f["diverted_to"] or f["dep_iata"]
    rows = fetch("SELECT * FROM standby_candidates(%s,%s,%s,%s,%s)", (s, f["duty_id"], pos, st, 1))
    ok = [x for x in rows if x["verdict"] == "CANDIDATE"][:3]
    if not ok:
        return f"No roster-safe {pos} standby is available for {f['flight_no']} at {st}.", "standby_candidates()"
    lines = [f"{x['full_name']} ({x['pattern_name']}, {'LVP' if x['lvp_qualified'] else 'no LVP'}, positioning {x['positioning_min']} min, FDP margin {x['margin_min']} min)" for x in ok]
    return f"{pos} candidates for {f['flight_no']} at {st} (legal for the remaining legs, no roster conflict):\n" + "\n".join(f"- {t}" for t in lines), "standby_candidates()"


def a_deadline(s, c, q, flights):
    now = now_utc(s)
    d = sorted([x for x in deadlines(c, s)["items"] if x["deadline_utc"]], key=lambda x: x["deadline_utc"])
    verify = [x for x in deadlines(c, s)["items"] if not x["deadline_utc"]]
    up = [x for x in d if x["deadline_utc"] >= now]
    over = [x for x in d if x["deadline_utc"] < now]
    if not up and not over:
        return "No flight has a computed deadline right now.", "deadlines"
    lines = []
    if up:
        top = up[0]
        mins = int((top["deadline_utc"] - now).total_seconds() // 60)
        lines.append(f"Next deadline: {top['flight_no']} - {top['reason']} at {z(top['deadline_utc'])} ({local(top['deadline_utc'])} SHJ), in {mins} min.")
        lines += [f"- {w}" for w in top["why"]]
        if len(up) > 1:
            lines.append("Then: " + "; ".join(f"{x['flight_no']} {z(x['deadline_utc'])}" for x in up[1:4]))
    if over:
        lines.append("Already passed: " + "; ".join(f"{x['flight_no']} ({x['reason'].lower()}, {z(x['deadline_utc'])})" for x in over))
    if verify:
        lines.append("Cannot compute a deadline (fuel not reported): " + ", ".join(x["flight_no"] for x in verify))
    return "\n".join(lines), "deadlines (v_flight_watch + flight_decision_inputs + rank_alternates)"


def a_pending(s, c, q, flights):
    rows = fetch("SELECT flight_no, decision_type, alternate_iata, decided_by, decided_role, decided_at FROM v_decision_log WHERE scenario_id = %s AND case_id = %s AND status = 'PROPOSED' ORDER BY decided_at", (s, c))
    if not rows:
        return "Nothing is waiting for approval.", "v_decision_log"
    return f"{len(rows)} decision(s) waiting for approval:\n" + "\n".join(f"- {x['flight_no']}: {x['decision_type']} {x['alternate_iata'] or ''} proposed by {x['decided_by']} ({x['decided_role']}) at {z(x['decided_at'])}" for x in rows), "v_decision_log WHERE status = PROPOSED"


def a_summary(s, c, q, flights):
    now = now_utc(s)
    hub_iata = fetch("SELECT hub_iata FROM disruption_case WHERE case_id = %s", (c,))[0]["hub_iata"]
    hub = fetch("SELECT * FROM v_airport_status_current WHERE scenario_id = %s AND iata = %s", (s, hub_iata))
    shj = hub[0] if hub else None
    cnt = lambda fn: sum(1 for f in flights if fn(f))  # noqa: E731
    t = f"As of {z(now)} ({local(now)} SHJ): {len(flights)} flights on watch. "
    if shj:
        t += f"{shj['iata']} is {shj['op_status']}" + (f", LVP in force" if shj["lvp_in_force"] else "") + (f", reopening forecast {z(shj['expected_reopen_utc'])}." if shj["expected_reopen_utc"] else ".") + " "
    t += f"{cnt(lambda f: f['is_holding'])} holding, {cnt(lambda f: f['diverted_to'])} diverted, {cnt(lambda f: f['crew_status'] in ('AT_RISK', 'EXCEEDED', 'DISCRETION_REQUIRED'))} with crew at risk or over limit, {cnt(lambda f: f['decision_status'] == 'PROPOSED')} decisions waiting for approval."
    return t, "v_flight_watch + v_airport_status_current"


def a_draft(s, c, q, flights):
    f = _find(flights, q)
    if not f:
        return "Tell me the flight, for example: Draft a message to RKT station about G9464.", "v_flight_watch"
    st = (re.search(r"\b([A-Z]{3})\s+station\b", q, re.I) or [None, f["diverted_to"] or f["dep_iata"]])[1].upper()
    by = f["latest_legal_offblocks_utc"]
    body = f"{st} ops: {f['flight_no']} ({f['registration']}) " + (f"must be off-blocks by {z(by)} ({local(by)} SHJ) for crew legality. Please confirm the aircraft is ready, or advise immediately. - OCC" if by else "status check requested. Please confirm aircraft and crew readiness. - OCC")
    return "Draft (review before sending):\n" + body, "v_flight_watch"


ROUTES = [
    ("crew_next", re.compile(r"(crew.*(run out|runs out|time out|times out|legal.*next|next))|(legal.*next)|(who.*(time|run)s? out)", re.I), a_crew_next),
    ("deadline", re.compile(r"(next|first|urgent).*(deadline|decision)|what.*(next|urgent)|deadline", re.I), a_deadline),
    ("draft", re.compile(r"\bdraft\b|\bmessage\b", re.I), a_draft),
    ("replace", re.compile(r"replace|replacement|standby|alternate crew|relief", re.I), a_replace),
    ("leave_by", re.compile(r"(what time|when).*(leave|depart|off-?blocks)|must leave|latest.*(depart|leave)", re.I), a_leave_by),
    ("aircraft", re.compile(r"\bwhere\b.*\b(A6-?[A-Z]{3}|aircraft|tail)\b|waiting for", re.I), a_aircraft),
    ("pending", re.compile(r"approval|waiting for me|pending", re.I), a_pending),
    ("summary", re.compile(r"summar|situation|overview|status of|how are we", re.I), a_summary),
]


@r.get("/ask/questions")
def questions(case_id: int | None = None, scenario_id: int | None = None):
    """Suggested questions, filled with real flights and registrations from the case."""
    ex = {"flight": "G9464", "reg": "A6-ARJ", "st": "RKT"}
    if case_id:
        fl = _flights(scn(scenario_id), case_id)
        d = next((f for f in fl if f["diverted_to"]), None) or (fl[0] if fl else None)
        if d:
            ex = {"flight": d["flight_no"], "reg": d["registration"] or ex["reg"], "st": d["diverted_to"] or d["dep_iata"]}
    return {"ai": bool(config.ANTHROPIC_API_KEY), "model": config.ASK_MODEL if config.ANTHROPIC_API_KEY else None, "items": [
        "Which crew runs out of legality next?",
        "What is the next deadline?",
        f"Where is {ex['reg']} and what is it waiting for?",
        f"What time must {ex['flight']} leave to land legal?",
        f"Who can replace the {ex['flight']} captain without breaking rosters?",
        "What is waiting for approval?",
        "Summarise the situation",
        f"Draft a message to {ex['st']} station about {ex['flight']}",
    ]}


def _facts(s, c, flights):
    """Compact, factual snapshot sent to Claude. Only database content, no free-form opinions."""
    now = now_utc(s)
    dl = {x["flight_id"]: x for x in deadlines(c, s)["items"]}
    return {
        "now_utc": z(now), "now_shj_local": local(now), "scenario_id": s, "case_id": c,
        "airports": [{k: (str(v) if k.endswith("utc") else v) for k, v in a.items() if k in ("iata", "op_status", "reason", "visibility_m", "lvp_in_force", "arrival_capacity_per_hr", "parking_available", "expected_reopen_utc", "quality")} for a in fetch("SELECT * FROM v_airport_status_current WHERE scenario_id = %s", (s,))],
        "flights": [{
            "flight": f["flight_no"], "reg": f["registration"], "route": f"{f['dep_iata']}-{f['planned_arr_iata']}", "status": f["status"], "eta_z": z(f["eta_utc"]) if f["eta_utc"] else None,
            "diverted_to": f["diverted_to"], "waiting_for": f["waiting_for"], "crew_status": f["crew_status"], "crew_margin_min": f["crew_margin_min"], "crew_legal_end_z": z(f["legal_end_utc"]) if f["legal_end_utc"] else None,
            "lvp_required": f["lvp_required"], "lvp_crew_ok": f["lvp_crew_ok"], "recommendation": f["recommendation"], "recommended_alternate": f["recommended_alternate"], "confidence": f["confidence"],
            "decision": f["last_decision"], "decision_status": f["decision_status"], "latest_legal_departure_z": z(f["latest_legal_offblocks_utc"]) if f["latest_legal_offblocks_utc"] else None,
            "deadline_z": z(dl[f["flight_id"]]["deadline_utc"]) if f["flight_id"] in dl and dl[f["flight_id"]]["deadline_utc"] else None, "deadline_reason": dl.get(f["flight_id"], {}).get("reason"),
            "open_data_exceptions": f["open_exceptions"],
        } for f in flights[:60]],
        "crew_next_to_time_out": [{"name": x["full_name"], "position": x["position_code"], "legs": x["duty_legs"], "legal_end_z": z(x["legal_end_utc"]), "minutes": x["minutes_until_legal_end"], "status": x["status"]} for x in fetch("SELECT * FROM v_crew_legality_ranking v WHERE v.scenario_id = %s AND v.minutes_until_legal_end >= 0 AND v.duty_id IN (SELECT l.duty_id FROM crew_duty_leg l JOIN case_flight cf ON cf.flight_id = l.flight_id WHERE l.scenario_id = %s AND l.is_active AND cf.case_id = %s) ORDER BY v.minutes_until_legal_end LIMIT 8", (s, s, c))],
        "decisions_waiting_for_approval": [{"flight": x["flight_no"], "decision": x["decision_type"], "alternate": x["alternate_iata"], "by": x["decided_by"]} for x in fetch("SELECT * FROM v_decision_log WHERE scenario_id = %s AND case_id = %s AND status = 'PROPOSED'", (s, c))],
    }


SYSTEM = """You are the decision-support assistant inside an airline operations console for fog disruption at Sharjah (SHJ).
Answer ONLY from the FACTS JSON in the user message. If the facts do not contain the answer, say you do not have that information
and name the screen or data that would hold it. Never invent flights, times, crew, fuel or rules. Quote times as 24h UTC with a Z
and give SHJ local time (UTC+4) in brackets. Be brief and operational: lead with the answer, then the one or two facts behind it.
You recommend and explain; people decide. Never state that a decision has been made or an action executed."""


def _claude(question, facts):
    client = anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)
    kwargs = dict(model=config.ASK_MODEL, max_tokens=1200, system=SYSTEM,
                  messages=[{"role": "user", "content": f"FACTS:\n{json.dumps(facts, default=str)}\n\nQUESTION: {question}"}],
                  output_config={"effort": "low"})
    try:  # server-side refusal fallback (recommended for these models); older SDKs without the parameter just skip it
        msg = client.beta.messages.create(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs)
    except TypeError:
        msg = client.messages.create(**kwargs)
    if msg.stop_reason == "refusal":
        return "The assistant declined to answer that question."
    return "".join(b.text for b in msg.content if getattr(b, "type", "") == "text").strip() or "No answer was returned."


@r.post("/ask")
def ask(b: Ask, user=Depends(actor)):
    s = scn(b.scenario_id)
    if not b.case_id:
        return {"mode": "none", "answer": "Select a case first.", "source": None}
    flights = _flights(s, b.case_id)
    q = b.question.strip()
    for qid, rx, fn in ROUTES:
        if rx.search(q):
            text, src = fn(s, b.case_id, q, flights)
            return {"mode": "predefined", "question_id": qid, "answer": text, "source": f"Answered from {src}"}
    if config.ANTHROPIC_API_KEY:
        try:
            return {"mode": "ai", "answer": _claude(q, _facts(s, b.case_id, flights)), "source": f"AI ({config.ASK_MODEL}), grounded on this case's database facts only"}
        except anthropic.AuthenticationError:
            return {"mode": "error", "answer": "The Claude API key was rejected. Check ANTHROPIC_API_KEY on the server.", "source": None}
        except anthropic.RateLimitError:
            return {"mode": "error", "answer": "The assistant is rate limited right now. Try again in a moment.", "source": None}
        except anthropic.APIError as e:
            return {"mode": "error", "answer": f"The assistant is unavailable ({type(e).__name__}). The predefined questions still work.", "source": None}
    return {"mode": "fallback", "answer": "I can answer the suggested questions from the live data. Free-text questions need the Claude API key, which is not configured on this server yet.", "source": None}
