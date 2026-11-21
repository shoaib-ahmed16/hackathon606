import { useMemo, useState } from 'react';
import { Alert, Box, Button, Chip, Paper, Stack, Typography } from '@mui/material';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import {
  useApprovePlanMutation,
  useBuildRecoveryMutation,
  useMoveSlotMutation,
} from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { iso, ms } from '@/features/ops/helpers';
import { fmtTime, fmtZ, MIN } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import Countdown from '../Countdown';
import StatCard from '@/components/StatCard';

const SLOTS = 12;

// Recovery lens: arrival slots after the hub reopens. Drag a flight to another slot; the server refuses moves that
// are earlier than the flight can arrive or into a taken slot (the plan itself came from build_recovery_plan()).
export default function RecoveryLens({ d }) {
  const dispatch = useAppDispatch();
  const [build, { isLoading: building }] = useBuildRecoveryMutation();
  const [approve] = useApprovePlanMutation();
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
    run(
      () =>
        move({
          planId: drag.plan_id,
          flightId: drag.flight_id,
          body: { proposed_slot_utc: iso(slot) },
        }),
      `${drag.flight_no} moved to ${fmtZ(slot)}`,
    );
    setDrag(null);
  };

  if (!head) {
    return (
      <Stack spacing={2}>
        <Alert severity="info">No recovery plan for this case yet.</Alert>
        <Box>
          <Button
            variant="contained"
            disabled={building}
            onClick={() => run(() => build({ ...d.ctx, window_min: 60 }), 'Recovery plan built')}
          >
            Build recovery plan
          </Button>
        </Box>
      </Stack>
    );
  }
  const inFirstHour = plan.filter((p) => p.within_window).length;
  return (
    <Stack spacing={1.5} data-src="build_recovery_plan() / v_recovery_plan_current">
      <Box
        sx={{
          display: 'grid',
          gap: 1.5,
          gridTemplateColumns: { xs: 'repeat(2, 1fr)', md: 'repeat(4, 1fr)' },
        }}
      >
        <StatCard label="Hub reopens" value={<Countdown at={view.open} big />} />
        <StatCard label="Arrival capacity" value={`${head.capacity_per_hr}/h`} />
        <StatCard label="Flights in plan" value={plan.length} />
        <StatCard label="Inside the window" value={`${inFirstHour} of ${plan.length}`} />
      </Box>
      <Typography variant="body2" sx={{ color: 'text.secondary' }}>
        Plan from {fmtZ(view.open)} ({fmtTime(view.open)} SHJ), status {head.plan_status}. Drag a
        flight to another slot: moves that are impossible are refused with the reason.
      </Typography>
      <Paper sx={{ overflowX: 'auto' }}>
        <Box
          sx={{
            display: 'grid',
            gridTemplateColumns: `repeat(${SLOTS}, minmax(96px, 1fr))`,
            minWidth: 1150,
          }}
        >
          {view.slots.map((t, i) => (
            <Box
              key={t}
              onDragOver={(e) => e.preventDefault()}
              onDrop={() => drop(t)}
              sx={{
                borderLeft: i ? 1 : 0,
                borderColor: 'divider',
                minHeight: 130,
                p: 0.75,
                display: 'flex',
                flexDirection: 'column',
                gap: 0.75,
              }}
            >
              <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                {fmtZ(t)} / {fmtTime(t)}
              </Typography>
              {(view.placed.get(t) ?? []).map((it) => (
                <Box
                  key={it.flight_id}
                  draggable
                  onDragStart={() => setDrag(it)}
                  onClick={() => dispatch(selectFlight(it.flight_id))}
                  title={(it.reasons ?? []).join(' - ')}
                  sx={{
                    p: 0.75,
                    borderRadius: 1.5,
                    border: 1,
                    borderColor: 'divider',
                    borderLeft: 4,
                    borderLeftColor: 'success.main',
                    cursor: 'grab',
                    bgcolor: 'action.hover',
                    fontSize: 12,
                  }}
                >
                  <b>{it.flight_no}</b> <span>{it.dep_iata}</span>
                  <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
                    {it.current_location?.replaceAll('_', ' ').toLowerCase()}
                  </Typography>
                </Box>
              ))}
            </Box>
          ))}
        </Box>
      </Paper>
      <Paper variant="outlined" sx={{ p: 1.5, borderStyle: 'dashed' }}>
        <Typography variant="subtitle2">
          Cannot be sequenced now{' '}
          <Typography component="span" variant="caption" sx={{ color: 'text.secondary' }}>
            resolve the reason first
          </Typography>
        </Typography>
        <Stack direction="row" sx={{ gap: 1, flexWrap: 'wrap', mt: 0.75 }}>
          {view.parked.length === 0 && (
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              Everything has a slot.
            </Typography>
          )}
          {view.parked.map((it) => (
            <Chip
              key={it.flight_id}
              color="error"
              variant="outlined"
              onClick={() => dispatch(selectFlight(it.flight_id))}
              label={`${it.flight_no}: ${it.infeasible_reason ?? 'outside the window'}`}
            />
          ))}
        </Stack>
      </Paper>
      <Stack direction="row" spacing={1}>
        {head.plan_status === 'PROPOSED' && (
          <Button
            variant="contained"
            onClick={() =>
              run(
                () => approve({ planId: head.plan_id }),
                'Recovery plan approved. Stations and Dispatch can act on it.',
              )
            }
          >
            Approve plan
          </Button>
        )}
        <Button
          variant="outlined"
          disabled={building}
          onClick={() =>
            run(() => build({ ...d.ctx, window_min: 60 }), 'Engine re-sequenced the plan')
          }
        >
          Ask the engine to re-sequence
        </Button>
      </Stack>
    </Stack>
  );
}
