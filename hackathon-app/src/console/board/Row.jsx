import { memo } from 'react';
import { ms, fmtZday, human, isRecovered, isAirborne, recWhat, sevClass, sevWord, whereText, TAG_LABEL, decisionWhat, REC_TONE } from '../lib';
import { Cd, Pill } from '../ui/ui';
import { MIN } from '@/features/ops/time';

function FuelMeter({ f, fuelEnd, now }) {
  if (isAirborne(f) && !f.diverted_to) {
    if (fuelEnd == null)
      return (
        <div className="meter verify">
          <div className="lbl"><span>Fuel</span><b className="c-verify">? verify</b></div>
          <div className="track" />
        </div>
      );
    const m = Math.floor((fuelEnd - now) / MIN);
    const tone = m < 20 ? 'exceeded' : m < 45 ? 'risk' : 'legal';
    return (
      <div className="meter">
        <div className="lbl"><span>Fuel</span><b className={`c-${tone}`}>{m} min*</b></div>
        <div className="track"><div className="fill" style={{ width: `${Math.max(4, Math.min(100, (m / 120) * 100))}%`, background: `var(--${tone})` }} /></div>
      </div>
    );
  }
  return (
    <div className="meter">
      <div className="lbl"><span>Fuel</span><b>On ground</b></div>
      <div className="track"><div className="fill" style={{ width: '100%', background: 'var(--faint)' }} /></div>
    </div>
  );
}

function CrewMeter({ f, now }) {
  if (isRecovered(f))
    return (
      <div className="meter">
        <div className="lbl"><span>Crew</span><b>Done</b></div>
        <div className="track" />
      </div>
    );
  const m = f.crew_margin_min;
  if (m == null)
    return (
      <div className="meter verify">
        <div className="lbl"><span>Crew</span><b className="c-verify">no crew data</b></div>
        <div className="track" />
      </div>
    );
  const left = f.legal_end_utc ? Math.floor((ms(f.legal_end_utc) - now) / MIN) : null;
  const tone = m < 0 ? 'disc' : m < 60 ? 'risk' : 'legal';
  const text = m < 0 ? 'Needs discretion' : left == null ? `${m} min margin` : left < 60 ? `${left} min left` : `${Math.floor(left / 60)} h ${String(left % 60).padStart(2, '0')} left`;
  return (
    <div className="meter">
      <div className="lbl"><span>Crew</span><b className={`c-${tone}`}>{text}</b></div>
      <div className="track"><div className="fill" style={{ width: `${Math.max(4, Math.min(100, ((left ?? m) / 240) * 100))}%`, background: `var(--${tone})` }} /></div>
    </div>
  );
}

// What the "decision" column says: approvals in progress, done, or what the engine suggests.
function RecCell({ f, cur, last, verifyFuel }) {
  if (isRecovered(f)) return <Pill tone="neutral">Arrived before closure</Pill>;
  if (cur?.status === 'PROPOSED') {
    const req = cur.required_roles.length;
    const done = cur.approved_roles.length;
    return (
      <>
        <Pill tone="risk">{cur.can_approve ? 'Needs your approval' : 'Waiting for approval'} · {done}/{req}</Pill>
        <span className="k">{cur.proposed_by}: {decisionWhat(cur)}</span>
      </>
    );
  }
  if (cur?.status === 'APPROVED') return <Pill tone="legal">Approved: {decisionWhat(cur)}</Pill>;
  if (last?.status === 'EXECUTED')
    return (
      <>
        <Pill tone="legal">Done: {decisionWhat(last)}</Pill>
        <span className="k">{whereText(f)[1]}</span>
      </>
    );
  if (verifyFuel) return <Pill tone="verify">? Verify fuel before deciding</Pill>;
  const what = recWhat(f);
  if (!what) return <Pill tone="neutral">No decision needed</Pill>;
  return <Pill tone={REC_TONE[f.recommendation] ?? 'ai'}>Engine: {what}</Pill>;
}

// One board row. memo: it only re-renders when ITS flight, decision, deadline, fuel, rules or selection changes
// (never on a clock tick); the countdown inside is its own small component.
const Row = memo(function Row({ f, cur, last, dl, fuelEnd, rules, selected, watched, now, onOpen }) {
  const sv = f.severity_score ?? 0;
  const at = dl?.deadline_utc ? ms(dl.deadline_utc) : null;
  const [where, sub] = whereText(f);
  const verifyFuel = isAirborne(f) && !f.diverted_to && fuelEnd == null;
  const recovered = isRecovered(f);
  const mine = rules.filter((r) => r.kind !== 'FILTER');
  return (
    <div className="row" role="option" tabIndex={0} aria-selected={selected} data-id={f.flight_id} data-src="v_flight_watch ⨝ v_flight_severity" onClick={() => onOpen(f.flight_id)} onKeyDown={(e) => e.key === 'Enter' && onOpen(f.flight_id)}>
      {watched && <span className="watch" title="You are watching this flight">👁</span>}
      <div className="flt">
        <b>{f.flight_no}</b>
        {(f.tags ?? []).map((t) => <span className="tag" key={t}>{TAG_LABEL[t] ?? t}</span>)}
        <span className="k">{f.dep_iata}→{f.planned_arr_iata}</span>
        <span className="k">{f.registration ?? 'no tail'}</span>
        {!recovered && <span className={`sev ${sevClass(sv)}`} title={`Severity ${sv}/100`}>{sevWord(sv)} {sv}</span>}
        {mine.map((r) => <span key={r.rule_id} className={`rule-mark rm-${r.kind}`} title={r.description}>{r.kind === 'CONSTRAINT' ? 'Blocked' : r.kind === 'PRIORITY' ? 'Priority' : 'Alert rule'}: {r.name}</span>)}
      </div>
      <div className="where">
        {where}
        <span className="k">{sub}{f.data_age_min != null && f.data_age_min > 15 ? ` · data ${f.data_age_min} min old` : ''}</span>
      </div>
      <FuelMeter f={f} fuelEnd={fuelEnd} now={now} />
      <CrewMeter f={f} now={now} />
      <div className="lvp-cell">
        {recovered || !f.lvp_required ? <span className="k">—</span> : f.lvp_crew_ok ? <Pill tone="legal">LVP ✓</Pill> : f.lvp_crew_ok === false ? <Pill tone="exceeded">LVP ✕</Pill> : <Pill tone="verify">LVP ?</Pill>}
      </div>
      <div className="rec"><RecCell f={f} cur={cur} last={last} verifyFuel={verifyFuel} /></div>
      <div className="cd-cell">
        {recovered ? <span className="k">Done</span> : at ? <><Cd at={at} big /><span className="k">{fmtZday(at, now)}</span></> : <><span className="cd-big c-verify">?</span><span className="k">{human(dl?.reason ?? 'verify')}</span></>}
      </div>
    </div>
  );
});
export default Row;
