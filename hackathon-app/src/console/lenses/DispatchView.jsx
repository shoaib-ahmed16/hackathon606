import { useMemo } from 'react';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms, MIN, fmtZ, isAirborne, plainCodes } from '../lib';
import { Cd, Pill } from '../ui/ui';
import { useNow } from '@/hooks/useNow';
import './lenses.css';

// The dispatcher's job: fuel and alternates across every airborne or holding flight, in one table (not one flight at a time).
// Sorted by who must decide first. Click a row for the full flight panel.
export default function DispatchView({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const rows = useMemo(() => {
    const fuelBy = Object.fromEntries(d.fuel.map((x) => [x.flight_id, x]));
    const dlBy = Object.fromEntries(d.deadlines.map((x) => [x.flight_id, x]));
    const stands = Object.fromEntries(d.airport.map((a) => [a.iata, a.parking_available]));
    return d.flights
      .filter((f) => isAirborne(f) && !f.diverted_to)
      .map((f) => {
        const fuel = fuelBy[f.flight_id];
        const opts = d.options.filter((o) => o.flight_id === f.flight_id).sort((a, b) => a.rank - b.rank);
        const best = opts.find((o) => o.is_executable && o.alternate_iata);
        const dl = dlBy[f.flight_id];
        return {
          f, fuel, best, dl,
          endurance: fuel ? Math.floor((ms(fuel.as_of_utc) + fuel.est_holding_endurance_min * MIN - now) / MIN) : null,
          stands: best ? stands[best.alternate_iata] : null,
          at: dl?.deadline_utc ? ms(dl.deadline_utc) : null,
        };
      })
      .sort((a, b) => (a.at ?? Infinity) - (b.at ?? Infinity));
  }, [d.flights, d.fuel, d.options, d.deadlines, d.airport, now]);

  return (
    <div className="dispatch-view" data-src="flight_fuel_estimate · rank_alternates · v_airport_status_current">
      <h2 className="lane-h">
        Fuel and alternates <span className="k">{rows.length} flight{rows.length === 1 ? '' : 's'} in the air or holding · soonest decision first</span>
      </h2>
      {rows.length === 0 ? (
        <div className="empty">No aircraft are airborne or holding on this case right now.</div>
      ) : (
        <div className="dv-wrap">
          <table className="dv-table">
            <thead>
              <tr>
                <th>Flight</th><th>Where</th><th>Fuel on board</th><th>Endurance</th><th>Best alternate</th><th>Spare fuel on arrival</th><th>Stands there</th><th>Leave the hold by</th><th>Engine says</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(({ f, fuel, best, dl, endurance, stands, at }) => (
                <tr key={f.flight_id} tabIndex={0} className={d.ops.selectedFlightId === f.flight_id ? 'on' : ''} onClick={() => dispatch(selectFlight(f.flight_id))} onKeyDown={(e) => e.key === 'Enter' && dispatch(selectFlight(f.flight_id))}>
                  <td><b>{f.flight_no}</b><div className="k">{f.dep_iata}→{f.planned_arr_iata} · {f.registration ?? 'no tail'}</div></td>
                  <td>{f.status === 'HOLDING' ? 'Holding' : 'Airborne'}<div className="k">ETA {fmtZ(ms(f.eta_utc ?? f.sta_utc))}</div></td>
                  <td>{fuel?.fuel_on_board_kg != null ? `${Number(fuel.fuel_on_board_kg).toLocaleString()} kg` : <span className="c-verify">? not reported</span>}{fuel && <div className="k">{String(fuel.quality).toLowerCase()}</div>}</td>
                  <td>{endurance == null ? <span className="c-verify">?</span> : <b className={endurance < 20 ? 'c-exceeded' : endurance < 45 ? 'c-risk' : ''}>{Math.max(0, endurance)} min</b>}</td>
                  <td>{best ? <b>{best.alternate_iata}</b> : <span className="c-verify">none executable</span>}</td>
                  <td>{best?.fuel_margin_min == null ? '—' : `${best.fuel_margin_min} min`}</td>
                  <td>{stands == null ? <span className="k">?</span> : stands}</td>
                  <td>{at ? <><Cd at={at} /><div className="k">{fmtZ(at)}</div></> : <span className="k">{dl ? plainCodes(dl.reason) : '—'}</span>}</td>
                  <td>{f.recommendation ? <Pill tone={f.recommendation === 'DIVERT' ? 'exceeded' : f.recommendation === 'HOLD' ? 'risk' : 'verify'}>{f.recommendation === 'DIVERT' && f.recommended_alternate ? `Divert to ${f.recommended_alternate}` : f.recommendation.replaceAll('_', ' ').toLowerCase()}</Pill> : <span className="k">—</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="k" style={{ marginTop: 10 }}>Fuel figures are in kilograms where reported and in minutes of holding where not; the quality label says whether they are reported or estimated. Stands are as last reported by the station.</p>
    </div>
  );
}
