"""Read models and actions behind the OCC console: deadlines, flight explanation, briefing, what-if, recovery plan edits.
Everything is computed from database rows (the Excel data and what operators entered). Nothing is invented here."""
import json
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from .db import fetch, live_scenario_id, tx, view
from .plain import humanize
from .deps import actor
from .routes_write import agent_user_id

r = APIRouter(prefix="/api", tags=["console"])


def scn(s):
    return s if s is not None else live_scenario_id()


def now_utc(scenario_id):
    return fetch("SELECT scenario_now(%s) AS t", (scenario_id,))[0]["t"]


def z(ts):
    return ts.astimezone(timezone.utc).strftime("%H:%MZ") if ts else "-"


def local(ts):
    return (ts.astimezone(timezone.utc) + timedelta(hours=4)).strftime("%H:%M") if ts else "-"


# ------------------------------------------------------------------ deadlines
@r.get("/deadlines")
def deadlines(case_id: int, scenario_id: int | None = None):
    """Next hard deadline per flight, from the engine's own numbers:
    airborne/holding -> last moment to divert on fuel; diverted -> latest legal departure; on ground -> latest legal departure."""
    s = scn(scenario_id)
    now = now_utc(s)
    out = []
    for f in view("v_flight_watch", {"scenario_id": s, "case_id": case_id}, limit=2000):
        d = None
        status, fid = f["status"], f["flight_id"]
        if f["diverted_to"] and f["diversion_status"] not in ("DEPARTED", "CLOSED", "CANCELLED"):
            alt, hub = f["diverted_to"], f["planned_arr_iata"] or f["arr_iata"]
            lat, disc = f["latest_legal_offblocks_utc"], f["latest_with_discretion_utc"]
            in_air = status in ("DIVERTING", "AIRBORNE")
            landing = f["eta_utc"] if in_air else f.get("ata_utc")
            # a latest-legal-departure that is EARLIER than the landing is not a deadline anyone can meet: say what is true instead
            words = None
            if lat and landing and lat < landing:
                words = f"Crew cannot fly {alt}→{hub} legally." + (f" Options: commander discretion until {z(disc)}, or replace the crew." if disc and disc > landing else " Option: replace the crew.")
            if in_air:
                d = {"deadline_utc": None, "kind": "diverting", "reason": f"Diverting to {alt}, landing about {z(landing)}",
                     "why": [f"The aircraft is flying to {alt}: landing about {z(landing)} ({local(landing)} SHJ)",
                             words or (f"Latest legal departure from {alt}: {z(lat)}" if lat else "Crew legality for the return is not available yet")]}
            elif words:
                d = {"deadline_utc": None, "kind": "crew", "reason": f"Crew cannot fly {alt}→{hub} legally",
                     "why": [words, f"Crew legal end {z(f['legal_end_utc'])} ({local(f['legal_end_utc'])} SHJ)" if f["legal_end_utc"] else "Crew legal end not available"]}
            elif lat:
                why = [
                    f"Crew legal end {z(f['legal_end_utc'])} ({local(f['legal_end_utc'])} SHJ)" if f["legal_end_utc"] else "Crew legal end not available",
                    f"Latest legal off-blocks from {f['departure_from_iata'] or alt}: {z(lat)} (legal end minus return block time)",
                    f"Operational target {z(f['operational_target_utc'])} (includes the operational buffer)",
                ]
                d = {"deadline_utc": lat, "kind": "departure", "reason": f"Latest legal departure from {alt}", "why": why}
        elif status in ("AIRBORNE", "HOLDING", "DIVERTING"):
            inp = fetch("SELECT * FROM flight_decision_inputs(%s,%s)", (s, fid))
            inp = inp[0] if inp else {}
            end = inp.get("endurance_left_min")
            if end is None:
                d = {"deadline_utc": None, "kind": "verify", "reason": "Fuel endurance not reported", "why": ["No holding-endurance estimate has been entered, so neither holding nor a diversion can be marked executable."]}
            else:
                opts = [o for o in fetch("SELECT * FROM rank_alternates(%s,%s)", (s, fid)) if o["is_executable"] and o["fuel_margin_min"] is not None]
                # The deadline belongs to the alternate the engine RECOMMENDS (else the top-ranked executable one), never to a different
                # alternate with more spare fuel: that would give the duty manager minutes that do not exist for the recommended option.
                best = next((o for o in opts if o["alt_iata"] == f.get("recommended_alternate")), None) or (min(opts, key=lambda o: o["rank"]) if opts else None)
                if best:
                    d = {"deadline_utc": (inp["endurance_until"] - timedelta(minutes=end - best["fuel_margin_min"])) if inp.get("endurance_until") and inp["endurance_until"] > now + timedelta(seconds=2) else now + timedelta(minutes=best["fuel_margin_min"]), "kind": "divert", "reason": f"Last moment to divert to {best['alt_iata']} on fuel",
                         "why": [f"Holding endurance {end} min (quality: {str(inp.get('fuel_quality')).lower()})", f"Flight time to {best['alt_iata']} about {best['est_flight_min']} min ({round(float(best['distance_km']))} km plus approach)",
                                 f"Spare fuel on arrival at {best['alt_iata']} if diverting now: {best['fuel_margin_min']} min, so the decision can wait about that long",
                                 f"SHJ reopening {z(inp.get('reopen_utc'))} ({str(inp.get('reopen_quality')).lower()})" if inp.get("reopen_utc") else "No reopening forecast on record"]}
                else:
                    # Fuel is estimated to be at or below final reserve already: the moment it crossed is not known (the estimate stops at "now"), so there is no
                    # countdown to show. A moving "deadline = now" restarted the timer at 0 on every refresh; it is flagged instead and shown as a fixed state.
                    eu = inp.get("endurance_until")
                    if end <= 0 or not eu or eu <= now + timedelta(seconds=2):
                        d = {"deadline_utc": None, "kind": "fuel", "at_reserve": True, "reason": "Fuel at or below final reserve (estimate)",
                             "why": ["The estimated fuel on board is at or below the final reserve and no alternate is executable.", "Verify the position and fuel with the crew now. Escalate to the OCC duty manager."]}
                    else:
                        d = {"deadline_utc": eu, "kind": "fuel", "reason": "Fuel runs out (no executable alternate)", "why": [f"Holding endurance {end} min and no alternate is executable. Escalate to the OCC duty manager."]}
        elif f["latest_legal_offblocks_utc"] and status in ("SCHEDULED", "TAXI_OUT"):
            d = {"deadline_utc": f["latest_legal_offblocks_utc"], "kind": "departure", "reason": "Latest legal departure", "why": [f"Crew legal end {z(f['legal_end_utc'])}", f"Latest legal off-blocks {z(f['latest_legal_offblocks_utc'])}"]}
        if d:
            out.append({"flight_id": fid, "flight_no": f["flight_no"], **d})
    return {"now_utc": now, "items": out}


# ------------------------------------------------------------------ flight explanation
@r.get("/flights/{flight_id}/detail")
def flight_detail(flight_id: int, case_id: int, scenario_id: int | None = None):
    s = scn(scenario_id)
    fl = view("v_flight_watch", {"scenario_id": s, "case_id": case_id, "flight_id": flight_id})
    if not fl:
        raise HTTPException(404, "Flight not in this case")
    f = fl[0]
    # an open (PROPOSED) recommendation always wins over an executed (ACCEPTED) one, so the card never shows the reasoning of a decision that is done
    rec = fetch(
        """SELECT rec_id, rec_type, confidence, rationale, assumptions, uncertainty, generated_by, generated_at, required_approver_role, status
             FROM recommendation WHERE scenario_id = %s AND flight_id = %s AND status IN ('PROPOSED','ACCEPTED')
            ORDER BY (status = 'PROPOSED') DESC, generated_at DESC LIMIT 1""",
        (s, flight_id),
    )
    crew = fetch(
        """SELECT cm.crew_id, cm.full_name, ca.position_code,
                  EXISTS (SELECT 1 FROM crew_qualification q WHERE q.crew_id = cm.crew_id AND q.qual_code = 'LVP') AS lvp
             FROM crew_duty_leg l JOIN crew_assignment ca ON ca.duty_id = l.duty_id AND ca.scenario_id = l.scenario_id AND ca.valid_to IS NULL
             JOIN crew_member cm ON cm.crew_id = ca.crew_id
            WHERE l.scenario_id = %s AND l.flight_id = %s AND l.is_active
            ORDER BY array_position(ARRAY['CP','FO','SO','CS','CC','SEC','EN'], ca.position_code), cm.full_name""",
        (s, flight_id),
    )
    fdp = fetch(
        """SELECT fc.sign_in_utc, fc.band_tz, fc.sign_in_local_time, fc.legs_counted, fc.max_fdp_min, fc.legal_end_utc, fc.discretion_end_utc,
                  fc.projected_end_utc, fc.margin_min, fc.status, fr.source_rule_id, fr.local_start_from, fr.local_start_to, rs.name AS rule_set, rs.version
             FROM fdp_calculation fc LEFT JOIN fdp_rule fr ON fr.rule_id = fc.rule_id LEFT JOIN rule_set rs ON rs.rule_set_id = fc.rule_set_id
            WHERE fc.scenario_id = %s AND fc.duty_id = %s AND fc.is_current AND fc.crew_id IS NULL LIMIT 1""",
        (s, f["duty_id"]),
    ) if f["duty_id"] else []
    pax = fetch("SELECT coalesce(sum(pax_count),0) AS n FROM pax_connection_valid WHERE inbound_flight_id = %s", (flight_id,))[0]["n"]
    ld = fetch("SELECT assumptions, block_time_min, block_time_basis FROM latest_departure_calc WHERE scenario_id=%s AND is_current AND flight_id=%s ORDER BY calculated_at DESC LIMIT 1", (s, f["recovery_flight_id"] or flight_id))
    # what each option would do, from the engine's own ranking
    conseq = {}
    try:
        inp = fetch("SELECT * FROM flight_decision_inputs(%s,%s)", (s, flight_id))
        inp = inp[0] if inp else {}
        for o in fetch("SELECT * FROM rank_alternates(%s,%s)", (s, flight_id)):
            alt, lines = o["alt_iata"], []
            lines.append(["✓", f"Creates recovery flight {f['flight_no']}D {alt} to {f['planned_arr_iata']}"])
            if inp.get("legal_end_now") and inp.get("legal_end_if_diverted"):
                lines.append(["!", f"Adds 1 sector for every operating crew member: legal end {z(inp['legal_end_now'])} to {z(inp['legal_end_if_diverted'])}"])
            if o["crew_return_margin_min"] is not None:
                lines.append(["!" if o["crew_return_margin_min"] < 0 else "✓", ("Return to the hub needs commander discretion or a replacement crew" if o["crew_return_margin_min"] < 0 else f"Crew can fly the return legally (margin {o['crew_return_margin_min']} min)")])
            if o["stands_left"] is not None:
                lines.append(["!" if o["stands_left"] <= 2 else "✓", f"{alt} stands {o['stands_left']} to {max(0, o['stands_left'] - 1)}"])
            if o["fuel_margin_min"] is not None:
                lines.append(["!" if o["fuel_margin_min"] < 15 else "✓", f"Spare fuel on arrival {o['fuel_margin_min']} min"])
            if pax:
                lines.append(["i", f"{pax} connecting passengers affected"])
            for c in (o["blocking_constraints"] or []):
                lines.append(["✕" if not c.get("verify") else "?", str(c.get("code", "")).replace("_", " ").lower()])
            conseq[alt] = lines
        hold = [["✓", "Stays in the arrival sequence"]]
        if inp.get("endurance_left_min") is not None:
            hold.append(["!" if inp["endurance_left_min"] < 30 else "✓", f"Holding endurance {inp['endurance_left_min']} min ({str(inp.get('fuel_quality')).lower()})"])
        if inp.get("reopen_utc"):
            hold.append(["i", f"Hub reopening {z(inp['reopen_utc'])} ({str(inp.get('reopen_quality')).lower()})"])
        if pax:
            hold.append(["i", f"{pax} connecting passengers waiting"])
        conseq["HOLD"] = hold
    except Exception:  # noqa: BLE001 - not an airborne flight: no options to preview
        conseq = {}
    why = []
    if fdp:
        x = fdp[0]
        why = [
            f"Crew signed in {z(x['sign_in_utc'])} ({local(x['sign_in_utc'])} SHJ), FDP band {x['band_tz']} local start {x['sign_in_local_time']}",
            f"{x['legs_counted']} sector(s) counted, maximum FDP {x['max_fdp_min'] // 60}h {x['max_fdp_min'] % 60:02d}m" + (f" (rule {x['source_rule_id']}, {x['rule_set']} {x['version']})" if x["rule_set"] else ""),
            f"Legal end {z(x['legal_end_utc'])}; with commander discretion +3h: {z(x['discretion_end_utc'])}",
        ]
        if ld:
            why.append(f"Return block time: {ld[0]['block_time_basis']}" if ld[0]["block_time_basis"] else "Return block time not available")
    return {"flight": f, "recommendation": rec[0] if rec else None, "crew": crew, "fdp": fdp[0] if fdp else None, "connecting_pax": pax,
            "assumptions": (ld[0]["assumptions"] if ld else None), "why": why, "consequences": conseq}


# ------------------------------------------------------------------ briefing
@r.get("/briefing")
def briefing(case_id: int, scenario_id: int | None = None, since: datetime | None = None, limit: int = Query(12, le=50)):
    """What changed since the operator last looked: the newest timeline entries (decisions, status, recommendations)."""
    s = scn(scenario_id)
    now = now_utc(s)
    rows = fetch(
        """SELECT occurred_at, stream, actor, actor_role, entity_type, summary FROM v_case_timeline
            WHERE case_id = %s AND (%s::timestamptz IS NULL OR occurred_at > %s::timestamptz)
              AND entity_type IN ('decision','decision_approval','airport_status_event','diversion','crew_replacement','case_comment','recovery_plan','disruption_case')
            ORDER BY occurred_at DESC LIMIT %s""",
        (case_id, since, since, limit),
    )
    recs = fetch(
        """SELECT count(*) FILTER (WHERE generated_at > %s::timestamptz) AS n FROM recommendation WHERE scenario_id = %s""",
        (since or datetime(1970, 1, 1, tzinfo=timezone.utc), s),
    )[0]["n"]
    return {"now_utc": now, "since": since, "new_recommendations": recs, "items": list(reversed(humanize(rows)))}


# ------------------------------------------------------------------ what-if
class WhatIf(BaseModel):
    scenario_id: int | None = None
    case_id: int
    reopen_shift_min: int = 45
    name: str | None = None


@r.post("/whatif")
def whatif(b: WhatIf, user=Depends(actor)):
    """Run the engine in a separate WHATIF copy with the hub reopening moved, and compare with the current picture.
    Nothing in the live scenario changes."""
    s = scn(b.scenario_id)
    with tx(user) as conn:
        case = conn.execute("SELECT * FROM disruption_case WHERE case_id = %s", (b.case_id,)).fetchone()
        if not case:
            raise HTTPException(404, "Unknown case")
        hub = case["hub_iata"]
        st = conn.execute("SELECT * FROM v_airport_status_current WHERE scenario_id = %s AND iata = %s", (s, hub)).fetchone()
        if not st:
            raise HTTPException(409, f"{hub} has no airport status in this scenario to build a what-if from.")
        name = b.name or f"WHATIF reopen {b.reopen_shift_min:+d} min ({datetime.utcnow():%H:%M:%S})"
        new_scn = conn.execute("SELECT clone_scenario(%s, %s, 'WHATIF') AS id", (s, name)).fetchone()["id"]
        # the bulk copy queues recalculation jobs; this request runs the engine itself, so the worker must not race it
        conn.execute("UPDATE reassessment_queue SET status = 'DONE', done_at = now(), error = 'what-if clone baseline' WHERE scenario_id = %s AND status = 'PENDING'", (new_scn,))
    with tx(user) as conn:
        stamp = conn.execute("SELECT scenario_now(%s) AS t", (new_scn,)).fetchone()["t"]
        # a forecast reopening is shifted; an open airport is closed again until now + shift (LVP in force)
        had_reopen = st["expected_reopen_utc"] is not None
        new_reopen = (st["expected_reopen_utc"] if had_reopen else stamp) + timedelta(minutes=b.reopen_shift_min)
        new_op, new_cap, new_lvp = (st["op_status"], st["arrival_capacity_per_hr"], st["lvp_in_force"]) if had_reopen else ("CLOSED", 0, True)
        conn.execute(
            """INSERT INTO airport_status_event (scenario_id, iata, op_status, reason, visibility_m, lvp_in_force, arrival_capacity_per_hr,
                      departure_capacity_per_hr, parking_available, effective_from_utc, expected_reopen_utc, quality, entered_by, note)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'SIMULATED',%s,%s)""",
            (new_scn, hub, new_op, st["reason"] if had_reopen else "FOG (what-if)", st["visibility_m"], new_lvp, new_cap, None, st["parking_available"],
             stamp, new_reopen, int(user), f"What-if: reopening {'moved' if had_reopen else 'closed until now'} {b.reopen_shift_min:+d} min"),
        )
        conn.execute("""INSERT INTO flight_fuel_estimate (scenario_id, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg, burn_rate_hold_kg_per_hr,
                                  est_holding_endurance_min, quality, basis, entered_by)
                        SELECT %s, flight_id, as_of_utc, fuel_on_board_kg, min_diversion_fuel_kg, burn_rate_hold_kg_per_hr, est_holding_endurance_min, quality, basis, entered_by
                          FROM flight_fuel_estimate WHERE scenario_id = %s""", (new_scn, s))
        new_case = conn.execute(
            "INSERT INTO disruption_case (scenario_id, title, hub_iata, cause, phase, opened_by) VALUES (%s,%s,%s,%s,'MONITORING',%s) RETURNING case_id",
            (new_scn, f"{case['title']} (what-if {b.reopen_shift_min:+d} min)", hub, case["cause"], int(user)),
        ).fetchone()["case_id"]
        conn.execute("INSERT INTO case_flight (case_id, flight_id, fog_exposure) SELECT %s, flight_id, fog_exposure FROM case_flight WHERE case_id = %s", (new_case, b.case_id))
        conn.execute("UPDATE reassessment_queue SET status = 'DONE', done_at = now(), error = 'what-if runs the engine itself' WHERE scenario_id = %s AND status = 'PENDING'", (new_scn,))
    with tx(agent_user_id()) as conn:
        for row in conn.execute(
            "SELECT cf.flight_id FROM case_flight cf JOIN flight_state fs ON fs.flight_id = cf.flight_id AND fs.scenario_id = %s WHERE cf.case_id = %s AND fs.status IN ('AIRBORNE','HOLDING')",
            (new_scn, new_case),
        ).fetchall():
            with conn.transaction():
                conn.execute("SELECT compute_flight_legality(%s,%s,'whatif')", (new_scn, row["flight_id"]))
                conn.execute("SELECT recommend_for_flight(%s,%s,%s)", (new_scn, new_case, row["flight_id"]))
    top = lambda sc: {x["flight_id"]: x for x in fetch(  # noqa: E731
        "SELECT flight_id, flight_no, action, alternate_iata, is_executable FROM v_recommendation_options WHERE scenario_id = %s AND rank = 1", (sc,))}
    live, alt = top(s), top(new_scn)
    rows = []
    for fid, a in alt.items():
        l = live.get(fid)
        la = f"{l['action']} {l['alternate_iata'] or ''}".strip() if l else "no recommendation"
        wa = f"{a['action']} {a['alternate_iata'] or ''}".strip()
        rows.append({"flight_no": a["flight_no"], "current": la, "what_if": wa, "changed": la != wa})
    rows.sort(key=lambda x: (not x["changed"], x["flight_no"]))
    return {"scenario_id": new_scn, "case_id": new_case, "shift_min": b.reopen_shift_min, "new_reopen_utc": new_reopen, "had_forecast": had_reopen, "rows": rows, "changed": sum(1 for x in rows if x["changed"])}


# ------------------------------------------------------------------ recovery plan edits
@r.post("/recovery/{plan_id}/approve")
def approve_plan(plan_id: int, user=Depends(actor)):
    with tx(user) as conn:
        role = conn.execute("SELECT r.can_approve FROM app_user u JOIN app_role r ON r.code = u.role_code WHERE u.user_id = %s", (int(user),)).fetchone()
        if not role or not role["can_approve"]:
            raise HTTPException(403, "Your role cannot approve recovery plans")
        rows = conn.execute("UPDATE recovery_plan SET status = 'APPROVED', approved_by = %s, approved_at = now() WHERE plan_id = %s AND status = 'PROPOSED' RETURNING *", (int(user), plan_id)).fetchall()
    if not rows:
        raise HTTPException(409, "Plan is not in PROPOSED status")
    return rows[0]


class SlotMove(BaseModel):
    proposed_slot_utc: datetime


@r.patch("/recovery/{plan_id}/items/{flight_id}")
def move_slot(plan_id: int, flight_id: int, b: SlotMove, user=Depends(actor)):
    """Move one flight to another arrival slot. Refused when the flight cannot arrive that early or the slot is taken."""
    with tx(user) as conn:
        it = conn.execute("SELECT i.*, p.status AS plan_status FROM recovery_plan_item i JOIN recovery_plan p USING (plan_id) WHERE i.plan_id = %s AND i.flight_id = %s", (plan_id, flight_id)).fetchone()
        if not it:
            raise HTTPException(404, "Flight is not in this plan")
        if it["plan_status"] != "PROPOSED":
            raise HTTPException(409, "Only a PROPOSED plan can be edited")
        if it["earliest_arrival_utc"] and b.proposed_slot_utc < it["earliest_arrival_utc"]:
            raise HTTPException(409, f"Not possible: this flight cannot arrive before {z(it['earliest_arrival_utc'])}")
        taken = conn.execute("SELECT 1 FROM recovery_plan_item WHERE plan_id = %s AND flight_id <> %s AND proposed_slot_utc = %s", (plan_id, flight_id, b.proposed_slot_utc)).fetchone()
        if taken:
            raise HTTPException(409, "That slot is already taken (one arrival per slot)")
        rows = conn.execute("UPDATE recovery_plan_item SET proposed_slot_utc = %s WHERE plan_id = %s AND flight_id = %s RETURNING *", (b.proposed_slot_utc, plan_id, flight_id)).fetchall()
    return rows[0]


# ------------------------------------------------------------------ diversion recovery plan (read-only)
@r.get("/recovery/diversions")
def diversion_recovery(case_id: int | None = None, scenario_id: int | None = None, min_connection_min: int = Query(30, ge=0, le=240)):
    """Per diverted flight: when the aircraft can return, whether the crew can legally fly it (standby options when not), and the
    connecting passengers who would miss their onward flight at the projected hub arrival. Read-only: the humans decide."""
    return fetch("SELECT * FROM diversion_recovery_plan(%s,%s,%s)", (scn(scenario_id), case_id, min_connection_min))
