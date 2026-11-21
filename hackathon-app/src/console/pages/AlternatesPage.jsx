import { useState } from 'react';
import toast from 'react-hot-toast';
import { useCreateStationLoginMutation, useGetAlternateAirportsQuery, useSaveAlternateMutation, useSearchAirportsQuery } from '@/features/ops/opsApi';
import { useDebounce } from '@/hooks/useDebounce';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { useConsole } from '../ConsoleContext';
import { Empty, Pill } from '../ui/ui';
import './pages.css';

const BLANK = { alt_iata: '', name: '', priority: 100, road_positioning_min: '', max_parking_stands: '', handling_contract: true, fuel_available: true, customs_24h: true, notes: '', is_active: true };
const num = (v) => (v === '' || v == null ? null : Number(v));
const yn = (v) => (v ? <Pill tone="legal">Yes</Pill> : <Pill tone="exceeded">No</Pill>);

// The alternates the engine may divert to. OCC and admin add, edit and switch them off; nothing is deleted. A change re-ranks the open cases.
export default function AlternatesPage() {
  const d = useConsole();
  const role = d.actor?.role_code;
  const canEdit = ['OCC', 'ADMIN'].includes(role);
  const hub = d.kase?.hub_iata ?? 'SHJ';
  const { data = [], isLoading } = useGetAlternateAirportsQuery({ hub });
  const [save, { isLoading: saving }] = useSaveAlternateMutation();
  const [makeLogin] = useCreateStationLoginMutation();
  const [f, setF] = useState(BLANK);
  const [editing, setEditing] = useState(false);
  const [term, setTerm] = useState('');
  const q = useDebounce(term, 300);
  const { data: found = [] } = useSearchAirportsQuery({ q }, { skip: editing || q.trim().length < 2 });
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));
  const known = new Set(data.map((a) => a.alt_iata));

  const reset = () => { setF(BLANK); setEditing(false); setTerm(''); };
  const edit = (a) => {
    setEditing(true);
    setF({ alt_iata: a.alt_iata, name: a.name, priority: a.priority, road_positioning_min: a.road_positioning_min ?? '', max_parking_stands: a.max_parking_stands ?? '',
      handling_contract: a.handling_contract, fuel_available: a.fuel_available, customs_24h: a.customs_24h, notes: a.notes ?? '', is_active: a.is_active });
    window.scrollTo?.({ top: 0, behavior: 'smooth' });
  };
  const send = async (body, ok) => {
    try {
      await save({ hub_iata: hub, ...body }).unwrap();
      toast.success(ok);
      return true;
    } catch (e) {
      toast.error(getErrorMessage(e));
      return false;
    }
  };
  const submit = async (e) => {
    e.preventDefault();
    if (!f.alt_iata) return toast.error('Pick an airport first');
    const done = await send(
      { alt_iata: f.alt_iata, priority: Number(f.priority) || 100, road_positioning_min: num(f.road_positioning_min), max_parking_stands: num(f.max_parking_stands),
        handling_contract: f.handling_contract, fuel_available: f.fuel_available, customs_24h: f.customs_24h, notes: f.notes.trim() || null, is_active: f.is_active },
      `${f.alt_iata} ${editing ? 'updated' : 'added'}. Open cases are being re-ranked.`,
    );
    if (done) reset();
  };
  const toggle = (a) =>
    send({ alt_iata: a.alt_iata, priority: a.priority, road_positioning_min: a.road_positioning_min, max_parking_stands: a.max_parking_stands, handling_contract: a.handling_contract,
      fuel_available: a.fuel_available, customs_24h: a.customs_24h, notes: a.notes, is_active: !a.is_active }, `${a.alt_iata} switched ${a.is_active ? 'off' : 'on'}. Open cases are being re-ranked.`);
  const login = async (a) => {
    try {
      const r = await makeLogin({ alt: a.alt_iata }).unwrap();
      toast.success(`Created ${r.username}. ${r.note}`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <div className="page">
      <h2>Alternate airports for {hub}</h2>
      <p className="lead">
        The airports the engine may divert to. Add one to test a what-if, switch one off to take it out of the ranking, or change its road time, stands, fuel and handling.
        Nothing is deleted. A change re-ranks every open case at once. A new alternate shows “?” in the top strip until someone enters its status.
      </p>

      {canEdit ? (
        <form className="rule-form" onSubmit={submit} aria-label={editing ? `Edit ${f.alt_iata}` : 'Add an alternate'}>
          <h3 className="sec" style={{ marginTop: 6 }}>{editing ? `Edit ${f.alt_iata} · ${f.name}` : 'Add an alternate'}</h3>
          {!editing && (
            <div style={{ marginBottom: 10 }}>
              <label className="field-l k" htmlFor="alt-search">Airport (code, name or country)</label>
              <input id="alt-search" className="field-in" style={{ width: 360, maxWidth: '100%' }} placeholder="e.g. DXB or Dubai" value={f.alt_iata ? `${f.alt_iata} · ${f.name}` : term}
                onChange={(e) => { setF((x) => ({ ...x, alt_iata: '', name: '' })); setTerm(e.target.value); }} autoComplete="off" />
              {!f.alt_iata && found.length > 0 && (
                <div className="opt-chips" style={{ marginTop: 6 }}>
                  {found.filter((a) => a.iata !== hub).map((a) => (
                    <button type="button" key={a.iata} className="btn" disabled={known.has(a.iata)} title={known.has(a.iata) ? 'Already an alternate' : `${a.name}, ${a.country}`}
                      onClick={() => { set('alt_iata', a.iata); set('name', a.name); }}>
                      <b>{a.iata}</b> {a.name}{known.has(a.iata) ? ' (already added)' : ''}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
          <div className="act" style={{ alignItems: 'flex-end', gap: 12 }}>
            <label className="field-l k">Priority<input className="field-in" type="number" min="1" max="999" style={{ width: 90 }} value={f.priority} onChange={(e) => set('priority', e.target.value)} /><small className="k"> lower = preferred</small></label>
            <label className="field-l k">Road time from {hub} (min)<input className="field-in" type="number" min="0" max="720" style={{ width: 110 }} placeholder="none" value={f.road_positioning_min} onChange={(e) => set('road_positioning_min', e.target.value)} /></label>
            <label className="field-l k">Parking stands<input className="field-in" type="number" min="0" max="200" style={{ width: 90 }} placeholder="?" value={f.max_parking_stands} onChange={(e) => set('max_parking_stands', e.target.value)} /></label>
            <label className="sw"><input type="checkbox" checked={f.handling_contract} onChange={(e) => set('handling_contract', e.target.checked)} /> Handling contract</label>
            <label className="sw"><input type="checkbox" checked={f.fuel_available} onChange={(e) => set('fuel_available', e.target.checked)} /> Fuel available</label>
            <label className="sw"><input type="checkbox" checked={f.customs_24h} onChange={(e) => set('customs_24h', e.target.checked)} /> Customs 24 h</label>
            {editing && <label className="sw"><input type="checkbox" checked={f.is_active} onChange={(e) => set('is_active', e.target.checked)} /> Active</label>}
          </div>
          <label className="field-l k" style={{ display: 'block', marginTop: 10 }}>Notes
            <input className="field-in" style={{ width: '100%', maxWidth: 560 }} maxLength={300} value={f.notes} onChange={(e) => set('notes', e.target.value)} placeholder="optional" />
          </label>
          <div className="act" style={{ marginTop: 12 }}>
            <button className="btn primary" disabled={saving || !f.alt_iata}>{editing ? 'Save changes' : 'Add alternate'}</button>
            {(editing || f.alt_iata) && <button type="button" className="btn ghost" onClick={reset}>Cancel</button>}
          </div>
        </form>
      ) : (
        <p className="k">Only OCC or admin can change the alternates.</p>
      )}

      <h3 className="sec">Alternates ({data.filter((a) => a.is_active).length} active)</h3>
      {isLoading ? <p className="k">Loading…</p> : data.length === 0 ? <Empty>No alternates for {hub} yet.</Empty> : (
        <div className="tbl-wrap">
          <table className="tbl">
            <thead>
              <tr><th>Airport</th><th>Priority</th><th>Road time</th><th>Stands</th><th>Handling</th><th>Fuel</th><th>Customs</th><th>Used in 2026</th><th>Station login</th><th>Status</th>{canEdit && <th />}</tr>
            </thead>
            <tbody>
              {data.map((a) => (
                <tr key={a.alt_iata} style={a.is_active ? undefined : { opacity: 0.55 }}>
                  <td><b>{a.alt_iata}</b> {a.name}<div className="k">{a.country}{a.notes ? ` · ${a.notes}` : ''}</div></td>
                  <td>{a.priority}</td>
                  <td>{a.road_positioning_min == null ? <span className="k">no road link</span> : `${a.road_positioning_min} min`}</td>
                  <td>{a.max_parking_stands ?? <span className="k">?</span>}</td>
                  <td>{yn(a.handling_contract)}</td>
                  <td>{yn(a.fuel_available)}</td>
                  <td>{yn(a.customs_24h)}</td>
                  <td>{a.historical_diversions ? `${a.historical_diversions} diversions` : <span className="k">none</span>}</td>
                  <td>
                    {a.station_users.length ? a.station_users.join(', ') : <span className="k">none</span>}
                    {role === 'ADMIN' && a.station_users.length === 0 && <div><button className="btn" onClick={() => login(a)}>Create login</button></div>}
                  </td>
                  <td>{a.is_active ? <Pill tone="legal">Active</Pill> : <Pill tone="verify">Off</Pill>}</td>
                  {canEdit && <td className="act"><button className="btn" onClick={() => edit(a)}>Edit</button><button className="btn ghost" disabled={saving} onClick={() => toggle(a)}>{a.is_active ? 'Switch off' : 'Switch on'}</button></td>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
