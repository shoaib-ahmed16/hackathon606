import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useAddRecordMutation, useUpdateDiversionMutation } from '@/features/ops/opsApi';
import { iso, stampMs } from '@/features/ops/helpers';
import { flightDay } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Cd, Empty, Pill, Sheet } from '../ui/ui';
import { fmtZ, human, ms } from '../lib';
import './lenses.css';

// Each big button is one station update on the diversion record (audited) plus a timeline comment for everyone.
const BUTTONS = (now) => [
  { k: 'Landed', done: (x) => x.landed_alt_utc != null, body: () => ({ landed_alt_utc: now, status: 'ON_GROUND_ALT' }) },
  { k: 'On blocks', done: (x) => x.on_blocks_alt_utc != null, body: () => ({ on_blocks_alt_utc: now, status: 'ON_GROUND_ALT', waiting_for: 'HANDLING' }) },
  { k: 'Refuel done', done: (x) => x.refuel_status === 'DONE', body: (x) => ({ refuel_status: x.refuel_status === 'DONE' ? 'PENDING' : 'DONE' }) },
  { k: 'Passengers on board', done: (x) => x.pax_onboard === true, body: (x) => ({ pax_onboard: !x.pax_onboard }) },
  { k: 'Passengers disembarked', done: (x) => x.pax_onboard === false, body: (x) => ({ pax_onboard: x.pax_onboard === false }) },
  // paperwork for the return leg: Dispatch files the flight plan, the station makes the load sheet ready; "Ready to depart" needs both
  { k: 'Flight plan filed', who: ['DISPATCH', 'OCC', 'ADMIN'], hint: 'Dispatch files the flight plan', done: (x) => x.flight_plan_filed_at != null, body: (x) => ({ flight_plan_filed: x.flight_plan_filed_at == null }) },
  { k: 'Load sheet ready', who: ['STATION', 'OCC', 'ADMIN'], hint: 'The station (load control) makes the load sheet ready', done: (x) => x.load_sheet_ready_at != null, body: (x) => ({ load_sheet_ready: x.load_sheet_ready_at == null }) },
  { k: 'Crew arrived', done: (x) => x.waiting_for === 'CREW_REST' || x.waiting_for === 'ARRIVAL_SLOT', body: () => ({ waiting_for: 'ARRIVAL_SLOT' }) },
  {
    k: 'Ready to depart',
    needs: (x) => (x.flight_plan_filed_at == null || x.load_sheet_ready_at == null) && x.status !== 'READY',
    done: (x) => x.status === 'READY',
    body: (x) => ({ status: x.status === 'READY' ? 'ON_GROUND_ALT' : 'READY', waiting_for: 'ARRIVAL_SLOT' }),
  },
];

function NoteSheet({ flightNo, onSend, onClose }) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async () => {
    setBusy(true);
    const ok = await onSend(text.trim());
    setBusy(false);
    if (ok) onClose();
  };
  return (
    <Sheet
      title={`Message to OCC about ${flightNo ?? 'this flight'}`}
      sub="OCC gets an alert in the bell, and so does everyone watching the flight, with the time and your name."
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn primary" disabled={!text.trim() || busy} onClick={send}>Send to OCC</button>
        </>
      }
    >
      <label className="field-l" htmlFor="st-note" style={{ marginTop: 0 }}>Message</label>
      <textarea id="st-note" value={text} onChange={(e) => setText(e.target.value)} />
    </Sheet>
  );
}

// Station tablet view: big targets, only what a ground team at the alternate has to report.
export default function StationView({ d }) {
  const [patch] = useUpdateDiversionMutation();
  const [add] = useAddRecordMutation();
  const [st, setSt] = useState(null);
  const [busy, setBusy] = useState(null);
  const [noteFor, setNoteFor] = useState(null);

  const stations = useMemo(() => [...new Set(d.diversions.map((x) => x.alternate_iata))].sort(), [d.diversions]);
  const station = stations.includes(st) ? st : stations[0];
  const here = d.diversions.filter((x) => x.alternate_iata === station && !['DEPARTED', 'CLOSED', 'CANCELLED'].includes(x.status));
  const dlBy = useMemo(() => Object.fromEntries(d.deadlines.map((x) => [x.flight_id, x])), [d.deadlines]);
  const flightOf = (x) => d.flights.find((f) => f.flight_id === x.original_flight_id);

  const comment = (x, body) =>
    add({
      table: 'case_comment',
      body: {
        case_id: d.ctx.case_id,
        flight_id: x.original_flight_id,
        author_id: d.actor.user_id,
        author_role: d.actor.role_code,
        body: `${station} station: ${body}`,
      },
    }).unwrap();

  const tap = async (x, b) => {
    setBusy(`${x.diversion_id}:${b.k}`);
    try {
      await patch({ id: x.diversion_id, body: b.body(x) }).unwrap();
      await comment(x, b.k);
      toast.success(`${flightOf(x)?.flight_no ?? ''}: “${b.k}” sent to OCC`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    } finally {
      setBusy(null);
    }
  };
  const sendNote = async (x, text) => {
    try {
      await comment(x, text);
      toast.success('Message sent to OCC');
      return true;
    } catch (e) {
      toast.error(getErrorMessage(e));
      return false;
    }
  };

  if (!stations.length) return <div className="station"><Empty>No aircraft are diverted on this case, so no station has anything to report.</Empty></div>;
  const stamp = iso(stampMs(d.kase));
  const btns = BUTTONS(stamp);

  return (
    <div className="station" data-src="UPDATE diversion · case_comment INSERT (station updates)">
      <div className="st-bar">
        <h2>
          {station} station · {here.length} diverted aircraft
        </h2>
        {stations.length > 1 && (
          <>
            <label className="sr" htmlFor="st-pick">Station</label>
            <select id="st-pick" className="field-in" style={{ width: 'auto' }} value={station} onChange={(e) => setSt(e.target.value)}>
              {stations.map((s) => (
                <option key={s} value={s}>{s}</option>
              ))}
            </select>
          </>
        )}
      </div>
      {here.length === 0 && <Empty>No aircraft waiting at {station}.</Empty>}
      {here.map((x) => {
        const f = flightOf(x);
        const dl = f ? dlBy[f.flight_id] : null;
        const dlAt = ms(dl?.deadline_utc);
        return (
          <div className="st-card" key={x.diversion_id}>
            <div className="st-top">
              <h3>{f?.registration ?? 'Aircraft'}</h3>
              <span>
                {f?.flight_no} ({flightDay(f)}) {f?.dep_iata}→{f?.planned_arr_iata}, diverted
              </span>
              {x.waiting_for && <Pill tone="disc">Waiting for {human(x.waiting_for)}</Pill>}
            </div>
            <div className="need">
              {dlAt != null ? (
                <>
                  OCC needs: confirm the aircraft is ready. It must leave by {fmtZ(dlAt)} · <Cd at={dlAt} />
                </>
              ) : (
                'OCC needs: report progress as it happens.'
              )}
            </div>
            <div className="big-btns">
              {btns.map((b) => {
                const done = b.done(x);
                const notMine = b.who && !b.who.includes(d.actor.role_code);
                const blocked = b.needs?.(x);
                return (
                  <button
                    key={b.k}
                    type="button"
                    className={`big ${done ? 'done' : ''}`}
                    aria-pressed={done}
                    title={blocked ? 'Needs the flight plan filed and the load sheet ready' : notMine ? b.hint : undefined}
                    disabled={busy === `${x.diversion_id}:${b.k}` || notMine || blocked}
                    onClick={() => tap(x, b)}
                  >
                    {done ? '✓ ' : ''}
                    {b.k}
                  </button>
                );
              })}
              <button type="button" className="big" onClick={() => setNoteFor(x)}>
                Ask or answer OCC
              </button>
            </div>
          </div>
        );
      })}
      <p className="k">Each tap reaches OCC and everyone watching the flight, with the time and your name, and is recorded in the audit trail.</p>
      {noteFor && <NoteSheet flightNo={flightOf(noteFor)?.flight_no} onSend={(t) => sendNote(noteFor, t)} onClose={() => setNoteFor(null)} />}
    </div>
  );
}
