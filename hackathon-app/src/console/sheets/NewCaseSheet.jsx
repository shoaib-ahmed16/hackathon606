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
const dubaiLocal = (t) => new Date(t + 4 * 3600e3).toISOString().slice(0, 16); // 'YYYY-MM-DDTHH:mm' in Dubai time
const nowText = (t) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Dubai', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(t);

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
  // A LIVE case starts NOW (current local time): nobody types a start. Only the end is asked. Replay and what-if cases are
  // about another moment, so they keep a start and an end.
  const live = (scenarios.data ?? []).find((s) => s.scenario_id === Number(f.scenario_id))?.kind === 'LIVE';
  const [opened] = useState(() => Date.now());
  const [liveEnd, setLiveEnd] = useState(() => dubaiLocal(Date.now() + 12 * 3600e3));
  const nowLocal = dubaiLocal(opened);
  const from = live ? nowLocal : f.from;
  const to = live ? liveEnd : f.to;
  const valid = f.hub_iata.trim().length === 3 && from && to && from < to;

  const submit = async () => {
    try {
      const hub = f.hub_iata.trim().toUpperCase();
      const res = await create({
        scenario_id: Number(f.scenario_id),
        hub_iata: hub,
        from_utc: live ? new Date().toISOString() : toUtc(f.from),
        to_utc: toUtc(to),
        title: f.title.trim() || `${hub} ${live ? 'live' : 'arrivals'} ${from.slice(0, 10)}`,
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
      sub={live ? 'A live case starts now. Choose when it ends; the watch list is every flight arriving at the airport until then, with its real crew and legality.' : 'The watch list is every scheduled flight arriving at the airport in the window, with its real crew and legality.'}
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
          {live ? (
            <div>
              <label className="field-l" htmlFor="nc-now">Starts</label>
              <input id="nc-now" className="field-in" value={`Now · ${nowText(opened)} (Dubai time)`} readOnly />
            </div>
          ) : (
            <div>
              <label className="field-l" htmlFor="nc-from">From (Dubai time)</label>
              <input id="nc-from" className="field-in" type="datetime-local" value={f.from} onChange={set('from')} />
            </div>
          )}
          <div>
            <label className="field-l" htmlFor="nc-to">{live ? 'Ends (Dubai time)' : 'To (Dubai time)'}</label>
            <input
              id="nc-to"
              className="field-in"
              type="datetime-local"
              min={live ? nowLocal : undefined}
              value={live ? liveEnd : f.to}
              onChange={live ? (e) => setLiveEnd(e.target.value) : set('to')}
            />
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
