import { useState } from 'react';
import { Box, Chip, InputAdornment, Paper, TextField, Typography } from '@mui/material';
import SearchIcon from '@mui/icons-material/Search';
import { useAppDispatch } from '@/app/hooks';
import { useGetAircraftQuery, useGetStandbyQuery } from '@/features/ops/opsApi';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtDur, fmtTime } from '@/features/ops/time';
import { useDebounce } from '@/hooks/useDebounce';
import StatusChip from './StatusChip';

const Card = ({ tone = 'primary', title, children, onClick }) => (
  <Paper
    onClick={onClick}
    sx={{
      p: 2,
      borderLeft: 4,
      borderColor: `${tone}.main`,
      cursor: onClick ? 'pointer' : 'default',
      '&:hover': onClick ? { bgcolor: 'action.hover' } : undefined,
    }}
  >
    <Typography variant="overline" sx={{ color: `${tone}.main` }}>
      {title}
    </Typography>
    {children}
  </Paper>
);
const T = (iso) => (iso ? fmtTime(ms(iso)) : '-');

// Four headline answers, all straight from the DB: Q1 next expiry, Q2 aircraft, Q3 latest departure, Q4 standby.
export default function SummaryCards({ d }) {
  const dispatch = useAppDispatch();
  const { crew, flights, ctx } = d;
  const [tail, setTail] = useState('');
  const reg = useDebounce(tail.trim(), 300);

  const q1 =
    crew.find((c) => c.minutes_until_legal_end != null && c.minutes_until_legal_end >= 0) ??
    crew[0];
  const q3 = flights
    .filter((f) => f.minutes_to_latest_legal_departure != null)
    .sort((a, b) => a.minutes_to_latest_legal_departure - b.minutes_to_latest_legal_departure)[0];
  const ac = useGetAircraftQuery({ reg, scenario_id: ctx.scenario_id }, { skip: reg.length < 3 });
  const sb = useGetStandbyQuery(
    {
      scenario_id: ctx.scenario_id,
      duty_id: q1?.duty_id,
      position: q1?.position_code,
      station: 'SHJ',
      from_leg: 1,
    },
    { skip: !q1 },
  );
  const best = sb.data?.find((c) => !c.roster_conflict) ?? sb.data?.[0];
  const a = ac.data?.[0];

  return (
    <Box
      sx={{
        display: 'grid',
        gap: 2,
        gridTemplateColumns: { xs: '1fr', md: 'repeat(2, 1fr)', xl: 'repeat(4, 1fr)' },
      }}
    >
      <Card
        tone={q1 && q1.minutes_until_legal_end < 60 ? 'error' : 'warning'}
        title="1. Next crew legality expiry"
        onClick={
          q1
            ? () => {
                const f = flights.find((x) => x.duty_id === q1.duty_id);
                if (f) dispatch(selectFlight(f.flight_id));
              }
            : undefined
        }
      >
        {q1 ? (
          <>
            <Typography variant="h4">
              {fmtDur(q1.minutes_until_legal_end)}{' '}
              <Typography component="span" variant="caption" sx={{ color: 'text.secondary' }}>
                ends {T(q1.legal_end_utc)} SHJ
              </Typography>
            </Typography>
            <Typography variant="body2">
              {q1.position_code} {q1.full_name} - {q1.duty_legs}
            </Typography>
            <StatusChip status={q1.status} />
          </>
        ) : (
          <Typography variant="body2">No active duty is approaching its legal limit.</Typography>
        )}
      </Card>
      <Card tone="warning" title="2. Aircraft locator">
        <TextField
          placeholder="Tail, e.g. A6-ANB"
          value={tail}
          onChange={(e) => setTail(e.target.value)}
          slotProps={{
            input: {
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              ),
            },
          }}
          sx={{ my: 0.5 }}
        />
        {a ? (
          <>
            <Typography component="div" variant="subtitle2">
              {a.flight_no ?? ''} <StatusChip status={a.status} />
            </Typography>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {Object.entries(a)
                .filter(([k, v]) => /location|waiting|iata/.test(k) && v)
                .map(([, v]) => v)
                .join(' - ')}
            </Typography>
          </>
        ) : (
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            {ac.isError && reg.length >= 3
              ? 'Aircraft not found in this scenario'
              : 'Type a registration'}
          </Typography>
        )}
      </Card>
      <Card
        tone="info"
        title="3. Most urgent latest-legal departure"
        onClick={q3 ? () => dispatch(selectFlight(q3.flight_id)) : undefined}
      >
        {q3 ? (
          <>
            <Typography variant="h4">
              {T(q3.latest_legal_offblocks_utc)}{' '}
              <Typography component="span" variant="caption" sx={{ color: 'text.secondary' }}>
                latest legal
              </Typography>
            </Typography>
            <Typography variant="body2">
              {q3.flight_no} {q3.registration} from {q3.departure_from_iata} - target{' '}
              {T(q3.operational_target_utc)}
            </Typography>
            <StatusChip status={q3.departure_legality} />
          </>
        ) : (
          <Typography variant="body2">No departure calculations yet.</Typography>
        )}
      </Card>
      <Card tone="success" title="4. Zero-impact standby crew">
        {best ? (
          <>
            <Typography variant="h6">
              {best.position_code} {best.full_name}
            </Typography>
            <Typography variant="body2">
              {best.pattern_name} - new sign-in {T(best.new_sign_in_utc)} - margin{' '}
              {fmtDur(best.margin_min)}
            </Typography>
            <Chip
              size="small"
              variant="outlined"
              color={best.roster_conflict ? 'error' : 'success'}
              label={best.verdict}
              sx={{ mt: 0.5 }}
            />
          </>
        ) : (
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            {sb.isFetching
              ? 'Checking standby pool...'
              : 'No candidate for the most critical duty.'}
          </Typography>
        )}
      </Card>
    </Box>
  );
}
