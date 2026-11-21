import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useApprovePlanMutation, useBuildRecoveryMutation, useMoveSlotMutation } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { iso } from '@/features/ops/helpers';
import { flightDay } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { Cd, Empty } from '../ui/ui';
import { fmtTime, fmtZ, human, MIN, ms } from '../lib';
import './lenses.css';

const SLOTS = 12;

// Recovery: arrival slots after the hub reopens. Drag a flight to another slot (or pick it and click a slot);
// the server refuses moves that are earlier than the flight can arrive or into a taken slot.
export default function RecoveryView({ d }) {
  const dispatch = useAppDispatch();
  const [build, { isLoading: building }] = useBuildRecoveryMutation();
  const [approve, { isLoading: approving }] = useApprovePlanMutation();
  const [move] = useMoveSlotMutation();
  const [drag, setDrag] = useState(null);
  const plan = d.plan;
  const head = plan[0];

  const view = useMemo(() => {
    if (!head) return null;
    const open = ms(head.reopening_utc);
    const step = (60 / (head.capacity_per_hr || 12)) * MIN;
    const slots = Array.from({ length: SLOTS }, (_, i) => open + i * step);
    const placed = new Map();
    const parked = [];
    for (const it of plan) {
      const t = ms(it.proposed_slot_utc);
      const idx = t != null ? Math.round((t - open) / step) : -1;
      if (!it.is_feasible || idx < 0 || idx >= SLOTS) parked.push(it);
      else placed.set(slots[idx], [...(placed.get(slots[idx]) ?? []), it]);
    }
    return { open, slots, placed, parked };
  }, [plan, head]);
  const flightBy = useMemo(() => new Map(d.flights.map((f) => [f.flight_id, f])), [d.flights]);

  const run = async (fn, ok) => {
    try {
      await fn().unwrap();
      toast.success(ok);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const drop = (slot) => {
    if (!drag) return;
    const it = drag;
    setDrag(null);
    run(() => move({ planId: it.plan_id, flightId: it.flight_id, body: { proposed_slot_utc: iso(slot) } }), `${it.flight_no} moved to ${fmtZ(slot)}`);
  };
  const toneOf = (it) => {
    const m = flightBy.get(it.flight_id)?.crew_margin_min;
    return m == null ? 'verify' : m < 60 ? 'risk' : 'legal';
  };

  if (!head) {
    return (
      <div className="recovery" data-src="build_recovery_plan()">
        <Empty>No recovery plan for this case yet.</Empty>
        <button type="button" className="btn primary" disabled={building} onClick={() => run(() => build({ ...d.ctx, window_min: 60 }), 'Recovery plan built')}>
          {building ? 'Building…' : 'Build recovery plan'}
        </button>
      </div>
    );
  }
  const inWindow = plan.filter((p) => p.within_window).length;

  return (
    <div className="recovery" data-src="build_recovery_plan() · v_recovery_plan_current">
      <h2 className="lane-h" style={{ marginTop: 4 }}>
        {d.kase?.hub_iata ?? 'Hub'} arrival plan after reopening{' '}
        <span className="k">
          from {fmtZ(view.open)} / {fmtTime(view.open)} SHJ · {head.capacity_per_hr} arrivals per hour · plan {human(head.plan_status)}
        </span>
      </h2>
      <div className="rec-stats">
        <span>Reopens in <b><Cd at={view.open} /></b></span>
        <span>Flights in plan <b>{plan.length}</b></span>
        <span>Inside the window <b>{inWindow} of {plan.length}</b></span>
      </div>
      <p className="k" style={{ margin: '0 0 10px' }}>
        Drag a flight to another slot, or select it and click a slot. Fuel, crew legality and LVP are checked before the move is accepted.
      </p>
      {drag && (
        <div className="pick-bar" role="status">
          <span>
            <b>{drag.flight_no}</b> selected. Click a slot to move it.
          </span>
          <button type="button" className="btn" onClick={() => dispatch(selectFlight(drag.flight_id))}>Open flight</button>
          <button type="button" className="btn ghost" onClick={() => setDrag(null)}>Cancel</button>
        </div>
      )}
      <div className="slots-wrap">
        <div className="slots">
          {view.slots.map((t) => {
            const items = view.placed.get(t) ?? [];
            const armed = Boolean(drag);
            return (
              <div
                key={t}
                className="slot"
                role={armed ? 'button' : undefined}
                tabIndex={armed ? 0 : undefined}
                aria-label={armed ? `Move ${drag.flight_no} to ${fmtZ(t)}` : undefined}
                onDragOver={(e) => {
                  e.preventDefault();
                  e.currentTarget.classList.add('over');
                }}
                onDragLeave={(e) => e.currentTarget.classList.remove('over')}
                onDrop={(e) => {
                  e.preventDefault();
                  e.currentTarget.classList.remove('over');
                  drop(t);
                }}
                onClick={() => armed && drop(t)}
                onKeyDown={(e) => armed && (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), drop(t))}
              >
                <span className="st">
                  {fmtZ(t)} · {fmtTime(t)}
                </span>
                {items.map((it) => (
                  <button
                    type="button"
                    key={it.flight_id}
                    className={`blk blk-btn ${toneOf(it)} ${drag?.flight_id === it.flight_id ? 'picked' : ''}`}
                    draggable
                    aria-pressed={drag?.flight_id === it.flight_id}
                    title={(it.reasons ?? []).join(' · ')}
                    onDragStart={(e) => {
                      setDrag(it);
                      e.dataTransfer.setData('text/plain', String(it.flight_id));
                    }}
                    onClick={(e) => {
                      e.stopPropagation();
                      setDrag(drag?.flight_id === it.flight_id ? null : it);
                    }}
                  >
                    <b>
                      {it.flight_no} {it.dep_iata}
                    </b>
                    {flightDay(flightBy.get(it.flight_id))} · {human(it.current_location)}
                  </button>
                ))}
              </div>
            );
          })}
        </div>
      </div>
      <div className="parking">
        <b>Cannot be sequenced now</b> <span className="k">resolve the reason first</span>
        <div>
          {view.parked.length === 0 && <span className="k">Everything has a slot.</span>}
          {view.parked.map((it) => (
            <button type="button" key={it.flight_id} className="blk" onClick={() => dispatch(selectFlight(it.flight_id))}>
              <b>
                {it.flight_no} {it.dep_iata}
              </b>
              {it.infeasible_reason ?? 'Outside the window'}
            </button>
          ))}
        </div>
      </div>
      <div className="ai-buttons" style={{ marginTop: 14 }}>
        {head.plan_status === 'PROPOSED' && (
          <button
            type="button"
            className="btn primary"
            disabled={approving}
            onClick={() => run(() => approve({ planId: head.plan_id }), 'Recovery plan approved. Stations and Dispatch can act on it.')}
          >
            Approve plan
          </button>
        )}
        <button type="button" className="btn" disabled={building} onClick={() => run(() => build({ ...d.ctx, window_min: 60 }), 'Engine re-sequenced the plan')}>
          {building ? 'Re-sequencing…' : 'Ask the engine to re-sequence'}
        </button>
      </div>
    </div>
  );
}
