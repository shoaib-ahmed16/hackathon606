import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useWhatIfMutation } from '@/features/ops/opsApi';
import { selectCase } from '@/features/ops/opsSlice';
import { fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';

// What if the airport stays closed longer (or closes again)? Runs the real engine in a separate WHATIF copy of the
// scenario and compares its advice with today's. Nothing live is touched.
export default function WhatIfSheet({ d, onClose }) {
  const dispatch = useAppDispatch();
  const [run, { isLoading, data }] = useWhatIfMutation();
  const [shift, setShift] = useState(60);
  const hubCode = d.kase?.hub_iata;
  const hub = d.airport.find((a) => a.iata === hubCode);

  const go = async () => {
    try {
      const r = await run({ ...d.ctx, reopen_shift_min: shift }).unwrap();
      toast.success(`What-if case #${r.case_id} created. It is in the case list as a what-if; use “Open the what-if case” to look at it.`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const open = () => {
    dispatch(selectCase({ scenario_id: data.scenario_id, case_id: data.case_id }));
    onClose();
  };

  return (
    <Sheet
      wide
      title={`What if ${hubCode ?? 'the airport'} stays closed longer?`}
      sub="Runs as a separate what-if scenario. Live operations and the current case are not changed."
      onClose={onClose}
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Close</button>
          {data && <button type="button" className="btn" onClick={open}>Open this scenario</button>}
          <button type="button" className="btn primary" disabled={isLoading} onClick={go}>
            {isLoading ? 'Running the engine…' : data ? 'Run again' : 'Run what-if'}
          </button>
        </>
      }
    >
      <div data-src="clone_scenario() + recommendation engine">
        <label className="field-l" htmlFor="wi-shift" style={{ marginTop: 0 }}>
          {hub?.expected_reopen_utc ? 'Move the reopening forecast by' : `${hubCode} is open: close it again for`}{' '}
          <b>
            {shift > 0 ? '+' : ''}
            {shift} min
          </b>
        </label>
        <input
          id="wi-shift"
          className="range"
          type="range"
          min={-60}
          max={240}
          step={15}
          value={shift}
          onChange={(e) => setShift(Number(e.target.value))}
          aria-valuetext={`${shift} minutes`}
        />
        {data && (
          <div style={{ marginTop: 16 }} aria-live="polite">
            <div className="replay-banner" style={{ display: 'block', borderRadius: 6, marginBottom: 10 }}>
              What-if scenario · reopening {fmtZL(Date.parse(data.new_reopen_utc))}
            </div>
            <p style={{ margin: '0 0 8px' }}>
              Advice changes for <b>{data.changed}</b> of {data.rows.length} flights
            </p>
            <div className="sheet-scroll">
              <table className="cmp">
                <thead>
                  <tr>
                    <th>Flight</th>
                    <th>Now</th>
                    <th>What-if</th>
                  </tr>
                </thead>
                <tbody>
                  {data.rows.map((r) => (
                    <tr key={r.flight_no} className={r.changed ? 'diff' : ''}>
                      <td><b>{r.flight_no}</b></td>
                      <td>{r.current}</td>
                      <td>
                        {r.changed && <Pill tone="ai">changes</Pill>} {r.what_if}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </Sheet>
  );
}
