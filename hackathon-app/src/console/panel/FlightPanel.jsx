import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import {
  useAddRecordMutation,
  useGetAlternatesQuery,
  useGetDownstreamQuery,
  useUpdateDiversionMutation,
  useGetFdpPreviewQuery,
  useMoveReportTimeMutation,
  useGetConnectionsQuery,
  useGetFuelCardQuery,
  useGetCommentsQuery,
  useGetFlightDetailQuery,
  useGetFlightLinksQuery,
  useGetFlightTimelineQuery,
  useGetFuelQuery,
  useAskForDataMutation,
  useSubscribeMutation,
  useUnsubscribeMutation,
  useRemoveTagMutation,
} from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Cd, Pill, Ribbon } from '../ui/ui';
import { AnswerSheet, ApproveSheet, ExecuteSheet, LinkSheet, ProposeSheet, RejectSheet, TagSheet, WithdrawSheet } from '../sheets/DecisionSheets';
import CrewFinderSheet from '../sheets/CrewFinderSheet';
import {
  MIN, REC_LABEL, REC_TONE, plainCodes, fmtZday, TAG_LABEL, currentDecision, decisionWhat, fmtTime, fmtZ, gapsOf, human, isAirborne, isRecovered, liveLabel, ms, roleLabel,
  sevClass, typeLabel, verdictPill,
} from '../lib';
import { useMinuteNow, useNow } from '@/hooks/useNow';

const QCLS = { FORECAST: 'q-forecast', ESTIMATED: 'q-estimated', MISSING: 'q-estimated', MEASURED: 'q-measured', SIMULATED: 'q-estimated', MANUAL: 'q-measured' };
const hhmm = (iso) => fmtZ(ms(iso));
const shortName = (l) => (l.code === 'CREW_SYSTEM' ? 'Crew system' : l.name);

// engine option row -> what the panel shows
const ACTION_TYPE = { HOLD: 'HOLD', DIVERT: 'DIVERT', DELAY_DEPARTURE: 'DELAY', RECOVER: 'RECOVER', CREW_REPLACE: 'CREW_REPLACE' };
const ACTION_WHAT = { HOLD: 'Keep holding', DELAY_DEPARTURE: 'Delay the departure', RECOVER: 'Depart the alternate now', CREW_REPLACE: 'Replace the crew' };
const optView = (o) => {
  const blockedWhy = (o.blocking_constraints ?? []).map((c) => human(c.code) + (c.margin_min != null ? ` (${c.margin_min} min)` : ''));
  return {
    rank: o.rank,
    option_id: o.option_id,
    type: ACTION_TYPE[o.action] ?? 'OTHER',
    alt: o.alternate_iata,
    what: o.action === 'DIVERT' ? `Divert to ${o.alternate_iata}${o.alternate_name ? ` (${o.alternate_name})` : ''}` : (ACTION_WHAT[o.action] ?? o.action),
    exec: o.is_executable,
    verify: o.needs_verification,
    score: o.score,
    margin: o.fuel_margin_min,
    why: o.is_executable ? (o.reasons ?? []).slice(0, 3) : blockedWhy.length ? blockedWhy : (o.reasons ?? []).slice(0, 1),
  };
};

function Decision({ d, f, list, cur, topOpt, gaps, openSheet }) {
  const log = cur ? d.decisions.find((l) => l.decision_id === cur.decision_id) : null;
  // an aircraft that has already diverted: its executed diversion IS the decision on record, not "no decision yet"
  const executed = f.diverted_to ? list.find((x) => x.decision_type === 'DIVERT' && x.status === 'EXECUTED') : null;
  const hist = list.filter((x) => x !== cur && x !== executed);
  const role = d.actor.role_code;
  const history = hist.length > 0 && (
    <details className="history">
      <summary>Earlier decisions ({hist.length})</summary>
      {hist.map((h) => (
        <div key={h.decision_id} style={{ marginTop: 6 }}>• {decisionWhat(h)}: <b>{h.status}</b> · {h.proposed_by} {hhmm(h.decided_at)}</div>
      ))}
    </details>
  );
  if (!cur) {
    let body;
    if (isRecovered(f)) body = <div className="dec-empty">No decision needed. Flight completed.</div>;
    else if (executed)
      body = (
        <>
          <div className="dec-empty">
            <Pill tone="legal">Diversion executed</Pill> {decisionWhat(executed)} · {executed.proposed_by} {hhmm(executed.decided_at)}. {f.status === 'DIVERTING' ? `The aircraft is flying to ${f.diverted_to}, landing about ${fmtZ(ms(f.eta_utc))}.` : `The aircraft is at ${f.diverted_to}.`}
          </div>
          <div className="dec-empty" style={{ marginTop: 6 }}>
            {gaps.length ? <>Next step: <b>resolve the data gaps below first</b>.</> : topOpt ? <>Next step at {f.diverted_to}: the engine's top option is <b>{topOpt.what}</b>.</> : 'No open decision at the alternate yet.'}
          </div>
        </>
      );
    else if (gaps.length) body = <div className="dec-empty">No decision can be proposed yet: <b>resolve the data gaps below first</b>. Options stay blocked until fuel is known.</div>;
    else if (!topOpt) body = <div className="dec-empty">No open decision. {f.recommendation ? '' : 'The engine has no recommendation for this flight.'}</div>;
    else
      body = (
        <>
          <div className="dec-empty">No decision yet. The engine's top option is <b>{topOpt.what}</b>.</div>
        </>
      );
    return (
      <div className="dec" data-src="decision + decision_approval + approval_policy">
        <div className="dec-top"><Pill tone="neutral">Decision</Pill></div>
        {body}
        {!isRecovered(f) && (
          <div className="ai-buttons" style={{ marginTop: 10 }}>
            {role === 'STATION' ? (
              <span className="k">Stations can comment and update status; they don't propose decisions.</span>
            ) : (
              <>
                {topOpt && !gaps.length && <button className="btn primary" onClick={() => openSheet({ kind: 'propose', opt: topOpt })}>Propose: {topOpt.what}</button>}
                {topOpt && !gaps.length && <button className="btn" onClick={() => document.getElementById('opts')?.scrollIntoView({ behavior: 'smooth', block: 'center' })}>Choose another option ↓</button>}
                <button className="btn ghost" onClick={() => openSheet({ kind: 'propose', opt: null })}>Record another decision…</button>
              </>
            )}
          </div>
        )}
        {history}
      </div>
    );
  }
  const waiting = cur.waiting_for;
  const apprBy = Object.fromEntries((log?.approvals ?? []).filter((a) => a.verdict === 'APPROVED').map((a) => [a.role, a]));
  let actions;
  if (cur.status === 'PROPOSED') {
    if (cur.can_approve)
      actions = (
        <>
          <button className="btn primary" onClick={() => openSheet({ kind: 'approve' })}>Review and approve as {roleLabel(role)}</button>
          <button className="btn danger" onClick={() => openSheet({ kind: 'reject' })}>Reject</button>
        </>
      );
    else if (cur.approved_roles.includes(role)) actions = <span className="k">You approved. Waiting for {waiting.map(roleLabel).join(', ')}.</span>;
    else actions = <span className="k">Waiting for {waiting.map(roleLabel).join(' and ')} approval.</span>;
  } else {
    actions = ['OCC', 'ADMIN'].includes(role)
      ? <><button className="btn primary" onClick={() => openSheet({ kind: 'execute' })}>Execute decision</button><span className="k">Approved by all required roles.</span></>
      : <span className="k">Approved. OCC executes.</span>;
  }
  return (
    <div className={`dec ${cur.status === 'PROPOSED' ? 'pending' : 'approved'}`} data-src="decision + decision_approval + approval_policy">
      <div className="dec-top">
        <Pill tone={cur.status === 'PROPOSED' ? 'risk' : 'legal'}>{cur.status === 'PROPOSED' ? 'Waiting for approval' : 'Approved'}</Pill>
        <span className="k">{typeLabel(cur.decision_type)} · {cur.followed_recommendation ? 'follows the engine' : <b className="c-risk">differs from the engine</b>}</span>
      </div>
      <div className="dec-title">{decisionWhat(cur)}</div>
      <div className="dec-meta">
        Proposed by {cur.proposed_by} ({roleLabel(cur.proposed_role)}) at {hhmm(cur.decided_at)} · “{cur.rationale}”
        {log?.details?.override_reason ? ` · Reason: ${log.details.override_reason}` : ''}
      </div>
      <div className="roles" aria-label="Required approvals">
        {cur.required_roles.map((r) => {
          const a = apprBy[r];
          const no = cur.rejected_roles.includes(r);
          return (
            <span key={r} className={`role ${a ? 'ok' : no ? 'no' : 'wait'}`}>
              {a ? '✓' : no ? '✕' : '⏳'} {roleLabel(r)}{a ? ` · ${a.by} ${a.at ? hhmm(a.at) : ''}` : ' · waiting'}
            </span>
          );
        })}
      </div>
      <div className="ai-buttons">
        {actions}
        {cur.can_withdraw && <button className="btn ghost" onClick={() => openSheet({ kind: 'withdraw' })} title="Take this proposal back (it stays in the record)">Withdraw</button>}
      </div>
      {history}
    </div>
  );
}

function Recs({ d, f, detail, opts, locked, openSheet }) {
  if (isRecovered(f)) return null;
  // two executable options with the same score: say so, and say which one needs the decision first (it leaves the hold earlier)
  const ex = opts.filter((o) => o.exec && o.score != null);
  const tied = new Set();
  let tieNote = null;
  if (ex.length > 1 && Math.abs(Number(ex[0].score) - Number(ex[1].score)) < 0.006) {
    ex.filter((o) => Math.abs(Number(o.score) - Number(ex[0].score)) < 0.006).forEach((o) => tied.add(o.rank));
    const a = ex[0];
    const b = ex[1];
    const sooner = a.margin != null && b.margin != null && a.margin !== b.margin ? (a.margin < b.margin ? a : b) : null;
    tieNote = `${a.alt ?? 'Option 1'} and ${b.alt ?? 'option 2'} score the same (${Number(a.score).toFixed(2)}). ${a.alt ?? 'Option 1'} is listed first on the engine's order; ${sooner ? `${sooner.alt} needs the decision sooner (it has ${sooner.margin} min of spare fuel against ${sooner === a ? b.margin : a.margin}).` : 'check the leave-the-hold-by time of each.'}`;
  }
  const rec = detail?.recommendation;
  const assumptions = (rec?.assumptions ?? []).map((a) => String(a));
  return (
    <div className="sec" data-src="v_recommendation_options · propose_hold_or_divert()">
      <h3>AI recommendations <span className="k">ranked · humans decide</span></h3>
      <div className="ai-card">
        <div className="ai-top">
          <span>Rationale {rec?.rec_type && <Pill tone={REC_TONE[rec.rec_type] ?? 'ai'}>{REC_LABEL[rec.rec_type] ?? rec.rec_type}</Pill>}</span>
          {rec?.confidence != null && (
            <span className="conf">Confidence {Math.round(rec.confidence * 100)}% <span className="conf-bar"><i style={{ width: `${rec.confidence * 100}%` }} /></span></span>
          )}
        </div>
        <p className="ai-why">{rec?.rationale ? plainCodes(rec.rationale) : 'No open recommendation for this flight.'}</p>
        {assumptions.length > 0 && (
          <div className="chips">
            {assumptions.map((a) => {
              const q = /quality:\s*(MEASURED|FORECAST|ESTIMATED|SIMULATED|MANUAL|MISSING)/i.exec(a)?.[1]?.toUpperCase();
              return <span key={a} className={`chip ${QCLS[q] ?? ''}`}>{a}</span>;
            })}
          </div>
        )}
        <div className="opts open" id="opts">
          {opts.length === 0 && <span className="k">No open options.</span>}
          {tieNote && <div className="tie-note k">{tieNote}</div>}
          {opts.map((o) => {
            const blocked = !o.exec;
            return (
              <button
                key={`${o.rank}-${o.alt ?? 'hold'}`}
                className={`opt ${blocked ? (o.verify ? 'blocked verify' : 'blocked') : ''}`}
                aria-disabled={blocked || locked}
                onClick={() => {
                  if (blocked) return toast((o.verify ? 'Blocked until verified: ' : 'Not executable: ') + (o.why[0] ?? ''));
                  if (locked) return toast(`A decision is already in progress for ${f.flight_no}`);
                  if (d.actor.role_code === 'STATION') return toast("Stations can't propose decisions");
                  openSheet({ kind: 'propose', opt: o });
                }}
              >
                <span className="rk">#{o.rank}</span>
                <span>
                  <span className="what">{o.what}</span>
                  {o.why.map((w) => (
                    <span key={w} className={`why ${blocked ? (o.verify ? 'vfy' : 'bad') : ''}`} style={{ display: 'block' }}>
                      {blocked ? (o.verify ? '? ' : '✕ ') : ''}{w}
                    </span>
                  ))}
                </span>
                <span className="sc">{o.exec ? `Score ${Number(o.score).toFixed(2)}` : o.verify ? 'Verify' : 'Blocked'}{tied.has(o.rank) && <span className="tie" title="Same score as another executable option">tie</span>}</span>
              </button>
            );
          })}
        </div>
        {locked && opts.length > 0 && d.actor.role_code !== 'STATION' && <p className="k" style={{ margin: '8px 0 0' }}>A decision is in progress above. New proposals wait until it is approved or rejected.</p>}
      </div>
    </div>
  );
}

function Gaps({ d, f, gaps, openSheet }) {
  const [ask] = useAskForDataMutation();
  const reqs = d.openRequests.filter((r) => r.flight_id === f.flight_id);
  // alternates that were asked about but are still unconfirmed
  const alt = (d.options ?? []).filter((o) => o.flight_id === f.flight_id && o.blocking_constraints?.some((c) => c.code === 'ALTERNATE_STATUS_UNKNOWN')).map((o) => o.alternate_iata);
  const altGaps = [...new Set(alt)].map((iata) => ({
    field: 'ALTERNATE_STATUS', iata, label: `${iata} status not confirmed`, sub: 'The engine keeps this alternate “verify first” until a station confirms it', ask: 'Ask station', to: 'STATION',
    open: reqs.find((r) => r.field === 'ALTERNATE_STATUS' && r.iata === iata),
  }));
  const all = [...gaps, ...altGaps];
  if (!all.length) return null;
  const role = d.actor.role_code;
  return (
    <div className="sec" data-src="data_request · v_recommendation_options">
      <h3>Missing data <span className="k">unknown is never treated as safe</span></h3>
      {all.map((x) => (
        <div key={`${x.field}-${x.iata ?? ''}`} className={`gap ${x.open ? 'open' : ''}`}>
          <span className="q">?</span>
          <span>
            <b>{x.label}</b>
            <span className="sub" style={{ display: 'block' }}>
              {x.open ? `Requested from ${roleLabel(x.open.requested_from_role)} · ${hhmm(x.open.created_at)} · open` : x.sub}
            </span>
          </span>
          <span className="ai-buttons">
            {!x.open && (
              <button
                className="btn"
                onClick={async () => {
                  try {
                    await ask({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, field: x.field, iata: x.iata }).unwrap();
                    toast.success(`Request sent to ${roleLabel(x.to)}. It stays open until answered.`);
                  } catch (e) {
                    toast.error(getErrorMessage(e));
                  }
                }}
              >
                {x.ask}
              </button>
            )}
            {(x.open ? role === x.open.requested_from_role || role === 'OCC' || role === 'ADMIN' : x.field === 'FUEL_ENDURANCE') && (
              <button className={`btn ${x.open ? '' : 'ghost'}`} onClick={() => openSheet({ kind: 'answer', gap: x })}>{x.open ? 'Enter answer' : 'Enter value'}</button>
            )}
          </span>
        </div>
      ))}
    </div>
  );
}

function Alternates({ d, f }) {
  const q = useGetAlternatesQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id }, { skip: !isAirborne(f) || Boolean(f.diverted_to) });
  const fc = useGetFuelCardQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id }, { skip: !isAirborne(f) || Boolean(f.diverted_to) }).data;
  const kgBy = Object.fromEntries((fc?.alternates ?? []).map((x) => [x.alt_iata, x]));
  const kg = (v) => (v == null ? '?' : `${Number(v).toLocaleString()} kg`);
  const fuel = useGetFuelQuery({ scenario_id: d.ctx.scenario_id }).data?.find((x) => x.flight_id === f.flight_id);
  const now = useNow();
  if (!isAirborne(f) || f.diverted_to) return null;
  const left = fuel ? Math.floor((ms(fuel.as_of_utc) + fuel.est_holding_endurance_min * MIN - now) / MIN) : null;
  return (
    <div className="sec" data-src="rank_alternates() · alternate_airport · airport_status_event">
      <h3>Fuel and alternates</h3>
      <dl className="facts" style={{ marginBottom: 8 }}>
        <dt>Holding endurance</dt>
        <dd>{left == null ? <span className="c-verify">? not reported</span> : `${left} min (${String(fuel.quality).toLowerCase()})`}</dd>
        {fc?.available && (
          <>
            <dt>Fuel on board</dt>
            <dd>{kg(fc.fuel_now_kg)} <span className="k">now ({String(fc.quality ?? '').toLowerCase()}; {kg(fc.fuel_on_board_kg)} at {fmtZ(ms(fc.as_of_utc))})</span></dd>
            <dt>Burn rate</dt>
            <dd>{fc.burn_rate_kg_per_hr ? `${Number(fc.burn_rate_kg_per_hr).toLocaleString()} kg/h` : '?'} <span className="k">holding burn; also used for the leg (an assumption)</span></dd>
          </>
        )}
      </dl>
      <div className="tbl-wrap">
        <table className="altt">
          <thead><tr><th>Alternate</th><th>Distance / flight</th><th>Stands</th><th>Fuel margin</th><th>Lands with</th><th>Uplift for return</th><th>Return to hub</th><th /></tr></thead>
          <tbody>
            {(q.data ?? []).map((a) => {
              const verify = (a.blocking_constraints ?? []).some((c) => c.verify);
              const why = (a.blocking_constraints ?? []).map((c) => human(c.code)).join(', ');
              return (
                <tr key={a.alt_iata} className={`${a.is_executable ? '' : 'blocked'} ${verify ? 'verify' : ''}`}>
                  <td><b>{a.alt_iata}</b></td>
                  <td title={a.flight_time_basis ?? undefined}>{a.distance_km == null ? '?' : `${Math.round(a.distance_km)} km`} · {a.est_flight_min == null ? '?' : `${a.est_flight_min} min`}</td>
                  <td title={a.score_breakdown?.stand_source === 'HISTORY' ? 'From history: the most aircraft seen on the ground there at once on past fog days. A station entry replaces it.' : undefined}>
                    {a.stands_left == null ? '?' : a.score_breakdown?.stand_source === 'HISTORY' ? `~${a.stands_left}` : a.stands_left}
                  </td>
                                    <td>{a.fuel_margin_min == null ? '?' : `${a.fuel_margin_min} min`}{kgBy[a.alt_iata]?.above_reserve_kg != null && <div className="k">{kg(kgBy[a.alt_iata].above_reserve_kg)} above reserve</div>}</td>
                  <td>{kg(kgBy[a.alt_iata]?.lands_with_kg)}</td>
                  <td>{kgBy[a.alt_iata]?.uplift_needed_kg == null ? '?' : kgBy[a.alt_iata].uplift_needed_kg === 0 ? <span className="c-legal">none needed</span> : kg(kgBy[a.alt_iata].uplift_needed_kg)}</td>
                  <td>{a.return_block_min ? `${a.return_block_min} min` : '?'}</td>
                  <td>{a.is_executable ? <span className="c-legal">Executable</span> : <span className={verify ? 'c-verify' : 'c-exceeded'}>{why || 'Blocked'}</span>}</td>
                </tr>
              );
            })}
            {q.data?.length === 0 && <tr><td colSpan={8} className="k">No alternates ranked.</td></tr>}
          </tbody>
        </table>
      </div>
      {fc?.assumption && <p className="k" style={{ marginTop: 6 }}>{fc.assumption} “Lands with” is what is left on touchdown; “uplift for return” is what the {`return leg plus a final reserve`} would need beyond that.</p>}
    </div>
  );
}

// The sign-in bracket decides the maximum FDP. Before sign-in the report time can still move (see what it would do); after sign-in the bracket is locked.
const hm = (t) => (t ? String(t).slice(0, 5) : '?');
const mmhh = (m) => (m == null ? '?' : `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`);
function ReportTime({ d, f, fdp }) {
  const signIn = ms(fdp.sign_in_utc);
  const now = useMinuteNow();
  const [t, setT] = useState('');
  const [reason, setReason] = useState('');
  const [moveTime, { isLoading: moving }] = useMoveReportTimeMutation();
  const canMove = ['OCC', 'CREW_CONTROL', 'ADMIN'].includes(d.actor.role_code);
  const signed = signIn <= now;
  const iso = (() => {
    if (!t) return null;
    const base = new Date(signIn);
    const [h, m] = t.split(':').map(Number);
    return new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate(), h, m)).toISOString();
  })();
  const { data } = useGetFdpPreviewQuery({ duty_id: f.duty_id, report_utc: iso ?? fdp.sign_in_utc, scenario_id: d.ctx.scenario_id }, { skip: signed || !f.duty_id });
  const pv = data?.preview;
  const apply = async () => {
    try {
      const r = await moveTime({ scenario_id: d.ctx.scenario_id, duty_id: f.duty_id, report_utc: iso, reason: reason.trim() }).unwrap();
      toast.success(`Report time moved to ${fmtZ(ms(r.after.report_utc))}. Limit ${mmhh(r.before.max_fdp_min)} → ${mmhh(r.after.max_fdp_min)}, legal end ${fmtZ(ms(r.after.legal_end_utc))}.`);
      setT('');
      setReason('');
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  if (signed)
    return (
      <div className="k" style={{ marginTop: 6 }}>
        🔒 Signed in at {fmtZ(signIn)}: the bracket {hm(fdp.local_start_from)}–{hm(fdp.local_start_to)} (SHJ local) is locked. Only the number of sectors can still change the limit.
      </div>
    );
  return (
    <div className="report-time">
      <div className="k">Not signed in yet: the report time can still move, and the limit follows the bracket it falls in.</div>
      <label className="k">Report time (UTC){' '}
        <input type="time" className="field-in" value={t || fmtZ(signIn).replace('Z', '')} onChange={(e) => setT(e.target.value)} style={{ width: 110 }} />
      </label>
      {pv && (
        <div style={{ marginTop: 4 }}>
          Bracket {hm(fdp.local_start_from)}–{hm(fdp.local_start_to)} → <b>{hm(pv.bracket_from)}–{hm(pv.bracket_to)}</b> · max FDP {mmhh(fdp.max_fdp_min)} → <b>{mmhh(pv.max_fdp_min)}</b> · legal end {fmtZ(ms(fdp.legal_end_utc))} → <b>{fmtZ(ms(pv.legal_end_utc))}</b>
          <span className="k"> (a preview until you apply it)</span>
        </div>
      )}
      {canMove && iso && new Date(iso).getTime() !== signIn && (
        <div style={{ marginTop: 6, display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
          <input className="field-in" style={{ flex: '1 1 220px' }} placeholder="Why does the report time move? (required)" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reason for moving the report time" />
          <button type="button" className="btn primary" disabled={moving || !reason.trim()} onClick={apply}>Move report time</button>
        </div>
      )}
    </div>
  );
}

// The paperwork for the return leg of a diverted aircraft: flight plan (Dispatch) and load sheet (station). "Ready to depart" needs both.
function ReturnChecklist({ d, f }) {
  const dv = d.diversions.find((x) => x.original_flight_id === f.flight_id && !['DEPARTED', 'CLOSED', 'CANCELLED'].includes(x.status));
  const [patch, { isLoading }] = useUpdateDiversionMutation();
  const [ask] = useAskForDataMutation();
  const role = d.actor.role_code;
  if (!dv || f.status === 'DIVERTING') return null;
  const items = [
    { key: 'flight_plan_filed', field: 'FLIGHT_PLAN', label: 'Flight plan filed', at: dv.flight_plan_filed_at, who: ['DISPATCH', 'OCC', 'ADMIN'], owner: 'Dispatch' },
    { key: 'load_sheet_ready', field: 'LOAD_SHEET', label: 'Load sheet ready', at: dv.load_sheet_ready_at, who: ['STATION', 'OCC', 'ADMIN'], owner: 'the station' },
  ];
  const tick = async (it) => {
    try {
      await patch({ id: dv.diversion_id, body: { [it.key]: !it.at } }).unwrap();
      toast.success(`${it.label}: ${it.at ? 'removed' : 'recorded'}`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const request = async (it) => {
    try {
      await ask({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, field: it.field }).unwrap();
      toast.success(`Asked ${it.owner} for the ${it.label.toLowerCase().replace(' filed', '').replace(' ready', '')}`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const ready = dv.status === 'READY';
  return (
    <div className="sec" data-src="diversion.flight_plan_filed_at · load_sheet_ready_at">
      <h3>Return leg checklist {ready ? <Pill tone="legal">Ready to depart</Pill> : <Pill tone="risk">{items.every((i) => i.at) ? 'Paperwork done' : 'Not ready'}</Pill>}</h3>
      <div className="checklist">
        {items.map((it) => {
          const open = d.openRequests.find((r) => r.flight_id === f.flight_id && r.field === it.field && r.status === 'OPEN');
          return (
            <div className="ck-row" key={it.key}>
              <Pill tone={it.at ? 'legal' : 'verify'}>{it.at ? '✓' : '?'}</Pill>
              <span><b>{it.label}</b> <span className="k">{it.at ? fmtZ(ms(it.at)) : `waiting for ${it.owner}`}{open ? ' · asked' : ''}</span></span>
              <span className="ck-act">
                {it.who.includes(role) && <button type="button" className="btn" disabled={isLoading || (ready && it.at)} onClick={() => tick(it)}>{it.at ? 'Undo' : 'Mark done'}</button>}
                {!it.at && !open && ['OCC', 'ADMIN'].includes(role) && <button type="button" className="btn ghost" onClick={() => request(it)}>Ask {it.owner}</button>}
              </span>
            </div>
          );
        })}
      </div>
      <p className="k" style={{ marginTop: 6 }}>The station can only mark the aircraft ready to depart when both are done.</p>
    </div>
  );
}

// Passengers on this flight who connect onward, worst first, with an export for Customer Service.
const CONN_TONE = { OK: 'legal', AT_RISK: 'risk', MISSED: 'exceeded', TOO_LONG: 'exceeded', INBOUND_DIVERTED: 'exceeded', CANCELLED: 'exceeded' };
const CONN_WORD = { OK: 'Makes it', AT_RISK: 'Tight', MISSED: 'Will miss it', TOO_LONG: 'No longer a connection (over 24 h)', INBOUND_DIVERTED: 'Flight diverted', CANCELLED: 'Cancelled' };
function Connections({ d, f }) {
  const q = useGetConnectionsQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id });
  const rows = q.data ?? [];
  if (!rows.length) return null;
  const bad = rows.filter((x) => x.connection_status !== 'OK');
  const paxBad = bad.reduce((n, x) => n + x.pax_count, 0);
  const exportCsv = () => {
    const esc = (v) => `"${String(v ?? '').replaceAll('"', '""')}"`;
    const head = 'inbound_flight,onward_flight,onward_to,connection_airport,passengers,scheduled_connection_min,projected_connection_min,status,inbound_arrival_utc,onward_departure_utc';
    const body = rows.map((x) => [f.flight_no, x.outbound_flight, x.outbound_to, x.connection_iata, x.pax_count, x.sched_connection_min, x.projected_connection_min, x.connection_status, x.inbound_arrival_utc, x.outbound_departure_utc].map(esc).join(','));
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([[head, ...body].join('\n')], { type: 'text/csv' }));
    a.download = `connections-${f.flight_no}.csv`;
    a.click();
  };
  return (
    <div className="sec" data-src="v_connection_risk">
      <h3>Connecting passengers {paxBad > 0 ? <Pill tone="risk">{paxBad} pax at risk</Pill> : <Pill tone="legal">all connect</Pill>} <button className="why-btn" onClick={exportCsv}>Export for Customer Service</button></h3>
      <div className="tbl-wrap">
        <table className="altt">
          <thead><tr><th>Onward flight</th><th>Pax</th><th>Connection time</th><th>Status</th></tr></thead>
          <tbody>
            {rows.map((x) => (
              <tr key={x.outbound_flight_id} className={x.connection_status === 'OK' ? '' : 'verify'}>
                <td><b>{x.outbound_flight}</b> <span className="k">to {x.outbound_to}</span><div className="k">leaves {fmtZ(ms(x.outbound_departure_utc))}</div></td>
                <td>{x.pax_count}</td>
                <td>{x.projected_connection_min == null ? '?' : `${x.projected_connection_min} min`}<div className="k">planned {x.sched_connection_min ?? '?'} · minimum 30</div></td>
                <td><Pill tone={CONN_TONE[x.connection_status] ?? 'verify'}>{CONN_WORD[x.connection_status] ?? x.connection_status}</Pill></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// What else breaks if this flight is late or diverted: the tail's next legs, crew rest before their next duty, connecting passengers.
function Downstream({ d, f }) {
  const q = useGetDownstreamQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id });
  const rows = q.data ?? [];
  if (!rows.length) return null;
  const aircraft = rows.filter((x) => x.kind === 'AIRCRAFT');
  const crew = rows.filter((x) => x.kind === 'CREW');
  const pax = aircraft.reduce((n, x) => n + (x.delay_min > 0 ? x.connecting_pax ?? 0 : 0), 0);
  const bad = (x) => x.delay_min > 0 || /conflict/i.test(x.impact ?? '');
  return (
    <div className="sec" data-src="downstream_impact()">
      <h3>Downstream impact {pax > 0 && <Pill tone="risk">{pax} connecting pax affected</Pill>}</h3>
      <div className="tbl-wrap">
        <table className="altt">
          <thead><tr><th>Next</th><th>Route</th><th>Planned</th><th>Impact</th></tr></thead>
          <tbody>
            {[...aircraft, ...crew].map((x, i) => (
              <tr key={i} className={bad(x) ? 'verify' : ''}>
                <td><b>{x.kind === 'CREW' ? x.ref : x.ref}</b></td>
                <td>{x.route}</td>
                <td>{x.planned_utc ? fmtZ(ms(x.planned_utc)) : '—'}</td>
                <td>{x.impact}{x.kind === 'AIRCRAFT' && x.connecting_pax > 0 ? ` · ${x.connecting_pax} connecting pax` : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Discussion({ d, f }) {
  const comments = useGetCommentsQuery({ case_id: d.ctx.case_id, flight_id: f.flight_id }).data ?? [];
  const [add, { isLoading }] = useAddRecordMutation();
  const [kind, setKind] = useState('COMMENT');
  const [text, setText] = useState('');
  const post = async () => {
    if (!text.trim()) return;
    try {
      await add({ table: 'case_comment', body: { case_id: d.ctx.case_id, flight_id: f.flight_id, author_id: d.actor.user_id, author_role: d.actor.role_code, body: text.trim(), kind } }).unwrap();
      setText('');
      toast.success('Posted');
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  return (
    <div className="sec" data-src="case_comment (+kind)">
      <h3>Discussion <span className="k">{comments.length} message{comments.length === 1 ? '' : 's'}</span></h3>
      <div className="msgs">
        {comments.map((c) => (
          <div className="msg" key={c.comment_id}>
            <div className="mh">
              <span className={`kind ${c.kind}`}>{String(c.kind ?? 'COMMENT').replace('_', ' ').toLowerCase()}</span>
              <b style={{ color: 'var(--text)' }}>{c.author}</b><span>{roleLabel(c.author_role)}</span><span>{hhmm(c.created_at)}</span>
            </div>
            {c.body}
          </div>
        ))}
        {comments.length === 0 && <span className="k">No messages yet. Ask a question or share a recommendation.</span>}
      </div>
      <div className="composer">
        <label className="sr" htmlFor="mKind">Message type</label>
        <select id="mKind" value={kind} onChange={(e) => setKind(e.target.value)}>
          {['COMMENT', 'QUESTION', 'ANSWER', 'RECOMMENDATION'].map((k) => <option key={k} value={k}>{k.charAt(0) + k.slice(1).toLowerCase()}</option>)}
        </select>
        <label className="sr" htmlFor="mText">Message</label>
        <input id="mText" placeholder={`Message everyone working on ${f.flight_no}`} value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && post()} />
        <button className="btn" disabled={isLoading || !text.trim()} onClick={post}>Post</button>
      </div>
      <div className="teams-note">{d.teams.has(f.flight_id) ? 'Mirrored to the Teams channel for watchers with Teams alerts.' : 'Watchers are notified in the app.'}</div>
    </div>
  );
}

export default function FlightPanel({ d, onClose }) {
  const f = d.flights.find((x) => x.flight_id === d.ops.selectedFlightId);
  const [sheet, setSheet] = useState(null);
  const [why, setWhy] = useState(false);
  if (!f) return <div className="empty">Select a flight to see its decision, options, crew and timeline.</div>;
  return <PanelBody key={f.flight_id} d={d} f={f} onClose={onClose} sheet={sheet} setSheet={setSheet} why={why} setWhy={setWhy} />;
}

function PanelBody({ d, f, onClose, sheet, setSheet, why, setWhy }) {
  const minuteNow = useMinuteNow();
  const detail = useGetFlightDetailQuery({ flightId: f.flight_id, ...d.ctx }).data;
  const links = useGetFlightLinksQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id }).data ?? [];
  const timeline = useGetFlightTimelineQuery({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, limit: 60 }, { pollingInterval: 15000 }).data ?? [];
  const [sub, { isLoading: subbing }] = useSubscribeMutation();
  const [unsub] = useUnsubscribeMutation();
  const [untag] = useRemoveTagMutation();
  const dl = d.deadlines.find((x) => x.flight_id === f.flight_id);
  const dlAt = dl?.deadline_utc ? ms(dl.deadline_utc) : null;
  const opts = useMemo(() => d.options.filter((o) => o.flight_id === f.flight_id).sort((a, b) => a.rank - b.rank).map(optView), [d.options, f.flight_id]);
  const list = useMemo(() => d.approvals.filter((x) => x.flight_id === f.flight_id), [d.approvals, f.flight_id]);
  const cur = currentDecision(list);
  const fuelRow = d.fuel.find((x) => x.flight_id === f.flight_id);
  const fuelEnd = fuelRow ? ms(fuelRow.as_of_utc) + fuelRow.est_holding_endurance_min * MIN : null;
  const gaps = gapsOf(f, { fuelEnd, openRequests: d.openRequests });
  const topOpt = opts.find((o) => o.exec);
  const watching = d.subscribed.has(f.flight_id);
  const teams = d.teams.has(f.flight_id);
  const margin = f.crew_margin_min;
  const sv = f.severity_score ?? 0;
  const fdp = detail?.fdp;
  const crew = fdp ? { signIn: ms(fdp.sign_in_utc), legal: ms(fdp.legal_end_utc), disc: ms(fdp.discretion_end_utc), proj: isAirborne(f) && !f.diverted_to ? Math.max(ms(fdp.projected_end_utc), minuteNow) : ms(fdp.projected_end_utc) } : null;
  const crewRisk = !isRecovered(f) && ['AT_RISK', 'DISCRETION_REQUIRED', 'EXCEEDED'].includes(f.crew_status);
  const run = async (fn, ok) => {
    try {
      await fn();
      toast.success(ok);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const close = () => setSheet(null);
  // a crew-replacement suggestion needs real crew details, so it goes through the replacement finder, not a plain proposal
  const openSheet = (x) => (x.kind === 'propose' && x.opt?.type === 'CREW_REPLACE' ? setSheet({ kind: 'crew' }) : setSheet(x));
  const watch = () => (watching ? run(() => unsub({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id }).unwrap(), `Stopped watching ${f.flight_no}`) : run(() => sub({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id }).unwrap(), `Watching ${f.flight_no}: you'll be alerted on every update`));
  const toggleTeams = () => run(() => sub({ flightId: f.flight_id, scenario_id: d.ctx.scenario_id, teams: !teams }).unwrap(), teams ? `Teams alerts off for ${f.flight_no}` : `Alerts for ${f.flight_no} will also go to Teams`);

  return (
    <>
      <div className="p-head">
        <div>
          <h2>
            {f.flight_no} {f.dep_iata}→{f.planned_arr_iata}
            {(f.tags ?? []).map((t) => (
              <span className="tag" key={t} title="Click to remove" style={{ cursor: 'pointer' }} onClick={() => run(() => untag({ flightId: f.flight_id, tag: t, scenario_id: d.ctx.scenario_id }).unwrap(), 'Tag removed')}>
                {TAG_LABEL[t] ?? t}
              </span>
            ))}
          </h2>
          <span className="k">
            {f.registration ?? 'no tail'} · {liveLabel(f)} · owner {f.owner ?? f.owner_role ?? '—'}
            {f.data_age_min != null ? ` · updated ${f.data_age_min} min ago` : ''}
            {!isRecovered(f) && <> · severity <b className={sevClass(sv)} style={{ padding: '0 6px', borderRadius: 999 }}>{sv}</b></>}
          </span>
        </div>
        <button className="btn ghost close" onClick={onClose}>Close</button>
      </div>

      <div className="p-actions" data-src="flight_subscription · deep_link()">
        <button className={`btn ${watching ? 'on' : ''}`} disabled={subbing} onClick={watch} aria-pressed={watching}>{watching ? '👁 Watching' + (teams ? ' + Teams' : '') : '👁 Watch flight'}</button>
        {watching && <button className="btn" onClick={toggleTeams}>{teams ? 'Stop Teams alerts' : '+ Teams alerts'}</button>}
        <button className="btn" onClick={() => setSheet({ kind: 'tag' })}>🏷 Tag</button>
        {links.map((l) =>
          l.configured ? (
            <a key={l.code} className="btn cw-link" href={l.url} target="_blank" rel="noopener noreferrer" title={l.url}>Open in {shortName(l)} ↗</a>
          ) : (
            <button key={l.code} className="btn" title="Link template not configured yet" onClick={() => setSheet({ kind: 'link', link: l })}>Open in {shortName(l)} ↗</button>
          ),
        )}
      </div>

      {(f.lvp_required && f.lvp_crew_ok === false) && (
        <div className="sec"><Pill tone="exceeded">LVP</Pill> LVP is in force and {(f.lvp_not_qualified ?? []).map((p) => `${p.position} ${p.name}`).join(', ') || 'a pilot'} is not LVP-qualified. Landing here needs a different crew.</div>
      )}
      {d.ruleMatches.rules.filter((r) => (d.ruleMatches.flights[f.flight_id] ?? []).includes(r.rule_id) && r.kind !== 'FILTER').map((r) => (
        <div className="sec" key={r.rule_id} data-src="ops_rule (rule matching this flight)">
          <span className={`rule-mark rm-${r.kind}`}>{r.kind === 'CONSTRAINT' ? 'Blocked by rule' : r.kind === 'PRIORITY' ? 'Priority rule' : 'Alert rule'}</span> <b>{r.name}.</b> {r.description}
        </div>
      ))}

      <div className="sec"><h3>Decision</h3><Decision d={d} f={f} list={list} cur={cur} topOpt={topOpt} gaps={gaps} openSheet={openSheet} /></div>
      <Recs d={d} f={f} detail={detail} opts={opts} locked={Boolean(cur) || d.actor.role_code === 'STATION'} openSheet={openSheet} />
      <Gaps d={d} f={f} gaps={gaps} openSheet={setSheet} />

      {dlAt != null && (
        <div className="sec">
          <h3>Deadline <button className="why-btn" onClick={() => setWhy(!why)}>Why this time?</button></h3>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
            <Cd at={dlAt} big />
            <span>{dl.reason}: <b>{fmtZday(dlAt, minuteNow)}</b> / {fmtTime(dlAt)} SHJ</span>
          </div>
          {why && (
            <div data-src="fdp_calculation.inputs · latest_departure_calc">
              <ol style={{ margin: '8px 0 0', paddingLeft: 18, fontSize: 13 }}>
                {[...(dl.why ?? []), ...(detail?.why ?? [])].map((w) => <li key={w}>{w}</li>)}
              </ol>
            </div>
          )}
        </div>
      )}
      {dl && dlAt == null && (dl.kind === 'diverting' || dl.kind === 'crew') && (
        <div className="sec">
          <h3>Deadline <button className="why-btn" onClick={() => setWhy(!why)}>Why?</button></h3>
          <div><Pill tone={dl.kind === 'crew' ? 'disc' : 'legal'}>{dl.kind === 'crew' ? 'Crew cannot return legally' : 'Diverting'}</Pill> <span>{dl.reason}</span></div>
          {why && <ol style={{ margin: '8px 0 0', paddingLeft: 18, fontSize: 13 }}>{(dl.why ?? []).map((w) => <li key={w}>{w}</li>)}</ol>}
        </div>
      )}
      {dl && dlAt == null && dl.kind !== 'diverting' && dl.kind !== 'crew' && !isRecovered(f) && <div className="sec"><h3>Deadline</h3><Pill tone="verify">Cannot compute</Pill> <span className="k">{dl.reason}</span></div>}

      {!isRecovered(f) && (
        <div className="sec" data-src="v_crew_legality_ranking · crew_qualification">
          <h3>Crew duty <Pill tone={(verdictPill[f.crew_status] ?? 't-verify').slice(2)}>{human(f.crew_status ?? 'unknown').replace(/^./, (c) => c.toUpperCase())}</Pill></h3>
          {isAirborne(f) && !f.diverted_to && f.eta_utc && ms(f.eta_utc) < minuteNow && <div className="c-risk" style={{ marginBottom: 6 }}>ETA {fmtZ(ms(f.eta_utc))} has passed ({Math.floor((minuteNow - ms(f.eta_utc)) / MIN)} min ago) and the aircraft is still airborne. The landing marker shows now, not the old estimate. Verify the position.</div>}
          {crew && crew.signIn > minuteNow && <div className="k" style={{ marginBottom: 6 }}>Duty starts {fmtZ(crew.signIn)} · legal until {fmtZ(crew.legal)} (the clock only runs after sign-in)</div>}
          {crew && <Ribbon c={crew} />}
          <dl className="facts" style={{ marginTop: 12 }}>
            {fdp && (<><dt>Limit</dt><dd>{Math.floor(fdp.max_fdp_min / 60)}:{String(fdp.max_fdp_min % 60).padStart(2, '0')} · {fdp.legs_counted} sector{fdp.legs_counted > 1 ? 's' : ''} · bracket {fdp.local_start_from ? `${hm(fdp.local_start_from)}–${hm(fdp.local_start_to)}` : '?'} SHJ local{fdp.source_rule_id ? ` · rule ${fdp.source_rule_id}` : ''}</dd></>)}
            <dt>Legal end</dt><dd>{f.legal_end_utc ? `${fmtZ(ms(f.legal_end_utc))} / ${fmtTime(ms(f.legal_end_utc))} SHJ · with discretion ${fmtZ(ms(f.discretion_end_utc))}` : '—'}</dd>
            <dt>Margin at landing</dt><dd>{margin == null ? '—' : margin < 0 ? <span className="c-disc">{-margin} min over</span> : `${margin} min`}</dd>
          </dl>
          {fdp && <ReportTime d={d} f={f} fdp={fdp} />}
          <div className="crew-list">
            {(detail?.crew ?? []).map((c) => {
              const pilot = ['CP', 'FO'].includes(c.position_code);
              return <div className="crew-li" key={c.crew_id}><span className="pos">{c.position_code}</span><span>{c.full_name}</span>{pilot && (c.lvp ? <Pill tone="legal">LVP ✓</Pill> : <Pill tone="exceeded">Not LVP</Pill>)}</div>;
            })}
          </div>
          {(f.crew_reasons ?? []).map((r) => <div key={r} className="k" style={{ marginTop: 4 }}>{plainCodes(r)}</div>)}
          {f.open_exceptions > 0 && <p className="c-risk" style={{ margin: '8px 0 0' }}>{f.open_exceptions} open data exception(s) on this duty. Treat legality as unverified.</p>}
          {(crewRisk || f.diverted_to) && f.duty_id && (
            <div style={{ marginTop: 10 }}><button className="btn" onClick={() => setSheet({ kind: 'crew' })}>Find replacement crew</button></div>
          )}
        </div>
      )}

      <Alternates d={d} f={f} />
      {f.diverted_to && <ReturnChecklist d={d} f={f} />}
      {!isRecovered(f) && <Downstream d={d} f={f} />}
      {!isRecovered(f) && <Connections d={d} f={f} />}

      <div className="sec" data-src="flight_event · decision · decision_approval · case_comment · data_request (this flight)">
        <h3>Flight briefing <span className="k">actions taken on this flight</span></h3>
        <ul className="tl">
          {timeline.slice(0, 25).map((t, i) => (
            <li key={`${t.occurred_at}-${i}`}>
              <span className="t">{hhmm(t.occurred_at)}</span>
              <span>{t.summary}<span className="who k" style={{ display: 'block' }}>{t.actor ?? 'system'}</span></span>
            </li>
          ))}
          {timeline.length === 0 && <li><span className="k">Nothing has happened to this flight yet.</span></li>}
        </ul>
      </div>

      <Discussion d={d} f={f} />

      {sheet?.kind === 'propose' && <ProposeSheet d={d} f={f} opt={sheet.opt} onClose={close} />}
      {sheet?.kind === 'approve' && cur && <ApproveSheet d={d} f={f} decision={cur} onClose={close} onReject={() => setSheet({ kind: 'reject' })} onFindReplacement={() => setSheet({ kind: 'crew' })} />}
      {sheet?.kind === 'reject' && cur && <RejectSheet d={d} f={f} decision={cur} onClose={close} />}
      {sheet?.kind === 'execute' && cur && <ExecuteSheet d={d} f={f} decision={cur} onClose={close} />}
      {sheet?.kind === 'answer' && <AnswerSheet d={d} f={f} gap={sheet.gap} onClose={close} />}
      {sheet?.kind === 'tag' && <TagSheet d={d} f={f} onClose={close} />}
      {sheet?.kind === 'withdraw' && cur && <WithdrawSheet f={f} decision={cur} onClose={close} />}
      {sheet?.kind === 'link' && <LinkSheet f={f} link={sheet.link} onClose={close} />}
      {sheet?.kind === 'crew' && <CrewFinderSheet d={d} f={f} onClose={close} />}
    </>
  );
}
