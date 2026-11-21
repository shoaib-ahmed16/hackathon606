import { useState } from 'react';
import {
  Button,
  Checkbox,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  MenuItem,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useCreateCaseMutation, useGetScenariosQuery } from '@/features/ops/opsApi';
import { selectCase } from '@/features/ops/opsSlice';
import { scenarioNowMs } from '@/features/ops/helpers';
import { getErrorMessage } from '@/utils/getErrorMessage';

const dubaiDay = (ms) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dubai' }).format(ms); // YYYY-MM-DD
const toUtc = (local) => new Date(`${local}:00+04:00`).toISOString(); // inputs are Dubai time (UTC+4, no DST)

// New disruption case: pick scenario, airport and a time window; the watch list is filled with the real flights.
export default function CreateCaseDialog({ kase, onClose }) {
  const dispatch = useAppDispatch();
  const scenarios = useGetScenariosQuery();
  const [create, { isLoading }] = useCreateCaseMutation();
  const day = dubaiDay(scenarioNowMs(kase));
  const [f, setF] = useState({
    scenario_id: kase?.scenario_id ?? 1,
    title: '',
    hub_iata: 'SHJ',
    from: `${day}T00:00`,
    to: `${day}T23:59`,
    simulate_fog: false,
    reopen_after_min: 120,
  });
  const set = (k) => (e) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  const submit = async () => {
    try {
      const res = await create({
        scenario_id: f.scenario_id,
        hub_iata: f.hub_iata.toUpperCase(),
        from_utc: toUtc(f.from),
        to_utc: toUtc(f.to),
        title: f.title.trim() || `${f.hub_iata.toUpperCase()} arrivals ${f.from.slice(0, 10)}`,
        simulate_fog: f.simulate_fog,
        reopen_after_min: Number(f.reopen_after_min),
        cause: f.simulate_fog ? 'FOG' : 'OPS',
      }).unwrap();
      dispatch(selectCase(res));
      toast.success(
        `Case created with ${res.flights} flights${res.recommended ? `, ${res.recommended} recommendations` : ''}`,
      );
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <Dialog open onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle>Create case</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 1 }}>
          <TextField
            label="Title (optional)"
            value={f.title}
            onChange={set('title')}
            placeholder="e.g. SHJ fog 22 Nov early morning"
          />
          <Stack direction="row" spacing={2}>
            <TextField select label="Scenario" value={f.scenario_id} onChange={set('scenario_id')}>
              {(scenarios.data ?? []).map((s) => (
                <MenuItem key={s.scenario_id} value={s.scenario_id}>
                  {s.name} ({s.kind})
                </MenuItem>
              ))}
            </TextField>
            <TextField
              label="Airport (arrivals)"
              value={f.hub_iata}
              onChange={set('hub_iata')}
              sx={{ maxWidth: 150 }}
            />
          </Stack>
          <Stack direction="row" spacing={2}>
            <TextField
              label="From (Dubai time)"
              type="datetime-local"
              value={f.from}
              onChange={set('from')}
              slotProps={{ inputLabel: { shrink: true } }}
            />
            <TextField
              label="To (Dubai time)"
              type="datetime-local"
              value={f.to}
              onChange={set('to')}
              slotProps={{ inputLabel: { shrink: true } }}
            />
          </Stack>
          <FormControlLabel
            control={<Checkbox checked={f.simulate_fog} onChange={set('simulate_fog')} />}
            label="Simulate fog at this airport (runs in its own what-if copy so LIVE data is not touched)"
          />
          {f.simulate_fog && (
            <TextField
              label="Fog clears after (minutes)"
              type="number"
              value={f.reopen_after_min}
              onChange={set('reopen_after_min')}
              sx={{ maxWidth: 240 }}
            />
          )}
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            The watch list is every scheduled flight arriving at the airport in the window, with its
            real crew and legality. Simulated fog is labelled SIMULATED and lives in a separate
            what-if scenario.
          </Typography>
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Cancel</Button>
        <Button variant="contained" disabled={isLoading} onClick={submit}>
          Create case
        </Button>
      </DialogActions>
    </Dialog>
  );
}
