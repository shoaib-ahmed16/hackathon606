import { useState } from 'react';
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useSetAirportCapacityMutation } from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';

const whole = (s) => (s === '' ? null : /^\d+$/.test(s) ? Number(s) : NaN);
const bad = (n) => n !== null && (Number.isNaN(n) || n < 0 || n > 200);

// OCC / ADMIN states how many stands and arrivals per hour to assume for an airport. The basis (who or what says so)
// is mandatory and is stored and audited with the figures. Nothing is invented: empty stays empty.
export default function CapacityDialog({ row, onClose }) {
  const [save, { isLoading }] = useSetAirportCapacityMutation();
  const [stands, setStands] = useState(String(row.configured_stands ?? ''));
  const [arrivals, setArrivals] = useState(String(row.configured_arrivals_per_hr ?? ''));
  const [basis, setBasis] = useState(row.configured_basis ?? '');
  const s = whole(stands);
  const a = whole(arrivals);
  const errors = {
    stands: bad(s) ? 'Whole number 0 to 200' : '',
    arrivals: bad(a) ? 'Whole number 0 to 200' : '',
    basis: basis.trim() ? '' : 'Say who or what states this capacity',
  };
  const none = s === null && a === null;
  const invalid = Boolean(errors.stands || errors.arrivals || errors.basis) || none;

  const submit = async () => {
    try {
      await save({
        iata: row.airport,
        body: { stands_assumed: s, arrivals_per_hr_assumed: a, basis: basis.trim() },
      }).unwrap();
      toast.success(`Capacity assumption saved for ${row.airport}`);
      onClose();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  return (
    <Dialog open onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle>
        Set assumed capacity: {row.airport} {row.name ? `(${row.name})` : ''}
      </DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ pt: 1 }}>
          <Alert severity="info">
            An assumption is used when there is no current status entry for the airport. It is
            labelled "Assumed" everywhere and recorded in the audit trail.
            {row.history_peak_arrivals_per_hr != null &&
              ` History has seen up to ${row.history_peak_arrivals_per_hr} arrivals in an hour and ${row.history_peak_ground} aircraft on the ground at once (${row.history_sample_n} hours of history): a minimum, not a limit.`}
          </Alert>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
            <TextField
              label="Assumed stands"
              value={stands}
              onChange={(e) => setStands(e.target.value.trim())}
              error={Boolean(errors.stands)}
              helperText={errors.stands || 'Leave empty if not known'}
              fullWidth
              slotProps={{ htmlInput: { inputMode: 'numeric' } }}
            />
            <TextField
              label="Assumed arrivals per hour"
              value={arrivals}
              onChange={(e) => setArrivals(e.target.value.trim())}
              error={Boolean(errors.arrivals)}
              helperText={errors.arrivals || 'Leave empty if not known'}
              fullWidth
              slotProps={{ htmlInput: { inputMode: 'numeric' } }}
            />
          </Stack>
          <TextField
            label="Basis (required)"
            value={basis}
            onChange={(e) => setBasis(e.target.value)}
            error={Boolean(errors.basis)}
            helperText={errors.basis || 'For example: who confirmed it, or which document'}
            multiline
            minRows={2}
            required
            fullWidth
          />
          {none && (
            <Typography variant="caption" sx={{ color: 'error.main' }}>
              Enter stands, arrivals per hour, or both.
            </Typography>
          )}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Cancel</Button>
        <Button variant="contained" onClick={submit} disabled={invalid || isLoading}>
          Save assumption
        </Button>
      </DialogActions>
    </Dialog>
  );
}
