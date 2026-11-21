import { useMemo } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { matches } from '@/features/ops/boardFilters';
import { setLens } from '@/features/ops/opsSlice';
import { useBoardFilters } from '@/features/ops/useBoardFilters';
import { isRecovered } from '../lib';

const BOARD_LENSES = ['occ', 'dispatch'];

function Kpi({ k, v, l, s, tone, on, onClick, children }) {
  return (
    <button className={`kpi ${onClick ? '' : 'static'}`} data-kpi={k} aria-pressed={Boolean(on)} aria-label={`${l}: ${typeof v === 'string' || typeof v === 'number' ? v : typeof children === 'string' ? children : ''}${s ? `, ${s}` : ''}${onClick ? '. Filter the board' : ''}`} onClick={onClick} title={onClick ? 'Filter the board' : undefined}>
      <span className={`v ${tone ? `c-${tone}` : ''}`}>{children ?? v}</span>
      <span className="l">{l}</span>
      <span className="s">{s}</span>
    </button>
  );
}

// The KPI bar. Every number is counted with the SAME predicate the board filters with, so a card and its filter agree.
export default function KpiBar({ d, ctx }) {
  const dispatch = useAppDispatch();
  const { chips, only } = useBoardFilters();
  const count = useMemo(() => {
    const c = (key) => d.flights.filter((f) => matches(f, key, ctx)).length;
    const live = d.flights.filter((f) => matches(f, 'affected', ctx));
    return {
      affected: live.length,
      pax: live.reduce((a, f) => a + Number(f.connecting_pax ?? 0), 0),
      paxRisk: live.reduce((a, f) => a + Number(f.pax_at_risk ?? 0), 0),
      high: c('sev:50'),
      medium: d.flights.filter((f) => (f.severity_score ?? 0) >= 30 && (f.severity_score ?? 0) < 50 && !isRecovered(f)).length,
      pending: c('approval'),
      divhold: c('status:divhold'),
      diverted: d.flights.filter((f) => f.diverted_to).length,
      holding: d.flights.filter((f) => f.status === 'HOLDING').length,
      crew: c('crew'),
      verify: c('verify'),
    };
  }, [d.flights, ctx]);

  const apply = (f) => {
    if (!BOARD_LENSES.includes(d.ops.lens)) dispatch(setLens('occ')); // the board lives in the OCC / Dispatch lens
    only(f);
  };
  const on = (f) => chips.length === 1 && chips[0] === f;
  return (
    <div className="kpis" data-src="v_disruption_kpis · v_flight_severity">
      <Kpi k="all" v={count.affected} l="Flights affected" s={`${d.flights.length} watched`} on={on('affected')} onClick={() => apply('affected')} />
      <Kpi k="pax" v={count.paxRisk.toLocaleString()} l="Pax at risk" s={`of ${count.pax.toLocaleString()} connecting`} tone={count.paxRisk > 0 ? 'risk' : undefined}
        onClick={() => toast(`Connecting passengers on these flights: ${count.pax.toLocaleString()}, each connection counted once (from the connecting-pax file). Only ${count.paxRisk.toLocaleString()} are at risk: their onward flight leaves less than 45 minutes after the projected arrival (under the 30 minute minimum connection time they miss it, 30 to 45 minutes is tight, and a connection of more than 24 hours is no longer a connection), or their flight diverted or was cancelled. Passengers on board are not in the supplied data.`, { id: 'pax-explainer', duration: 9000 })} />
      <Kpi k="sev" v={count.high} tone="exceeded" l="High severity" s={`${count.medium} medium`} on={on('sev:50')} onClick={() => apply('sev:50')} />
      <Kpi k="pending" v={count.pending} tone="risk" l="Decisions pending" s="waiting for approval" on={on('approval')} onClick={() => apply('approval')} />
      <Kpi k="div" v={`${count.diverted} / ${count.holding}`} l="Diverted / holding" s="aircraft" on={on('status:divhold')} onClick={() => apply('status:divhold')} />
      <Kpi k="crew" v={count.crew} tone="risk" l="Crew at risk" s="margin < 60 min" on={on('crew')} onClick={() => apply('crew')} />
      <Kpi k="verify" v={count.verify} tone="verify" l="Needs verification" s="data gaps + requests" on={on('verify')} onClick={() => apply('verify')} />
    </div>
  );
}
