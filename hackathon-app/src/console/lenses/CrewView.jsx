import { useMemo, useState } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { useNow } from '@/hooks/useNow';
import { Cd, Pill } from '../ui/ui';
import { crewTone, fmtTime, fmtZ, ms, verdictPill } from '../lib';
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

// Crew Control: who runs out of legality next. One row per duty, worst crew member first, soonest legal end on top.
export default function CrewView({ d }) {
  const dispatch = useAppDispatch();
  const [pick, setPick] = useState(null); // flight to find a replacement for

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
      if (worse) byDuty.set(c.duty_id, { ...c, crewCount: (cur?.crewCount ?? 0) + 1 });
      else cur.crewCount += 1;
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
                  <div className="rw-row" key={c.duty_id}>
                    <span>
                      <b>{c.flight?.flight_no ?? c.duty_legs}</b>{' '}
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
                        {fmtZ(legalAt)} / {fmtTime(legalAt)} SHJ
                      </span>
                    </span>
                    <Ribbon signIn={ms(c.sign_in_utc)} legal={legalAt} disc={ms(c.discretion_end_utc)} proj={ms(c.projected_end_utc)} />
                    <span>
                      {m == null ? (
                        <Pill tone={verdictPill[c.status]?.slice(2) ?? 'verify'}>Verify</Pill>
                      ) : (
                        <Pill tone={tone}>{m < 0 ? `${-m} min over` : `${m} min`}</Pill>
                      )}
                    </span>
                    <span className="rw-actions">
                      {c.flight && (m == null || m < 60) && (
                        <button type="button" className="btn" onClick={() => setPick(c.flight)}>
                          Find replacement
                        </button>
                      )}
                      {c.flight && (
                        <button type="button" className="btn ghost" onClick={() => dispatch(selectFlight(c.flight.flight_id))}>
                          Open
                        </button>
                      )}
                    </span>
                  </div>
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
