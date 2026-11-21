import { useMemo } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { matches } from '@/features/ops/boardFilters';
import { selectFlight, setLens } from '@/features/ops/opsSlice';
import { useBoardFilters } from '@/features/ops/useBoardFilters';
import { ms } from '@/features/ops/helpers';
import { useNow } from '@/hooks/useNow';
import { Cd } from '../ui/ui';
import { isRecovered, toneFor } from '../lib';

const BOARD_LENSES = ['occ', 'dispatch'];

function Kpi({ k, v, l, s, tone, on, onClick, children }) {
  return (
    <button className={`kpi ${onClick ? '' : 'static'}`} data-kpi={k} aria-pressed={Boolean(on)} onClick={onClick} title={onClick ? 'Filter the board' : undefined}>
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
  const now = useNow();
  const count = useMemo(() => {
    const c = (key) => d.flights.filter((f) => matches(f, key, ctx)).length;
    const live = d.flights.filter((f) => matches(f, 'affected', ctx));
    return {
      affected: live.length,
      pax: live.reduce((a, f) => a + Number(f.connecting_pax ?? 0), 0),
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

  const dated = d.deadlines.filter((x) => x.deadline_utc && !d.flights.find((f) => f.flight_id === x.flight_id && isRecovered(f))).sort((a, b) => ms(a.deadline_utc) - ms(b.deadline_utc));
  const next = dated.find((x) => ms(x.deadline_utc) >= now - 3600000) ?? dated[dated.length - 1]; // overdue within the last hour comes first
  // an overdue deadline is shown short ("7 min late") so it fits the card; the long "passed 7 min 40 s ago" stays in the bar above
  const lateMin = next && ms(next.deadline_utc) < now ? Math.max(1, Math.floor((now - ms(next.deadline_utc)) / 60000)) : null;
  const lateText = lateMin == null ? '' : lateMin < 60 ? `${lateMin} min late` : `${Math.floor(lateMin / 60)} h ${String(lateMin % 60).padStart(2, '0')} late`;
  const apply = (f) => {
    if (!BOARD_LENSES.includes(d.ops.lens)) dispatch(setLens('occ')); // the board lives in the OCC / Dispatch lens
    only(f);
  };
  const on = (f) => chips.length === 1 && chips[0] === f;
  return (
    <div className="kpis" data-src="v_disruption_kpis · v_flight_severity">
      <Kpi k="all" v={count.affected} l="Flights affected" s={`${d.flights.length} watched`} on={on('affected')} onClick={() => apply('affected')} />
      <Kpi k="pax" v={count.pax.toLocaleString()} l="Pax affected" s="connecting only" onClick={() => toast('Passengers on board are not in the supplied data. Connecting passengers come from the connecting-pax file; on-board counts need aeroMart bookings.')} />
      <Kpi k="sev" v={count.high} tone="exceeded" l="High severity" s={`${count.medium} medium`} on={on('sev:50')} onClick={() => apply('sev:50')} />
      <Kpi k="pending" v={count.pending} tone="risk" l="Decisions pending" s="waiting for approval" on={on('approval')} onClick={() => apply('approval')} />
      <Kpi
        k="next"
        tone={next ? toneFor(ms(next.deadline_utc), now) : undefined}
        l="Next deadline"
        s={next ? (lateMin != null ? `${next.flight_no} · deadline passed` : next.flight_no) : ''}
        onClick={next ? () => dispatch(selectFlight(next.flight_id)) : undefined}
      >
        {next ? (lateMin != null ? lateText : <Cd at={ms(next.deadline_utc)} />) : '—'}
      </Kpi>
      <Kpi k="div" v={`${count.diverted} / ${count.holding}`} l="Diverted / holding" s="aircraft" on={on('status:divhold')} onClick={() => apply('status:divhold')} />
      <Kpi k="crew" v={count.crew} tone="risk" l="Crew at risk" s="margin < 60 min" on={on('crew')} onClick={() => apply('crew')} />
      <Kpi k="verify" v={count.verify} tone="verify" l="Needs verification" s="data gaps + requests" on={on('verify')} onClick={() => apply('verify')} />
    </div>
  );
}
