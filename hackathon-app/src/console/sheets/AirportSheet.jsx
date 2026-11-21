import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAddRecordMutation } from '@/features/ops/opsApi';
import { iso, ms, stampMs } from '@/features/ops/helpers';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { ReasonChips, Sheet } from '../ui/ui';
import { fmtZ } from '../lib';

const toLocalInput = (t) => (t ? new Date(t + 4 * 3600e3).toISOString().slice(0, 16) : ''); // Dubai time, no DST
const fromLocalInput = (v) => new Date(`${v}:00+04:00`).toISOString();
const Tri = ({ label, value, onChange }) => (
  <div style={{ marginTop: 12 }}>
    <div className="field-l" style={{ margin: 0 }}>{label}</div>
    <div className="reason-chips" style={{ marginTop: 6 }}>
      {[[true, 'Yes'], [false, 'No'], [null, 'Unknown']].map(([v, t]) => (
        <button key={t} type="button" aria-pressed={value === v} onClick={() => onChange(v)}>{t}</button>
      ))}
    </div>
  </div>
);

// Verify or update an airport's status. Works for an alternate that shows "verify" (nobody has confirmed it) and for the hub
// itself (closure, LVP, visibility, reopening forecast, arrival capacity). It writes an airport_status_event: the database then
// queues a reassessment and the engine re-ranks every affected flight, so there is nothing else to do.
export default function AirportSheet({ d, iata, onClose }) {
  const [add, { isLoading }] = useAddRecordMutation();
  const cur = d.airport.find((a) => a.iata === iata);
  const isHub = iata === d.kase?.hub_iata;
  const [status, setStatus] = useState(cur?.op_status ?? 'OPEN');
  const [stands, setStands] = useState(cur?.parking_available ?? '');
  const [fuel, setFuel] = useState(cur?.fuel_ok ?? null);
  const [handling, setHandling] = useState(cur?.handling_ok ?? null);
  const [minima, setMinima] = useState(cur?.weather_above_minima ?? null);
  const [lvp, setLvp] = useState(Boolean(cur?.lvp_in_force));
  const [vis, setVis] = useState(cur?.visibility_m ?? '');
  const [cap, setCap] = useState(cur?.arrival_capacity_per_hr ?? '');
  const [reopen, setReopen] = useState(toLocalInput(cur?.expected_reopen_utc ? ms(cur.expected_reopen_utc) : null));
  const [reason, setReason] = useState(cur?.reason ?? '');
  const [quality, setQuality] = useState('MEASURED');
  const [note, setNote] = useState('');
  const num = (v) => (v === '' || v == null ? null : Number(v));
  const needsReopen = isHub && status !== 'OPEN';

  const save = async () => {
    try {
      await add({
        table: 'airport_status_event',
        body: {
          scenario_id: d.ctx.scenario_id,
          iata,
          op_status: status,
          reason: reason.trim() || null,
          visibility_m: isHub ? num(vis) : null,
          lvp_in_force: isHub ? lvp : false,
          arrival_capacity_per_hr: isHub ? num(cap) : null,
          parking_available: num(stands),
          weather_above_minima: minima,
          handling_ok: handling,
          fuel_ok: fuel,
          effective_from_utc: iso(stampMs(d.kase)),
          expected_reopen_utc: needsReopen && reopen ? fromLocalInput(reopen) : null,
          quality,
          entered_by: d.actor.user_id,
          note: note.trim() || `${isHub ? 'Hub' : 'Alternate'} status entered from the console`,
        },
      }).unwrap();
      toast.success(`${iata} saved as ${status.toLowerCase()}. The engine re-ranks the affected flights.`);
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const canSave = !isLoading && (!needsReopen || reopen);

  return (
    <Sheet
      title={`${cur ? 'Update' : 'Verify'} ${iata}${isHub ? ' (hub)' : ''}`}
      sub={cur ? `Now: ${cur.op_status.toLowerCase()}${cur.parking_available != null ? `, ${cur.parking_available} stands` : ''}${cur.expected_reopen_utc ? `, reopening ${fmtZ(ms(cur.expected_reopen_utc))}` : ''} (${String(cur.quality ?? '').toLowerCase()}).` : 'No status is on record for this airport, so the engine will not treat it as usable. Confirm it here.'}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn primary" disabled={!canSave} onClick={save}>Save and re-rank</button>
        </>
      }
    >
      <div className="field-l" style={{ marginTop: 0 }}>Status</div>
      <div className="reason-chips">
        {['OPEN', 'RESTRICTED', 'CLOSED'].map((s) => (
          <button key={s} type="button" aria-pressed={status === s} onClick={() => setStatus(s)}>{s.toLowerCase()}</button>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginTop: 12 }}>
        <label><div className="field-l" style={{ margin: 0 }}>Stands free</div>
          <input className="field-in" type="number" min="0" style={{ width: 110, marginTop: 6 }} value={stands} onChange={(e) => setStands(e.target.value)} /></label>
        {isHub && (
          <>
            <label><div className="field-l" style={{ margin: 0 }}>Visibility / RVR (m)</div>
              <input className="field-in" type="number" min="0" style={{ width: 130, marginTop: 6 }} value={vis} onChange={(e) => setVis(e.target.value)} /></label>
            <label><div className="field-l" style={{ margin: 0 }}>Arrivals per hour</div>
              <input className="field-in" type="number" min="0" style={{ width: 130, marginTop: 6 }} value={cap} onChange={(e) => setCap(e.target.value)} /></label>
          </>
        )}
      </div>
      {isHub && (
        <label className="check-row" style={{ marginTop: 12 }}>
          <input type="checkbox" checked={lvp} onChange={(e) => setLvp(e.target.checked)} />
          <span>Low Visibility Procedures in force (pilots must be LVP-qualified to land)</span>
        </label>
      )}
      {needsReopen && (
        <>
          <div className="field-l">Expected reopening (Dubai time, required while not open)</div>
          <input className="field-in" type="datetime-local" value={reopen} onChange={(e) => setReopen(e.target.value)} />
        </>
      )}
      <Tri label="Fuel available" value={fuel} onChange={setFuel} />
      <Tri label="Handling available" value={handling} onChange={setHandling} />
      <Tri label="Weather above minima" value={minima} onChange={setMinima} />
      {isHub && (
        <>
          <div className="field-l">Reason</div>
          <input className="field-in" placeholder="e.g. FOG, runway closed" value={reason} onChange={(e) => setReason(e.target.value)} />
        </>
      )}
      <div className="field-l">Source</div>
      <ReasonChips
        options={['Reported / observed', 'Forecast', 'Manual entry']}
        value={{ MEASURED: 'Reported / observed', FORECAST: 'Forecast', MANUAL: 'Manual entry' }[quality]}
        onChange={(v) => setQuality({ 'Reported / observed': 'MEASURED', Forecast: 'FORECAST', 'Manual entry': 'MANUAL' }[v])}
      />
      <textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder="Note (who confirmed it, how)" />
    </Sheet>
  );
}
