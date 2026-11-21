import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useCreateCaseMutation, useGetScenariosQuery } from '@/features/ops/opsApi';
import { selectCase } from '@/features/ops/opsSlice';
import { scenarioNowMs } from '@/features/ops/helpers';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Sheet } from '../ui/ui';
import '../lenses/lenses.css';

const dubaiDay = (t) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dubai' }).format(t); // YYYY-MM-DD
const toUtc = (local) => new Date(`${local}:00+04:00`).toISOString(); // inputs are Dubai time (UTC+4, no DST)

// New disruption case: pick scenario, airport and a time window; the watch list is filled with the real flights.
export default function NewCaseSheet({ d, onClose }) {
  const dispatch = useAppDispatch();
  const scenarios = useGetScenariosQuery();
  const [create, { isLoading }] = useCreateCaseMutation();
  const kase = d.kase;
  const [f, setF] = useState(() => {
    const day = dubaiDay(scenarioNowMs(kase));
    return {
      scenario_id: kase?.scenario_id ?? 1,
      title: '',
      hub_iata: kase?.hub_iata ?? 'SHJ',
      from: `${day}T00:00`,
      to: `${day}T23:59`,
      simulate_fog: false,
      reopen_after_min: 120,
    };
  });
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const valid = f.hub_iata.trim().length === 3 && f.from && f.to && f.from < f.to;

  const submit = async () => {
    try {
      const hub = f.hub_iata.trim().toUpperCase();
      const res = await create({
        scenario_id: Number(f.scenario_id),
        hub_iata: hub,
        from_utc: toUtc(f.from),
        to_utc: toUtc(f.to),
        title: f.title.trim() || `${hub} arrivals ${f.from.slice(0, 10)}`,
        simulate_fog: f.simulate_fog,
        reopen_after_min: Number(f.reopen_after_min),
        cause: f.simulate_fog ? 'FOG' : 'OPS',
      }).unwrap();
      dispatch(selectCase(res));
      toast.success(`Case created with ${res.flights} flights${res.recommended ? `, ${res.recommended} recommendations` : ''}`);
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <Sheet
      title="New case"
      sub="The watch list is every scheduled flight arriving at the airport in the window, with its real crew and legality."
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn primary" disabled={isLoading || !valid} onClick={submit}>
            {isLoading ? 'Creating…' : 'Create case'}
          </button>
        </>
      }
    >
      <form
        data-src="POST /api/cases/create"
        onSubmit={(e) => {
          e.preventDefault();
          if (valid && !isLoading) submit();
        }}
      >
        <label className="field-l" htmlFor="nc-title" style={{ marginTop: 0 }}>Title (optional)</label>
        <input id="nc-title" className="field-in" value={f.title} onChange={set('title')} placeholder="e.g. SHJ fog 22 Nov early morning" />
        <div className="form-grid">
          <div>
            <label className="field-l" htmlFor="nc-scn">Scenario</label>
            <select id="nc-scn" className="field-in" value={f.scenario_id} onChange={set('scenario_id')}>
              {(scenarios.data ?? []).map((s) => (
                <option key={s.scenario_id} value={s.scenario_id}>
                  {s.name} ({s.kind})
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="field-l" htmlFor="nc-hub">Airport (arrivals)</label>
            <input id="nc-hub" className="field-in" value={f.hub_iata} maxLength={3} onChange={set('hub_iata')} />
          </div>
          <div>
            <label className="field-l" htmlFor="nc-from">From (Dubai time)</label>
            <input id="nc-from" className="field-in" type="datetime-local" value={f.from} onChange={set('from')} />
          </div>
          <div>
            <label className="field-l" htmlFor="nc-to">To (Dubai time)</label>
            <input id="nc-to" className="field-in" type="datetime-local" value={f.to} onChange={set('to')} />
          </div>
        </div>
        <label className="check-row" htmlFor="nc-fog">
          <input id="nc-fog" type="checkbox" checked={f.simulate_fog} onChange={set('simulate_fog')} />
          <span>Simulate fog at this airport (runs in its own what-if copy, so live data is not touched and the case is labelled SIMULATED)</span>
        </label>
        {f.simulate_fog && (
          <>
            <label className="field-l" htmlFor="nc-reopen">Fog clears after (minutes)</label>
            <input id="nc-reopen" className="field-in" style={{ maxWidth: 200 }} type="number" min={0} value={f.reopen_after_min} onChange={set('reopen_after_min')} />
          </>
        )}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}
