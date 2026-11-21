import {
  Button,
  Chip,
  Dialog,
  DialogContent,
  DialogTitle,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { useAddRecordMutation, useGetStandbyQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtDur, fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';

const T = (iso) => (iso ? fmtZL(ms(iso)) : '-');

// Q4: who can replace this crew member without breaking legality or the roster.
export default function StandbyDialog({ d, row, onClose }) {
  const dispatch = useAppDispatch();
  const [add, { isLoading }] = useAddRecordMutation();
  const { data = [], isFetching } = useGetStandbyQuery({
    scenario_id: d.ctx.scenario_id,
    duty_id: row.duty_id,
    position: row.position_code,
    station: 'SHJ',
    from_leg: 1,
  });
  const flight = d.flights.find((f) => f.duty_id === row.duty_id);
  // The database requires an APPROVED CREW_REPLACE decision before a swap can run: propose it here,
  // approve it in the flight panel, then execute it there.
  const propose = async (c) => {
    try {
      await add({
        table: 'decision',
        body: {
          scenario_id: d.ctx.scenario_id,
          case_id: d.ctx.case_id,
          flight_id: flight.flight_id,
          decision_type: 'CREW_REPLACE',
          rationale: `Replace ${row.position_code} ${row.full_name} with ${c.full_name} (${c.pattern_name}): ${c.verdict}`,
          decided_by: d.actor.user_id,
          decided_role: d.actor.role_code,
          details: {
            duty_id: row.duty_id,
            out_crew_id: row.crew_id,
            in_crew_id: c.crew_id,
            sign_in_utc: c.new_sign_in_utc,
            report_station: 'SHJ',
            from_leg_seq: 1,
            standby_id: c.standby_id,
            positioning_min: c.positioning_min,
          },
        },
      }).unwrap();
      toast.success('Swap proposed. Approve and execute it in the flight panel.');
      onClose();
      dispatch(selectFlight(flight.flight_id));
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  return (
    <Dialog open onClose={onClose} maxWidth="md" fullWidth>
      <DialogTitle>
        Replace {row.position_code} {row.full_name} ({row.duty_legs})
      </DialogTitle>
      <DialogContent>
        {isFetching && (
          <Typography variant="body2">
            Checking rest, roster conflicts, LVP and positioning...
          </Typography>
        )}
        <Table>
          <TableHead>
            <TableRow>
              <TableCell>Standby</TableCell>
              <TableCell>Sign-in</TableCell>
              <TableCell>Positioning</TableCell>
              <TableCell>FDP margin</TableCell>
              <TableCell>Verdict</TableCell>
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {data.map((c) => (
              <TableRow key={c.crew_id}>
                <TableCell>
                  {c.full_name}
                  <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
                    {c.pattern_name} - {c.lvp_qualified ? 'LVP qualified' : 'no LVP'}
                  </Typography>
                </TableCell>
                <TableCell>{T(c.new_sign_in_utc)}</TableCell>
                <TableCell>{c.positioning_min} min</TableCell>
                <TableCell>{fmtDur(c.margin_min)}</TableCell>
                <TableCell>
                  <Chip
                    size="small"
                    variant="outlined"
                    color={c.roster_conflict ? 'error' : 'success'}
                    label={c.verdict}
                  />
                </TableCell>
                <TableCell>
                  <Button
                    size="small"
                    variant="contained"
                    disabled={isLoading || !flight || c.verdict !== 'CANDIDATE'}
                    onClick={() => propose(c)}
                  >
                    Propose swap
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        {!isFetching && data.length === 0 && (
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            No standby candidates for this position.
          </Typography>
        )}
      </DialogContent>
    </Dialog>
  );
}
