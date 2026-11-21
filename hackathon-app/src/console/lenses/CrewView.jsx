import { Fragment, useMemo, useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { useGetLegOutlookQuery, useGetNextDutyLegalQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { fmtDur, fmtZD, fmtZLD } from '@/features/ops/time';
import { useNow } from '@/hooks/useNow';
import { Cd, Pill } from '../ui/ui';
import { crewTone, fmtZ, ms, verdictPill } from '../lib';
import CrewFinderSheet from '../sheets/CrewFinderSheet';
import './lenses.css';

const ORDER = ['CP', 'FO', 'SO', 'CS', 'CC', 'SEC', 'EN'];
const SHOWN = 60;

// Duty ribbon: sign-in -> legal end -> +3 h discretion. Marks: now, projected landing, legal end.
function Ribbon({ signIn, legal, disc, proj }) {
  const now = useNow();
  if (signIn == null || legal == null) return <span className="k">No duty timeline</span>;
  const end = disc ?? legal + 3 * 3600000;
  const span = Math.max(1, end - signIn);
  const p = (t) => Math.max(0, Math.min(100, ((t - signIn) / span) * 100));
  return (
    <div className="ribbon" role="img" aria-label={`Sign-in ${fmtZ(signIn)}, legal end ${fmtZ(legal)}${proj ? `, lands ${fmtZ(proj)}` : ''}`}>
      <div className="rb-track">
        <div className="rb-used" style={{ width: `${p(now)}%` }} />
        <div className="rb-disc" style={{ left: `${p(legal)}%`, right: 0 }} />
      </div>
      <div className="rb-mark" style={{ left: `${p(now)}%` }} title={`Now ${fmtZ(now)}`} />
      {proj != null && <div className="rb-mark proj" style={{ left: `${p(proj)}%` }} title={`Projected landing ${fmtZ(proj)}`} />}
      <div className="rb-mark legal" style={{ left: `${p(legal)}%` }} title={`Legal end ${fmtZ(legal)}`} />
    </div>
  );
}

// Legality of the duty's crew for the current legs (N) and one more sector (N+1), straight from the approved FDP rules.
function Outlook({ dutyId, scenarioId }) {
  const { data = [] } = useGetLegOutlookQuery({ scenario_id: scenarioId, duty_id: dutyId });
  if (!data.length) return null;
  const rank = ['LEGAL', 'AT_RISK', 'DISCRETION_REQUIRED', 'VERIFICATION_REQUIRED', 'EXCEEDED'];
  const worst = (key) => data.reduce((a, c) => (rank.indexOf(c[key]) > rank.indexOf(a) ? c[key] : a), 'LEGAL');
  const min = (key) => data.reduce((a, c) => (c[key] == null ? a : a == null ? c[key] : Math.min(a, c[key])), null);
  const n = worst('status_n');
  const n1 = worst('status_n1');
  const label = (st, m) => `${String(st).replaceAll('_', ' ').toLowerCase()}${m == null ? '' : ` · ${m} min`}`;
  return (
    <span className="outlook">
      <Pill tone={verdictPill[n]?.slice(2) ?? 'verify'}>N={data[0].legs_n} {label(n, min('margin_n_min'))}</Pill>
      <Pill tone={verdictPill[n1]?.slice(2) ?? 'verify'}>N+1={data[0].legs_n1} {label(n1, min('margin_n1_min'))}</Pill>
    </span>
  );
}


// Duty end + minimum rest. The rest is ASSUMED in the supplied rules and is shown as such.
function NextLegal({ n }) {
  const t = n?.next_legal_from_utc ? ms(n.next_legal_from_utc) : null;
  if (t == null) return <span className="k">needs verification</span>;
  return (
    <span>
      <b>{fmtZLD(t)}</b>
      <span className="k" style={{ display: 'block' }}>
        <Cd at={t} /> · duty ends {fmtZD(ms(n.duty_end_utc))} + {fmtDur(n.rest_min)} rest{n.rest_quality === 'ASSUMED' ? ' (assumed)' : ''}
      </span>
    </span>
  );
}

const tn = (st) => verdictPill[st]?.slice(2) ?? 'verify';
// Time against the approved limit: negative margin = how far the crew lags behind the legality required.
const lagText = (st, m) =>
  st === 'VERIFICATION_REQUIRED' || m == null ? 'needs verification' : m < 0 ? `short by ${fmtDur(-m)}` : `${fmtDur(m)} to spare`;
const SEV = ['LEGAL', 'AT_RISK', 'DISCRETION_REQUIRED', 'VERIFICATION_REQUIRED', 'EXCEEDED'];

// Every crew member of the duty with legality for the current legs (N) and one more sector (N+1); worst case highlighted.
function CrewDetail({ dutyId, scenarioId, crew }) {
  const { data = [], isFetching } = useGetLegOutlookQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const { data: nl = [] } = useGetNextDutyLegalQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const next = (id) => nl.find((x) => x.crew_id === id);
  const lvp = (id) => crew.find((c) => c.crew_id === id)?.lvp_qualified;
  const rows = [...data].sort(
    (a, b) => Math.max(SEV.indexOf(b.status_n), SEV.indexOf(b.status_n1)) - Math.max(SEV.indexOf(a.status_n), SEV.indexOf(a.status_n1)),
  );
  if (isFetching && !rows.length) return <div className="k crew-detail">Checking legality for N and N+1…</div>;
  if (!rows.length) return <div className="k crew-detail">No crew legality calculated for this duty.</div>;
  return (
    <div className="crew-detail" role="table" aria-label="Crew legality for N and N+1 legs">
      <div className="cd-row cd-head" role="row">
        <span>Crew</span>
        <span>Current N legs</span>
        <span>N+1 legs (one more sector)</span>
        <span>Legal for next flight from</span>
      </div>
      {rows.map((c) => {
        const worst = SEV[Math.max(SEV.indexOf(c.status_n), SEV.indexOf(c.status_n1))];
        return (
          <div className="cd-row" role="row" key={c.crew_id} style={{ background: `var(--${tn(worst)}-bg)`, borderLeft: `3px solid var(--${tn(worst)})` }}>
            <span>
              <b>{c.position_code}</b> {c.full_name}
              <span className="k" style={{ display: 'block' }}>
                #{c.crew_id}
                {['CP', 'FO'].includes(c.position_code) && lvp(c.crew_id) === false ? ' · not LVP' : ''}
              </span>
            </span>
            <span>
              <Pill tone={tn(c.status_n)}>{String(c.status_n).replaceAll('_', ' ')}</Pill>
              <span className="k" style={{ display: 'block' }}>
                {c.legs_n} leg{c.legs_n > 1 ? 's' : ''} · max {fmtDur(c.max_fdp_n_min)} · {lagText(c.status_n, c.margin_n_min)}
              </span>
            </span>
            <span>
              <Pill tone={tn(c.status_n1)}>{String(c.status_n1).replaceAll('_', ' ')}</Pill>
              <span className="k" style={{ display: 'block' }}>
                {c.legs_n1} legs · max {fmtDur(c.max_fdp_n1_min)} · {lagText(c.status_n1, c.margin_n1_min)}
              </span>
            </span>
            <NextLegal n={next(c.crew_id)} />
          </div>
        );
      })}
    </div>
  );
}

// Crew Control: who runs out of legality next. One row per duty, worst crew member first, soonest legal end on top.
export default function CrewView({ d }) {
  const dispatch = useAppDispatch();
  const [pick, setPick] = useState(null); // flight to find a replacement for
  const [open, setOpen] = useState(() => new Set()); // duties whose crew list is expanded
  const toggle = (id) => setOpen((o) => { const n = new Set(o); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  const { crew, flights } = d;
  const rows = useMemo(() => {
    const byDuty = new Map();
    for (const c of crew) {
      const cur = byDuty.get(c.duty_id);
      const cm = c.margin_min ?? 1e9;
      const worse =
        !cur ||
        cm < (cur.margin_min ?? 1e9) ||
        (cm === (cur.margin_min ?? 1e9) && ORDER.indexOf(c.position_code) < ORDER.indexOf(cur.position_code));
      const needs = (cur?.needsHelp ?? false) || c.status !== 'LEGAL';
      if (worse) byDuty.set(c.duty_id, { ...c, crewCount: (cur?.crewCount ?? 0) + 1, needsHelp: needs });
      else {
        cur.crewCount += 1;
        cur.needsHelp = needs;
      }
    }
    return [...byDuty.values()]
      .filter((c) => c.legal_end_utc)
      .sort((a, b) => ms(a.legal_end_utc) - ms(b.legal_end_utc))
      .map((c) => ({ ...c, flight: flights.find((f) => f.duty_id === c.duty_id) }));
  }, [crew, flights]);

  return (
    <div className="crew-view" data-src="v_crew_legality_ranking ORDER BY minutes_until_legal_end">
      <h2 className="lane-h" style={{ marginTop: 4 }}>
        Who runs out of legality next{' '}
        <span className="k">
          {rows.length} duties on this case, soonest legal end first
        </span>
      </h2>
      {rows.length === 0 ? (
        <div className="runway">
          <div className="empty">No crew duties with a known legal end on this case.</div>
        </div>
      ) : (
        <div className="runway">
          <div className="rw-scroll">
            <div className="rw-inner">
              <div className="rw-row rw-head">
                <span>Flight · crew</span>
                <span>Legal end</span>
                <span>Duty (sign-in → legal end → +3 h discretion)</span>
                <span>Margin at landing</span>
                <span />
              </div>
              {rows.slice(0, SHOWN).map((c) => {
                const m = c.margin_min;
                const legalAt = ms(c.legal_end_utc);
                const tone = crewTone(m);
                return (
                  <Fragment key={c.duty_id}>
                  <div className="rw-row">
                    <span>
                      {c.flight ? (
                        <button type="button" className="flt-link" onClick={() => dispatch(selectFlight(c.flight.flight_id))} title="Open this flight">{c.flight.flight_no}</button>
                      ) : (
                        <b>{c.duty_legs}</b>
                      )}{' '}
                      <span className="k">{c.flight ? `${c.flight.dep_iata}→${c.flight.planned_arr_iata ?? c.flight.arr_iata}` : c.duty_legs}</span>
                      <span className="k" style={{ display: 'block' }}>
                        {c.position_code} {c.full_name}
                        {c.crewCount > 1 ? ` + ${c.crewCount - 1} crew` : ''} · {c.legs_counted} sector{c.legs_counted > 1 ? 's' : ''} · max {c.max_fdp_hhmm}
                        {['CP', 'FO'].includes(c.position_code) && !c.lvp_qualified && (
                          <>
                            {' · '}
                            <span className="c-exceeded">{c.position_code} not LVP</span>
                          </>
                        )}
                      </span>
                    </span>
                    <span>
                      <Cd at={legalAt} />
                      <span className="k" style={{ display: 'block' }}>
                        {fmtZLD(legalAt)}
                      </span>
                    </span>
                    <Ribbon signIn={ms(c.sign_in_utc)} legal={legalAt} disc={ms(c.discretion_end_utc)} proj={ms(c.projected_end_utc)} />
                    <span>
                      {m == null ? (
                        <Pill tone={verdictPill[c.status]?.slice(2) ?? 'verify'}>Verify</Pill>
                      ) : (
                        <Pill tone={tone}>{m < 0 ? `${-m} min over` : `${m} min`}</Pill>
                      )}
                      <Outlook dutyId={c.duty_id} scenarioId={d.ctx.scenario_id} />
                    </span>
                    <span className="rw-actions">
                      {c.flight && !c.needsHelp && <span className="k">Legal for this route</span>}
                      {c.flight && c.needsHelp && (
                        <button type="button" className="btn" onClick={() => setPick(c.flight)}>
                          Find replacement
                        </button>
                      )}
                      <button type="button" className="btn" aria-expanded={open.has(c.duty_id)} onClick={() => toggle(c.duty_id)}>
                        {open.has(c.duty_id) ? 'Hide crew' : 'Crew'}
                      </button>
                      {c.flight && (
                        <button type="button" className="btn" onClick={() => dispatch(selectFlight(c.flight.flight_id))}>
                          Open
                        </button>
                      )}
                    </span>
                  </div>
                  {open.has(c.duty_id) && (
                    <CrewDetail dutyId={c.duty_id} scenarioId={d.ctx.scenario_id} crew={crew.filter((x) => x.duty_id === c.duty_id)} />
                  )}
                  </Fragment>
                );
              })}
            </div>
          </div>
        </div>
      )}
      <div className="rb-legend lens-note">
        <span><i className="lg-now" />Now</span>
        <span><i className="lg-proj" />Projected landing</span>
        <span><i className="lg-legal" />Legal end</span>
        <span><i className="lg-disc" />Commander discretion zone</span>
      </div>
      <p className="k">Crew types without approved FDP rules show as “Verify” and are never treated as legal.</p>
      {pick && <CrewFinderSheet d={d} f={pick} onClose={() => setPick(null)} />}
    </div>
  );
}
