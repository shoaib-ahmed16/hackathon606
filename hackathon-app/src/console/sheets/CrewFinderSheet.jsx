import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useAddRecordMutation, useGetStandbyQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { fmtDur, fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { ms } from '../lib';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';

const T = (iso) => (iso ? fmtZL(ms(iso)) : '-');

// Who can replace a crew member of this flight's duty without breaking legality or the roster.
// The DB needs an APPROVED CREW_REPLACE decision before a swap runs: this only proposes it.
export default function CrewFinderSheet({ d, f, onClose }) {
  const dispatch = useAppDispatch();
  const [add, { isLoading }] = useAddRecordMutation();
  const duty = useMemo(
    () => [...d.crew.filter((c) => c.duty_id === f.duty_id)].sort((a, b) => (a.margin_min ?? 1e9) - (b.margin_min ?? 1e9)),
    [d.crew, f.duty_id],
  );
  const [outId, setOutId] = useState(null);
  const [picked, setPicked] = useState(null);
  const [note, setNote] = useState('');
  const row = duty.find((c) => c.crew_id === outId) ?? duty[0];

  const { data = [], isFetching } = useGetStandbyQuery(
    { scenario_id: d.ctx.scenario_id, duty_id: f.duty_id, position: row?.position_code, station: 'SHJ', from_leg: 1 },
    { skip: !row },
  );
  const cand = data.find((c) => c.crew_id === picked);

  const propose = async () => {
    if (!cand || !row) return;
    try {
      await add({
        table: 'decision',
        body: {
          scenario_id: d.ctx.scenario_id,
          case_id: d.ctx.case_id,
          flight_id: f.flight_id,
          decision_type: 'CREW_REPLACE',
          rationale: `Replace ${row.position_code} ${row.full_name} with ${cand.full_name} (${cand.pattern_name}): ${cand.verdict}${note.trim() ? `. ${note.trim()}` : ''}`,
          decided_by: d.actor.user_id,
          decided_role: d.actor.role_code,
          details: {
            duty_id: f.duty_id,
            out_crew_id: row.crew_id,
            in_crew_id: cand.crew_id,
            sign_in_utc: cand.new_sign_in_utc,
            report_station: 'SHJ',
            from_leg_seq: 1,
            standby_id: cand.standby_id,
            positioning_min: cand.positioning_min,
          },
        },
      }).unwrap();
      toast.success('Replacement proposed. Approve and execute it in the flight panel.');
      onClose();
      dispatch(selectFlight(f.flight_id));
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <Sheet
      title={`Replacement crew for ${f.flight_no}`}
      sub="Standby crew legal for the remaining sectors, LVP-qualified and roster-safe."
      onClose={onClose}
      wide
      footer={
        <>
          <button type="button" className="btn ghost" onClick={onClose}>Close</button>
          <button type="button" className="btn primary" disabled={!cand || isLoading} onClick={propose}>
            Propose replacement
          </button>
        </>
      }
    >
      <div data-src="standby_candidates()">
        {duty.length > 1 && (
          <>
            <label className="field-l" htmlFor="cf-out" style={{ marginTop: 0 }}>Replace</label>
            <select
              id="cf-out"
              className="field-in"
              value={row?.crew_id ?? ''}
              onChange={(e) => {
                setOutId(Number(e.target.value));
                setPicked(null);
              }}
            >
              {duty.map((c) => (
                <option key={c.crew_id} value={c.crew_id}>
                  {c.position_code} {c.full_name} ({c.margin_min == null ? 'verify' : `${c.margin_min} min margin`})
                </option>
              ))}
            </select>
          </>
        )}
        {row && (
          <p className="k" style={{ margin: '8px 0 12px' }}>
            Replacing {row.position_code} {row.full_name} on {row.duty_legs}
          </p>
        )}
        {isFetching && <p className="k" aria-live="polite">Checking rest, roster conflicts, LVP and positioning…</p>}
        {data.map((c) => {
          const ok = c.verdict === 'CANDIDATE';
          return (
            <div key={c.crew_id} className={`cand ${ok ? '' : 'bad'} ${picked === c.crew_id ? 'picked' : ''}`}>
              <div>
                <b>{row?.position_code} {c.full_name}</b>{' '}
                <span className="k">
                  {c.pattern_name} · {c.positioning_min} min positioning · sign-in {T(c.new_sign_in_utc)} · FDP margin {fmtDur(c.margin_min)}
                </span>
                <div style={{ fontSize: 13, marginTop: 2 }}>
                  <Pill tone={c.lvp_qualified ? 'legal' : 'exceeded'}>{c.lvp_qualified ? 'LVP ✓' : 'Not LVP'}</Pill>
                </div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <Pill tone={ok ? 'legal' : c.roster_conflict ? 'risk' : 'exceeded'}>{String(c.verdict).replaceAll('_', ' ')}</Pill>
                {ok && (
                  <div style={{ marginTop: 6 }}>
                    <button
                      type="button"
                      className="btn"
                      aria-pressed={picked === c.crew_id}
                      onClick={() => setPicked(picked === c.crew_id ? null : c.crew_id)}
                    >
                      {picked === c.crew_id ? 'Selected ✓' : 'Select'}
                    </button>
                  </div>
                )}
              </div>
            </div>
          );
        })}
        {!isFetching && data.length === 0 && <p className="k">No standby candidates for this position.</p>}
        <label className="field-l" htmlFor="cf-note">Note for the approvers (optional)</label>
        <textarea id="cf-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. crew will time out before an arrival slot" />
      </div>
    </Sheet>
  );
}
