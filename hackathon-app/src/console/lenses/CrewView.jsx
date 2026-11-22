import { Fragment, useMemo, useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import {
  useGetDutySectorsQuery,
  useGetLegOutlookQuery,
  useGetN1ExtraSectorQuery,
  useGetNextDutyLegalQuery,
  useGetOpenCrewDutiesQuery,
} from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { fmtDur, fmtZD, fmtZLD } from '@/features/ops/time';
import { useNow } from '@/hooks/useNow';
import { Pill } from '../ui/ui';
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

// N+1 (one more sector) is a what-if that matters until OCC initiates a diversion for the duty's flight (a DIVERT decision approved
// or executed, a diversion record, or the flight already diverting/diverted) and while the flight can still be diverted. Once a
// diversion is initiated the extra sector is already part of N, so N+1 is not shown any more.
function useDutyContext(dutyId, scenarioId) {
  const { data: sectors = [] } = useGetDutySectorsQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const initiated = sectors[0]?.diversion_in_play === true;
  return { sectors, inPlay: initiated, showN1: sectors.length > 0 && !initiated && sectors[0]?.divertible === true };
}

// Every sector of the duty on the row: origin → destination, departure, arrival and the sector's flight (block) time.
function RowSectors({ dutyId, scenarioId, fallback }) {
  const { sectors } = useDutyContext(dutyId, scenarioId);
  if (!sectors.length) return <b>{fallback}</b>;
  return (
    <span className="row-sectors">
      {sectors.map((x) => (
        <span className="rs-line" key={x.leg_seq}>
          <b>{x.flight_no}</b> {x.dep_iata}→{x.arr_iata}
          {x.planned_arr_iata !== x.arr_iata && <span className="k"> (planned {x.planned_arr_iata})</span>}
          <span className="k" style={{ display: 'block' }}>
            {x.dep_utc ? fmtZD(ms(x.dep_utc)) : '-'} → {x.arr_utc ? fmtZD(ms(x.arr_utc)) : '-'} · {x.block_min == null ? '-' : fmtDur(x.block_min)} flight
          </span>
        </span>
      ))}
    </span>
  );
}

// N+1 per crew: with the extra sector (return from the best-ranked alternate, engine times) when it can be estimated,
// otherwise only the tighter FDP limit for one more sector (no extra flying time).
// N+1 is a what-if before OCC declares a diversion, so it only ever reads LEGAL or AT RISK (even when the limit would be passed:
// the minutes short still show). DISCRETION REQUIRED / EXCEEDED belong to the current leg (N) once a flight is actually diverted.
const n1Risk = (st) => (st === 'DISCRETION_REQUIRED' || st === 'EXCEEDED' ? 'AT_RISK' : st);
const withExtra = (base, extra) =>
  (base ?? []).map((c) => {
    const x = (extra ?? []).find((e) => e.crew_id === c.crew_id);
    const m = x && x.margin_n1_extra_min != null
      ? { ...c, status_n1: x.status_n1_extra, margin_n1_min: x.margin_n1_extra_min, via: x.alt_iata, x }
      : c;
    return { ...m, status_n1: n1Risk(m.status_n1) };
  });

// Legality of the duty's crew for the current legs (N) and, only when a diversion is in play, one more sector (N+1).
function Outlook({ dutyId, scenarioId }) {
  const { showN1 } = useDutyContext(dutyId, scenarioId);
  const { data: base = [] } = useGetLegOutlookQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const { data: extra = [] } = useGetN1ExtraSectorQuery({ scenario_id: scenarioId, duty_id: dutyId }, { skip: !showN1 });
  const data = showN1 ? withExtra(base ?? [], extra ?? []) : base ?? [];
  if (!data.length) return null;
  const rank = ['LEGAL', 'AT_RISK', 'DISCRETION_REQUIRED', 'VERIFICATION_REQUIRED', 'EXCEEDED'];
  const worst = (key) => data.reduce((a, c) => (rank.indexOf(c[key]) > rank.indexOf(a) ? c[key] : a), 'LEGAL');
  const min = (key) => data.reduce((a, c) => (c[key] == null ? a : a == null ? c[key] : Math.min(a, c[key])), null);
  const n = worst('status_n');
  const n1 = worst('status_n1');
  const label = (st, m) => `${String(st).replaceAll('_', ' ').toLowerCase()}${m == null ? '' : ` · ${m} min`}`;
  const via = data.find((c) => c.via)?.via;
  return (
    <span className="outlook">
      <Pill tone={verdictPill[n]?.slice(2) ?? 'verify'}>N={data[0].legs_n} {label(n, min('margin_n_min'))}</Pill>
      {showN1 && (
        <Pill tone={verdictPill[n1]?.slice(2) ?? 'verify'}>
          N+1={data[0].legs_n1} {label(n1, min('margin_n1_min'))}
          {via ? ` if diverted via ${via}` : ' if diverted'}
        </Pill>
      )}
    </span>
  );
}

// From when the crew can fly their next flight: last arrival of the duty + the minimum rest. Only the time is shown;
// how it is worked out (the rest is ASSUMED in the supplied rules) is in the tooltip and the column header.
function NextLegal({ n }) {
  const t = n?.next_legal_from_utc ? ms(n.next_legal_from_utc) : null;
  if (t == null) return <span className="k">needs verification</span>;
  return (
    <b title={`Duty ends ${fmtZD(ms(n.duty_end_utc))} + ${fmtDur(n.rest_min)} minimum rest${n.rest_quality === 'ASSUMED' ? ' (assumed: not in the supplied FDTL file)' : ''}`}>
      {fmtZLD(t)}
    </b>
  );
}

const tn = (st) => verdictPill[st]?.slice(2) ?? 'verify';
// Time against the approved limit: negative margin = how far the crew lags behind the legality required.
const lagText = (st, m) =>
  st === 'VERIFICATION_REQUIRED' || m == null ? 'needs verification' : m < 0 ? `short by ${fmtDur(-m)}` : `${fmtDur(m)} to spare`;
const SEV = ['LEGAL', 'AT_RISK', 'DISCRETION_REQUIRED', 'VERIFICATION_REQUIRED', 'EXCEEDED'];

// The duty's sectors with their own hours. Sector hours are shown for information; legality below still comes from the
// approved FDP rules (they are not a legal measure and are not used for any status).
function Sectors({ sectors }) {
  if (!sectors.length) return null;
  const q = (b) => (b === 'ACTUAL' ? '' : b === 'ESTIMATED' ? ' est.' : ' sched.');
  return (
    <div className="cd-sectors" role="table" aria-label="Duty sectors">
      <div className="cd-srow cd-head" role="row">
        <span>Sector</span>
        <span>Departs</span>
        <span>Arrives</span>
        <span>Block</span>
        <span>Ground after</span>
      </div>
      {sectors.map((x) => (
        <div className="cd-srow" role="row" key={x.leg_seq}>
          <span>
            <b>{x.flight_no}</b> {x.dep_iata}→{x.arr_iata}
            {x.planned_arr_iata !== x.arr_iata && <span className="k"> (planned {x.planned_arr_iata})</span>}
            {x.leg_source !== 'PLANNED' && <span className="k"> · {String(x.leg_source).toLowerCase()}</span>}
          </span>
          <span>{x.dep_utc ? fmtZLD(ms(x.dep_utc)) : '-'}<span className="k">{q(x.dep_basis)}</span></span>
          <span>{x.arr_utc ? fmtZLD(ms(x.arr_utc)) : '-'}<span className="k">{q(x.arr_basis)}</span></span>
          <span>{x.block_min == null ? '-' : fmtDur(x.block_min)}</span>
          <span>{x.ground_after_min == null ? '-' : fmtDur(x.ground_after_min)}</span>
        </div>
      ))}
      <div className="k" style={{ marginTop: 4 }}>
        Sector hours {fmtDur(sectors[0].sector_total_min)}
        {sectors[0].ground_total_min != null ? ` + ground ${fmtDur(sectors[0].ground_total_min)}` : ''} (information only; legality uses the approved FDP)
      </div>
    </div>
  );
}

// Every crew member of the duty with legality for the current legs (N) and one more sector (N+1); worst case highlighted.
function CrewDetail({ dutyId, scenarioId, crew }) {
  const { sectors, showN1 } = useDutyContext(dutyId, scenarioId);
  const { data: base = [], isFetching } = useGetLegOutlookQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const { data: extra = [] } = useGetN1ExtraSectorQuery({ scenario_id: scenarioId, duty_id: dutyId }, { skip: !showN1 });
  const data = showN1 ? withExtra(base ?? [], extra ?? []) : base ?? [];
  const sev = (c) => Math.max(SEV.indexOf(c.status_n), showN1 ? SEV.indexOf(c.status_n1) : 0);
  const { data: nl = [] } = useGetNextDutyLegalQuery({ scenario_id: scenarioId, duty_id: dutyId });
  const next = (id) => nl.find((x) => x.crew_id === id);
  const lvp = (id) => crew.find((c) => c.crew_id === id)?.lvp_qualified;
  const rows = [...data].sort((a, b) => sev(b) - sev(a));
  if (isFetching && !rows.length) return <div className="k crew-detail">Checking legality for N and N+1…</div>;
  if (!rows.length) return <div className="k crew-detail">No crew legality calculated for this duty.</div>;
  return (
    <div className="crew-detail" role="table" aria-label="Crew legality for N and N+1 legs">
      <Sectors sectors={sectors} />
      <div className={`cd-row cd-head${showN1 ? '' : ' no-n1'}`} role="row">
        <span>Crew</span>
        <span>Current N legs</span>
        {showN1 && <span>N+1 legs (if OCC diverts: one more sector)</span>}
        <span>Legal for next flight from (last arrival + rest, rest assumed)</span>
      </div>
      {rows.map((c) => {
        const worst = SEV[sev(c)];
        return (
          <div className={`cd-row${showN1 ? '' : ' no-n1'}`} role="row" key={c.crew_id} style={{ background: `var(--${tn(worst)}-bg)`, borderLeft: `3px solid var(--${tn(worst)})` }}>
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
            {showN1 ? (
              <span>
                <Pill tone={tn(c.status_n1)}>{String(c.status_n1).replaceAll('_', ' ')}</Pill>
                <span className="k" style={{ display: 'block' }}>
                  {c.legs_n1} legs · max {fmtDur(c.max_fdp_n1_min)} · {lagText(c.status_n1, c.margin_n1_min)}
                  {c.x && (
                    <>
                      <br />
                      incl. return {c.via}→SHJ {c.x.return_block_min} min ({c.x.return_block_basis}), back {fmtZD(ms(c.x.return_arrival_utc))}
                    </>
                  )}
                </span>
              </span>
            ) : null}
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

  const [scope, setScope] = useState('case'); // 'case' = this case's duties, 'all' = every duty that is not over
  const [shown, setShown] = useState(SHOWN);
  const { flights } = d;
  const { data: allOpen = [] } = useGetOpenCrewDutiesQuery({ scenario_id: d.ctx.scenario_id }, { skip: scope !== 'all' });
  const crew = scope === 'all' ? allOpen : d.crew;
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
    // every duty that is not over, including crew whose legal end is unknown (VERIFICATION_REQUIRED): those go last
    return [...byDuty.values()]
      .sort((a, b) => (a.legal_end_utc ? ms(a.legal_end_utc) : Infinity) - (b.legal_end_utc ? ms(b.legal_end_utc) : Infinity))
      .map((c) => ({ ...c, flight: flights.find((f) => f.duty_id === c.duty_id) }));
  }, [crew, flights]);

  return (
    <div className="crew-view" data-src="v_crew_legality_ranking ORDER BY minutes_until_legal_end">
      <h2 className="lane-h" style={{ marginTop: 4 }}>
        Who runs out of legality next{' '}
        <span className="k">
          {rows.length} duties {scope === 'all' ? 'not over yet (all cases)' : 'on this case'}, soonest legal end first
        </span>{' '}
        <button type="button" className="btn ghost" onClick={() => { setScope(scope === 'all' ? 'case' : 'all'); setShown(SHOWN); }}>
          {scope === 'all' ? 'This case only' : 'All open duties'}
        </button>
      </h2>
      {rows.length === 0 ? (
        <div className="runway">
          <div className="empty">No crew duties that are not over yet.</div>
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
              {rows.slice(0, shown).map((c) => {
                const m = c.margin_min;
                const legalAt = c.legal_end_utc ? ms(c.legal_end_utc) : null;
                const tone = crewTone(m);
                return (
                  <Fragment key={c.duty_id}>
                  <div className="rw-row">
                    <span>
                      <RowSectors dutyId={c.duty_id} scenarioId={d.ctx.scenario_id} fallback={c.duty_legs} />
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
                      <span className="k" style={{ display: 'block' }}>
                        {legalAt != null ? fmtZLD(legalAt) : 'Legal end unknown'}
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
              {rows.length > shown && (
                <div className="rw-row">
                  <button type="button" className="btn ghost" onClick={() => setShown(shown + SHOWN)}>
                    Show {Math.min(SHOWN, rows.length - shown)} more of {rows.length - shown}
                  </button>
                </div>
              )}
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
