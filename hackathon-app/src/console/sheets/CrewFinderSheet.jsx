import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useAddRecordMutation, useGetReplacementOptionsQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { fmtDur, fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { ms } from '../lib';
import { Pill, Sheet } from '../ui/ui';
import '../lenses/lenses.css';

const tone = (ok) => (ok == null ? 'verify' : ok ? 'legal' : 'exceeded');
const POS = { CANDIDATE_BASE_IS_DESTINATION: 'based at destination', DESTINATION_IS_HUB: 'at hub', ROAD_FROM_HUB: 'road from hub' };
const posText = (c, dest) => (c.positioning_min == null ? `positioning to ${dest} not configured` : `${c.positioning_min} min positioning (${POS[c.positioning_basis] ?? c.positioning_basis})`);
const SRC = { SIGNED_IN: 'signed in that day', STANDBY: 'standby', NO_SIGN_IN: 'no sign-in that day (counted as standby)' };
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

  // Where this flight lands now: the diversion airport when diverted, else the planned arrival.
  const destination = f.diverted_to ?? f.planned_arr_iata ?? f.arr_iata;
  const { data = [], isFetching } = useGetReplacementOptionsQuery(
    { scenario_id: d.ctx.scenario_id, duty_id: f.duty_id, position: row?.position_code, destination, from_leg: 1 },
    { skip: !row || !destination },
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
            report_station: cand.report_station ?? destination,
            from_leg_seq: cand.from_leg_seq ?? 1,
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
      sub={`Standby crew for the flight's destination (${destination ?? '?'}): legal for the current legs (N) and one more sector (N+1), LVP-qualified and roster-safe.`}
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
      <div data-src="crew_replacement_options()">
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
        {isFetching && <p className="k" aria-live="polite">Checking rest, roster conflicts, LVP, positioning to {destination} and the extra sector…</p>}
        {data.slice(0, 50).map((c) => {
          const ok = c.verdict === 'CANDIDATE';
          return (
            <div key={c.crew_id} className={`cand ${ok ? '' : 'bad'} ${picked === c.crew_id ? 'picked' : ''}`}>
              <div>
                <b>{row?.position_code} {c.full_name}</b>{' '}
                <span className="k">
                  {c.pattern_name} · base {c.base_iata ?? '-'} · {posText(c, destination)} · sign-in {T(c.new_sign_in_utc)}
                </span>
                <div style={{ fontSize: 13, marginTop: 2 }}>
                  <Pill tone={c.lvp_qualified ? 'legal' : 'exceeded'}>{c.lvp_qualified ? 'LVP ✓' : 'Not LVP'}</Pill>{' '}
                  <Pill tone={tone(c.ok_n)}>N={c.legs_n}: {c.margin_n_min == null ? 'verify' : `${fmtDur(c.margin_n_min)} margin`}</Pill>{' '}
                  <Pill tone={tone(c.ok_n1)}>N+1={c.legs_n1}: {c.margin_n1_min == null ? 'verify' : `${fmtDur(c.margin_n1_min)} margin`}</Pill>
                </div>
                <div className="k" style={{ marginTop: 2 }}>
                  <b>Legality {fmtDur(c.legality_min)}</b> (flight needs {fmtDur(c.need_min)}) · {SRC[c.pool_source] ?? c.pool_source}
                </div>
                <div className="k" style={{ marginTop: 2 }}>
                  Week: {fmtDur(c.week_duty_min)} duty, {fmtDur(c.week_flying_min)} flying (pool avg {fmtDur(c.pool_avg_duty_min)} duty)
                  {c.below_avg ? ' · at or below average' : ' · above average'}
                </div>
              </div>
              <div style={{ textAlign: 'right' }}>
                {c.is_suggested && <Pill tone="legal">Suggested</Pill>}{' '}
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
        <p className="k">
          N = remaining legs of this duty, N+1 = one more sector (its own flying time is not included). Weekly workload is the roster in the
          last 7 days (the loaded roster may cover less); it ranks crew and is not a legal limit.
        </p>
        {data.length > 50 && <p className="k">Showing the best 50 of {data.length}, most legality hours first.</p>}
        {!isFetching && data.length === 0 && <p className="k">No standby candidates for this position.</p>}
        <label className="field-l" htmlFor="cf-note">Note for the approvers (optional)</label>
        <textarea id="cf-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. crew will time out before an arrival slot" />
      </div>
    </Sheet>
  );
}
