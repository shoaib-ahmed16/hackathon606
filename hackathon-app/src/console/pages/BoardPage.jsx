import { useCallback, useEffect, useMemo, useRef } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { passesAll, priorityOf, rulesFor, filterLabel } from '@/features/ops/boardFilters';
import { selectFlight } from '@/features/ops/opsSlice';
import { useBoardFilters } from '@/features/ops/useBoardFilters';
import { ms } from '@/features/ops/helpers';
import { useConsole } from '../ConsoleContext';
import { useMinuteNow } from '@/hooks/useNow';
import { MIN } from '@/features/ops/time';
import DispatchView from '../lenses/DispatchView';
import Filters from '../board/Filters';
import KpiBar from '../board/KpiBar';
import Row from '../board/Row';
import FlightPanel from '../panel/FlightPanel';
import CrewView from '../lenses/CrewView';
import RecoveryView from '../lenses/RecoveryView';
import StationView from '../lenses/StationView';
import { isAirborne, isRecovered } from '../lib';

const LANES = [
  ['act', 'Act now', 'under 15 min', 'lane-act'],
  ['soon', 'Decide soon', '15–45 min, or needs verifying', 'lane-soon'],
  ['mon', 'Monitoring', 'more than 45 min', ''],
  ['done', 'Recovered', '', ''],
];
const EMPTY = [];

function Board({ d }) {
  const dispatch = useAppDispatch();
  const minute = useMinuteNow();
  const { chips, clear } = useBoardFilters();
  const open = useCallback((id) => dispatch(selectFlight(id)), [dispatch]);
  const nowMin = Math.floor(minute / MIN);

  const dlBy = useMemo(() => Object.fromEntries(d.deadlines.map((x) => [x.flight_id, x])), [d.deadlines]);
  const fuelBy = useMemo(() => Object.fromEntries(d.fuel.map((x) => [x.flight_id, ms(x.as_of_utc) + x.est_holding_endurance_min * MIN])), [d.fuel]);
  const requested = useMemo(() => new Set(d.openRequests.map((r) => r.flight_id)), [d.openRequests]);
  const hubRestricted = Boolean(d.kase?.hub_restricted);
  const ctx = useMemo(() => ({ fuelBy, requested, subscribed: d.subscribed, ruleMatches: d.ruleMatches, hubRestricted, nowMs: nowMin * MIN }), [fuelBy, requested, d.subscribed, d.ruleMatches, hubRestricted, nowMin]);
  const byFlight = useMemo(() => {
    const m = {};
    for (const x of d.approvals) (m[x.flight_id] ??= []).push(x);
    return m; // approvals arrive newest first
  }, [d.approvals]);
  const rulesBy = useMemo(() => Object.fromEntries(d.flights.map((f) => [f.flight_id, rulesFor(d.ruleMatches, f.flight_id)])), [d.flights, d.ruleMatches]);

  const lanes = useMemo(() => {
    const list = d.flights.filter((f) => passesAll(f, chips, ctx));
    const laneOf = (f) => {
      if (isRecovered(f)) return 'done';
      const dl = dlBy[f.flight_id];
      // no deadline: unknown fuel in the air needs a look soon; a flight on the ground with nothing running is just monitored
      if (!dl?.deadline_utc) return isAirborne(f) || f.diverted_to ? 'soon' : 'mon';
      const m = (ms(dl.deadline_utc) - nowMin * MIN) / MIN;
      return m < 15 ? 'act' : m <= 45 ? 'soon' : 'mon';
    };
    const key = (f) => (dlBy[f.flight_id]?.deadline_utc ? ms(dlBy[f.flight_id].deadline_utc) : nowMin * MIN + 20 * MIN);
    const out = { act: [], soon: [], mon: [], done: [] };
    for (const f of list) out[laneOf(f)].push(f);
    for (const k in out)
      out[k].sort((a, b) => priorityOf(d.ruleMatches, a.flight_id) - priorityOf(d.ruleMatches, b.flight_id) || key(a) - key(b) || (b.severity_score ?? 0) - (a.severity_score ?? 0));
    return out;
  }, [d.flights, d.ruleMatches, chips, ctx, dlBy, nowMin]);

  // open the most urgent flight when the board loads, so the right-hand panel is never an empty "select a flight" box
  const opened = useRef(null);
  const topAct = lanes.act[0]?.flight_id;
  useEffect(() => {
    if (d.ops.selectedFlightId == null && topAct != null && opened.current !== d.ctx.case_id) {
      opened.current = d.ctx.case_id;
      dispatch(selectFlight(topAct));
    }
  }, [topAct, d.ops.selectedFlightId, d.ctx.case_id, dispatch]);

  const shown = Object.values(lanes).reduce((n, l) => n + l.length, 0);
  return (
    <>
      <KpiBar d={d} ctx={ctx} />
      <Filters d={d} />
      <div className="board-count" aria-live="polite" data-testid="board-count">
        Showing <b>{shown}</b> of {d.flights.length} flights
        {chips.length > 0 && ` · ${chips.map((c) => filterLabel(c, d.ruleMatches)).join(' + ')}`}
      </div>
      <div className="board" role="listbox" aria-label="Flights by deadline">
        {shown === 0 && (
          <div className="empty">
            No flights match these filters. <button className="why-btn" onClick={clear}>Clear filters</button>
          </div>
        )}
        {LANES.map(([k, name, sub, cls]) => {
          const items = lanes[k];
          if (!items.length) return null;
          return (
            <div className={`lane ${cls}`} key={k}>
              <h2 className="lane-h">{name} <span className="k">{sub}{sub ? ' · ' : ''}{items.length} flight{items.length > 1 ? 's' : ''}</span></h2>
              <div className="rows">
                {items.map((f) => (
                  <Row
                    key={f.flight_id}
                    f={f}
                    cur={(byFlight[f.flight_id] ?? EMPTY).find((x) => ['PROPOSED', 'APPROVED'].includes(x.status))}
                    last={(byFlight[f.flight_id] ?? EMPTY)[0]}
                    dl={dlBy[f.flight_id]}
                    fuelEnd={fuelBy[f.flight_id]}
                    rules={rulesBy[f.flight_id]}
                    selected={d.ops.selectedFlightId === f.flight_id}
                    watched={d.subscribed.has(f.flight_id)}
                    now={minute}
                    onOpen={open}
                  />
                ))}
              </div>
            </div>
          );
        })}
        <p className="k" style={{ marginTop: 14 }}>
          * Estimated values. Severity = deadline 40 · crew 20 · LVP 15 · connecting pax 15 · unverified data 10. Weights to be agreed with OCC.
        </p>
      </div>
    </>
  );
}

// The console: the lens decides the centre view; the flight panel sits on the right for the board and crew lenses.
export default function BoardPage() {
  const d = useConsole();
  const dispatch = useAppDispatch();
  const lens = d.ops.lens;
  const hasPanel = lens === 'occ' || lens === 'dispatch' || lens === 'crew';
  const selected = d.ops.selectedFlightId;
  const close = useCallback(() => dispatch(selectFlight(null)), [dispatch]);

  // keyboard: J / K move between flights, Esc closes the panel (Enter opens a focused row)
  useEffect(() => {
    const onKey = (e) => {
      if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName) || document.querySelector('.scrim.open, .drawer.open')) return;
      if (!['occ', 'dispatch'].includes(lens)) return;
      const rows = [...document.querySelectorAll('.row')];
      const i = rows.findIndex((r) => Number(r.dataset.id) === selected);
      if (e.key === 'j' && rows[i + 1]) { dispatch(selectFlight(Number(rows[i + 1].dataset.id))); rows[i + 1].focus(); }
      if (e.key === 'k' && rows[i - 1]) { dispatch(selectFlight(Number(rows[i - 1].dataset.id))); rows[i - 1].focus(); }
      if (e.key === 'Escape' && selected) close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [lens, selected, dispatch, close]);

  return (
    <div className={`main${hasPanel ? " has-panel" : ""}`} style={hasPanel ? undefined : { gridTemplateColumns: '1fr' }}>
      <section className="view" aria-live="polite">
        {lens === 'occ' && <Board d={d} />}
        {lens === 'dispatch' && <DispatchView d={d} />}
        {lens === 'crew' && <CrewView d={d} />}
        {lens === 'station' && <StationView d={d} />}
        {lens === 'recovery' && <RecoveryView d={d} />}
      </section>
      {hasPanel && (
        <>
          <div className={`panel-scrim ${selected ? 'open' : ''}`} onClick={close} />
          <aside className={`panel ${selected ? 'open' : ''}`} aria-label="Flight details">
            <FlightPanel d={d} onClose={close} />
          </aside>
        </>
      )}
    </div>
  );
}
