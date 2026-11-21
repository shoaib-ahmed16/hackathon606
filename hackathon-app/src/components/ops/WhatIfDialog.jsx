import { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Slider,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useWhatIfMutation } from '@/features/ops/opsApi';
import { closePanel, selectCase } from '@/features/ops/opsSlice';
import { fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';

// What if the airport stays closed longer (or closes again)? Runs the real engine in a separate WHATIF copy of the
// scenario and compares its advice with today's. Nothing live is touched.
export default function WhatIfDialog({ d }) {
  const dispatch = useAppDispatch();
  const [run, { isLoading, data }] = useWhatIfMutation();
  const [shift, setShift] = useState(60);
  const hub = d.airport.find((a) => a.iata === d.kase?.hub_iata);

  const go = async () => {
    try {
      await run({ ...d.ctx, reopen_shift_min: shift }).unwrap();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const open = () => {
    dispatch(selectCase({ scenario_id: data.scenario_id, case_id: data.case_id }));
    dispatch(closePanel());
  };

  return (
    <Dialog open onClose={() => dispatch(closePanel())} maxWidth="sm" fullWidth>
      <DialogTitle>What if {d.kase?.hub_iata} stays closed longer?</DialogTitle>
      <DialogContent>
        <Stack spacing={2}>
          <Alert severity="info">
            Runs in a separate what-if scenario. Live operations and the current case are not
            changed.
          </Alert>
          <Box>
            <Typography variant="body2" sx={{ color: 'text.secondary' }}>
              {hub?.expected_reopen_utc
                ? 'Move the reopening forecast by'
                : `${d.kase?.hub_iata} is open: close it again for`}
              :{' '}
              <b>
                {shift > 0 ? '+' : ''}
                {shift} min
              </b>
            </Typography>
            <Slider
              min={-60}
              max={240}
              step={15}
              value={shift}
              onChange={(_, v) => setShift(v)}
              valueLabelDisplay="auto"
            />
          </Box>
          {data && (
            <Box>
              <Typography variant="subtitle2" sx={{ mb: 0.5 }}>
                New reopening {fmtZL(Date.parse(data.new_reopen_utc))}: advice changes for{' '}
                <b>{data.changed}</b> of {data.rows.length} flights
              </Typography>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Flight</TableCell>
                    <TableCell>Now</TableCell>
                    <TableCell>What-if</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {data.rows.map((r) => (
                    <TableRow
                      key={r.flight_no}
                      sx={r.changed ? { bgcolor: 'action.hover' } : undefined}
                    >
                      <TableCell>
                        <b>{r.flight_no}</b>
                      </TableCell>
                      <TableCell>{r.current}</TableCell>
                      <TableCell>
                        {r.changed && (
                          <Chip size="small" color="warning" label="changes" sx={{ mr: 1 }} />
                        )}
                        {r.what_if}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Box>
          )}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={() => dispatch(closePanel())}>Close</Button>
        {data && <Button onClick={open}>Open this scenario</Button>}
        <Button variant="contained" disabled={isLoading} onClick={go}>
          {isLoading ? 'Running the engine...' : data ? 'Run again' : 'Run what-if'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
