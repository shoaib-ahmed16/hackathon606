import { useMemo, useState } from 'react';
import { Box, Button, Chip, MenuItem, Paper, Stack, TextField, Typography } from '@mui/material';
import toast from 'react-hot-toast';
import { useAddRecordMutation, useUpdateDiversionMutation } from '@/features/ops/opsApi';
import { iso, ms, stampMs } from '@/features/ops/helpers';
import { fmtZ } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import Countdown from '../Countdown';

// Each big button is one station update on the diversion record (audited) plus a timeline comment for everyone.
const BUTTONS = (now) => [
  {
    k: 'Landed',
    done: (x) => x.landed_alt_utc != null,
    body: () => ({ landed_alt_utc: now, status: 'ON_GROUND_ALT' }),
  },
  {
    k: 'On blocks',
    done: (x) => x.on_blocks_alt_utc != null,
    body: () => ({ on_blocks_alt_utc: now, status: 'ON_GROUND_ALT', waiting_for: 'HANDLING' }),
  },
  {
    k: 'Refuel done',
    done: (x) => x.refuel_status === 'DONE',
    body: (x) => ({ refuel_status: x.refuel_status === 'DONE' ? 'PENDING' : 'DONE' }),
  },
  {
    k: 'Passengers on board',
    done: (x) => x.pax_onboard === true,
    body: (x) => ({ pax_onboard: !x.pax_onboard }),
  },
  {
    k: 'Passengers disembarked',
    done: (x) => x.pax_onboard === false,
    body: (x) => ({ pax_onboard: x.pax_onboard === false }),
  },
  {
    k: 'Crew arrived',
    done: (x) => x.waiting_for === 'CREW_REST' || x.waiting_for === 'ARRIVAL_SLOT',
    body: () => ({ waiting_for: 'ARRIVAL_SLOT' }),
  },
  {
    k: 'Ready to depart',
    done: (x) => x.status === 'READY',
    body: (x) => ({
      status: x.status === 'READY' ? 'ON_GROUND_ALT' : 'READY',
      waiting_for: 'ARRIVAL_SLOT',
    }),
  },
];

// Station lens: tablet-style, big targets, only what a ground team at the alternate has to report.
export default function StationLens({ d }) {
  const [patch] = useUpdateDiversionMutation();
  const [add] = useAddRecordMutation();
  const stations = useMemo(
    () => [...new Set(d.diversions.map((x) => x.alternate_iata))].sort(),
    [d.diversions],
  );
  const [st, setSt] = useState(null);
  const station = st ?? stations[0];
  const here = d.diversions.filter(
    (x) => x.alternate_iata === station && !['DEPARTED', 'CLOSED', 'CANCELLED'].includes(x.status),
  );
  const dlBy = Object.fromEntries(d.deadlines.map((x) => [x.flight_id, x]));
  const flightOf = (x) => d.flights.find((f) => f.flight_id === x.original_flight_id);

  const tap = async (x, b) => {
    const f = flightOf(x);
    try {
      await patch({ id: x.diversion_id, body: b.body(x) }).unwrap();
      await add({
        table: 'case_comment',
        body: {
          case_id: d.ctx.case_id,
          flight_id: x.original_flight_id,
          author_id: d.actor.user_id,
          author_role: d.actor.role_code,
          body: `${station} station: ${b.k}`,
        },
      }).unwrap();
      toast.success(`${f?.flight_no ?? ''}: "${b.k}" sent to OCC`);
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const note = async (x) => {
    const text = window.prompt(`Note for OCC about ${flightOf(x)?.flight_no}`);
    if (!text?.trim()) return;
    try {
      await add({
        table: 'case_comment',
        body: {
          case_id: d.ctx.case_id,
          flight_id: x.original_flight_id,
          author_id: d.actor.user_id,
          author_role: d.actor.role_code,
          body: `${station} station: ${text.trim()}`,
        },
      }).unwrap();
      toast.success('Note sent to OCC');
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  if (!stations.length)
    return (
      <Typography variant="body2" sx={{ color: 'text.secondary' }}>
        No aircraft are diverted on this case, so no station has anything to report.
      </Typography>
    );
  return (
    <Stack
      spacing={2}
      data-src="diversion UPDATE + case_comment INSERT (station updates)"
      sx={{ maxWidth: 1000 }}
    >
      <Stack direction="row" spacing={2} sx={{ alignItems: 'center' }}>
        <Typography variant="h5">
          {station} station - {here.length} diverted aircraft
        </Typography>
        <TextField
          select
          size="small"
          label="Station"
          value={station}
          onChange={(e) => setSt(e.target.value)}
          sx={{ minWidth: 120 }}
        >
          {stations.map((s) => (
            <MenuItem key={s} value={s}>
              {s}
            </MenuItem>
          ))}
        </TextField>
      </Stack>
      {here.map((x) => {
        const f = flightOf(x);
        const dl = f ? dlBy[f.flight_id] : null;
        const btns = BUTTONS(iso(stampMs(d.kase)));
        return (
          <Paper key={x.diversion_id} sx={{ p: 2 }}>
            <Stack direction="row" spacing={1.5} sx={{ alignItems: 'baseline', flexWrap: 'wrap' }}>
              <Typography variant="h5">{f?.registration ?? 'aircraft'}</Typography>
              <Typography variant="body2">
                {f?.flight_no} {f?.dep_iata} to {f?.planned_arr_iata}, diverted
              </Typography>
              <Chip
                size="small"
                color="warning"
                label={`waiting for ${String(x.waiting_for).replaceAll('_', ' ').toLowerCase()}`}
              />
            </Stack>
            <Box sx={{ my: 1.5, p: 1.25, borderRadius: 2, bgcolor: 'action.hover' }}>
              <Typography variant="body2" sx={{ fontWeight: 600 }}>
                {dl?.deadline_utc ? (
                  <>
                    OCC needs: confirm the aircraft is ready. It must leave by{' '}
                    {fmtZ(ms(dl.deadline_utc))} - <Countdown at={ms(dl.deadline_utc)} />
                  </>
                ) : (
                  'OCC needs: report progress as it happens.'
                )}
              </Typography>
            </Box>
            <Box
              sx={{
                display: 'grid',
                gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))',
                gap: 1.25,
              }}
            >
              {btns.map((b) => {
                const done = b.done(x);
                return (
                  <Button
                    key={b.k}
                    variant={done ? 'contained' : 'outlined'}
                    color={done ? 'success' : 'primary'}
                    sx={{ minHeight: 68, fontSize: 15, fontWeight: 600 }}
                    onClick={() => tap(x, b)}
                  >
                    {done ? '✓ ' : ''}
                    {b.k}
                  </Button>
                );
              })}
              <Button
                variant="outlined"
                color="inherit"
                sx={{ minHeight: 68, fontSize: 15 }}
                onClick={() => note(x)}
              >
                Add a note
              </Button>
            </Box>
          </Paper>
        );
      })}
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        Each tap is sent to OCC immediately with the time and your name, and is recorded in the
        audit trail.
      </Typography>
    </Stack>
  );
}
