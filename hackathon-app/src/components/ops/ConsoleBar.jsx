import {
  Box,
  Button,
  Chip,
  Stack,
  ToggleButton,
  ToggleButtonGroup,
  Typography,
} from '@mui/material';
import toast from 'react-hot-toast';
import { useAppDispatch } from '@/app/hooks';
import { usePushFeedMutation } from '@/features/ops/opsApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { openPanel, setLens, toggleSources } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { useNow } from '@/hooks/useNow';
import Countdown from './Countdown';

export const LENSES = [
  ['occ', 'OCC'],
  ['dispatch', 'Dispatch'],
  ['crew', 'Crew Control'],
  ['station', 'Station'],
  ['recovery', 'Recovery'],
];

// Next deadline across the whole case + role lenses + tools.
export default function ConsoleBar({ d, briefing, onBriefing }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const { ops, deadlines } = d;
  const [pushFeed, { isLoading: pushing }] = usePushFeedMutation();
  const onPush = async () => {
    try {
      const r = await pushFeed().unwrap();
      toast.success(
        r.events_applied || r.crew_duties_active || r.crew_duties_completed
          ? `Feed pushed: ${r.flights_updated} flights, ${r.events_applied} events, ${r.crew_duties_active} duties started, ${r.crew_duties_completed} completed, ${r.fuel_estimates} fuel updates`
          : 'Feed pushed: already up to date',
      );
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };
  const dated = deadlines
    .filter((x) => x.deadline_utc)
    .sort((a, b) => ms(a.deadline_utc) - ms(b.deadline_utc));
  // the next deadline still ahead; if everything is already past, show the most recent one as overdue
  const upcoming = dated.filter((x) => ms(x.deadline_utc) >= now);
  const overdue = dated.filter((x) => ms(x.deadline_utc) < now);
  const next = upcoming[0] ?? overdue[overdue.length - 1];
  const verify = deadlines.filter((x) => !x.deadline_utc);

  return (
    <Stack
      direction={{ xs: 'column', lg: 'row' }}
      spacing={1.5}
      sx={{ alignItems: { lg: 'center' }, flexWrap: 'wrap', rowGap: 1 }}
    >
      <Box
        sx={{ flex: 1, minWidth: 280 }}
        data-src="min(deadline) per flight: v_flight_watch + flight_decision_inputs + rank_alternates"
      >
        {next ? (
          <Stack direction="row" spacing={1} sx={{ alignItems: 'baseline', flexWrap: 'wrap' }}>
            <Chip
              size="small"
              color="error"
              label={upcoming.length ? 'Next deadline' : 'Overdue'}
            />
            <Countdown at={ms(next.deadline_utc)} big />
            <Typography variant="body2">
              <b>{next.flight_no}</b> - {next.reason}
            </Typography>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              ({new Date(ms(next.deadline_utc)).toISOString().slice(11, 16)}Z)
            </Typography>
          </Stack>
        ) : (
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            No deadline is running right now.
          </Typography>
        )}
        {upcoming.length > 0 && overdue.length > 0 && (
          <Typography variant="caption" sx={{ color: 'error.main', display: 'block' }}>
            {overdue.length} already passed: {overdue.map((o) => o.flight_no).join(', ')}
          </Typography>
        )}
        {verify.length > 0 && (
          <Typography variant="caption" sx={{ color: 'warning.main' }}>
            {verify.length} flight(s) cannot show a deadline until fuel is reported:{' '}
            {verify.map((v) => v.flight_no).join(', ')}
          </Typography>
        )}
      </Box>
      <Button size="small" variant={briefing ? 'contained' : 'outlined'} onClick={onBriefing}>
        Since you last looked
      </Button>
      <ToggleButtonGroup
        exclusive
        size="small"
        value={ops.lens}
        onChange={(_, v) => v && dispatch(setLens(v))}
        aria-label="Role lens"
      >
        {LENSES.map(([k, label]) => (
          <ToggleButton key={k} value={k}>
            {label}
          </ToggleButton>
        ))}
      </ToggleButtonGroup>
      <Stack direction="row" spacing={0.5}>
        <Button
          size="small"
          variant="outlined"
          disabled={pushing}
          onClick={onPush}
          title="Simulate the live feed up to now: flight movements, passengers, crew duty status, standby release and fuel"
        >
          {pushing ? 'Pushing...' : 'Push live data'}
        </Button>
        <Button size="small" onClick={() => dispatch(openPanel('whatif'))}>
          What if...
        </Button>
        <Button
          size="small"
          variant={ops.showSources ? 'contained' : 'text'}
          onClick={() => dispatch(toggleSources())}
          title="Show which database view feeds each part"
        >
          Data sources
        </Button>
      </Stack>
    </Stack>
  );
}
