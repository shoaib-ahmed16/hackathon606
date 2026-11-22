import {
  Alert,
  Box,
  Button,
  Divider,
  Drawer,
  IconButton,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
  useTheme,
} from '@mui/material';
import { BarChart } from '@mui/x-charts/BarChart';
import CloseIcon from '@mui/icons-material/Close';
import Loader from '@/components/Loader';
import StatusChip from '@/console/ui/StatusChip';
import { useGetAirportCapacityDetailQuery } from '@/features/ops/opsApi';
import { fmtZL, fmtZs } from '@/features/ops/time';
import { OutcomeChip, SourceChip } from './CapacityBits';
import { dash, hourLabel, lowerBound, ms, scenarioParams } from './capacityHelpers';

function Stat({ label, value, source, basis, note }) {
  return (
    <Paper variant="outlined" sx={{ p: 1.5 }}>
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        {label}
      </Typography>
      <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
        <Typography variant="h5">{value}</Typography>
        {source && <SourceChip source={source} basis={basis} />}
      </Stack>
      {note && (
        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {note}
        </Typography>
      )}
    </Paper>
  );
}

function FlightRows({ rows, timeKey, timeLabel, extra }) {
  if (!rows?.length) {
    return (
      <Typography variant="body2" sx={{ color: 'text.secondary' }}>
        None in the data.
      </Typography>
    );
  }
  return (
    <Table size="small">
      <TableHead>
        <TableRow>
          <TableCell>Flight</TableCell>
          <TableCell>Aircraft</TableCell>
          <TableCell>{timeLabel}</TableCell>
          <TableCell>{extra[0]}</TableCell>
        </TableRow>
      </TableHead>
      <TableBody>
        {rows.map((f) => (
          <TableRow key={`${f.flight_id}-${timeKey}`}>
            <TableCell>
              {f.flight_no}
              {f.diverted ? ' (diverted)' : ''}
            </TableCell>
            <TableCell>{dash(f.registration)}</TableCell>
            <TableCell>
              {fmtZL(ms(f[timeKey]))}
              {f.arrival_is_actual === false || f.departure_is_actual === false ? ' (planned)' : ''}
            </TableCell>
            <TableCell>{extra[1](f)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

// One airport in depth: stands, arrivals, occupancy, next hours, history and the traffic around now.
export default function AirportDetail({ iata, scenarioId, canEdit, onEdit, onClose }) {
  const theme = useTheme();
  const {
    data: d,
    isLoading,
    error,
  } = useGetAirportCapacityDetailQuery(
    { iata, window_h: 24, ...scenarioParams(scenarioId) },
    { skip: !iata },
  );
  const hourly = d?.assessment?.hourly ?? [];
  const byHour = d?.history_profile?.by_hour_utc ?? [];
  const h = d?.history;

  return (
    <Drawer anchor="right" open={Boolean(iata)} onClose={onClose}>
      <Box sx={{ width: { xs: '100vw', md: 760 }, p: 2.5 }}>
        <Stack direction="row" sx={{ alignItems: 'center', justifyContent: 'space-between' }}>
          <Stack direction="row" spacing={1} sx={{ alignItems: 'center', flexWrap: 'wrap' }}>
            <Typography variant="h5">
              {iata} {d?.name ? `· ${d.name}` : ''}
            </Typography>
            {d?.airport_op_status && <StatusChip status={d.airport_op_status} />}
            {d && <OutcomeChip outcome={d.outcome} />}
          </Stack>
          <Stack direction="row" spacing={1}>
            {canEdit && d && (
              <Button size="small" variant="outlined" onClick={() => onEdit(d)}>
                Set capacity
              </Button>
            )}
            <IconButton onClick={onClose} aria-label="Close">
              <CloseIcon />
            </IconButton>
          </Stack>
        </Stack>

        {isLoading && <Loader />}
        {error && <Alert severity="error">Could not load this airport.</Alert>}
        {d && (
          <Stack spacing={2.5} sx={{ mt: 2 }}>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              Refreshed with the scenario clock {fmtZs(ms(d.computed_at_utc))}. Updates every 10
              seconds.
            </Typography>

            <Box
              sx={{
                display: 'grid',
                gridTemplateColumns: { xs: '1fr 1fr', sm: 'repeat(3, 1fr)' },
                gap: 1.5,
              }}
            >
              <Stat
                label="Total stands"
                value={lowerBound(d.stands_total, d.stands_source)}
                source={d.stands_source}
                basis={d.stands_basis}
              />
              <Stat
                label="Occupied now"
                value={dash(d.occupied_stands)}
                note="From Air Arabia movements. Not verified."
              />
              <Stat
                label="Available stands"
                value={dash(d.available_stands)}
                note={d.available_stands == null ? 'Unknown' : undefined}
              />
              <Stat
                label="Arrivals per hour"
                value={lowerBound(d.arrivals_per_hr, d.arrivals_source)}
                source={d.arrivals_source}
                basis={d.arrivals_basis}
              />
              <Stat
                label="Inbound, next 12 h"
                value={d.inbound?.length ?? 0}
                note="Scheduled and updated ETAs"
              />
              <Stat
                label="Outbound, next 12 h"
                value={d.outbound?.length ?? 0}
                note="Scheduled and updated ETDs"
              />
            </Box>

            <Alert severity="info">
              <b>Confidence.</b> Stands: {d.stands_basis}. Arrivals per hour: {d.arrivals_basis}.
            </Alert>
            {d.reasons?.map((r) => (
              <Typography key={r} variant="body2" sx={{ color: 'text.secondary' }}>
                {r}
              </Typography>
            ))}

            <Divider />
            <Typography variant="h6">Next 24 hours (UTC)</Typography>
            <BarChart
              height={240}
              colors={[theme.palette.primary.main, theme.palette.secondary.main]}
              xAxis={[{ scaleType: 'band', data: hourly.map((x) => hourLabel(x.hour_utc)) }]}
              series={[
                { data: hourly.map((x) => x.arrivals_scheduled), label: 'Arrivals' },
                { data: hourly.map((x) => x.departures_scheduled), label: 'Departures' },
              ]}
            />
            <BarChart
              height={220}
              colors={[theme.palette.info.main, theme.palette.success.main]}
              xAxis={[{ scaleType: 'band', data: hourly.map((x) => hourLabel(x.hour_utc)) }]}
              series={[
                { data: hourly.map((x) => x.on_ground), label: 'Aircraft on ground (derived)' },
                { data: hourly.map((x) => x.stands_free), label: 'Stands free (if known)' },
              ]}
            />

            <Divider />
            <Typography variant="h6">History (Jan to Nov 2026, actual arrivals)</Typography>
            <Box
              sx={{
                display: 'grid',
                gridTemplateColumns: { xs: '1fr 1fr', sm: 'repeat(3, 1fr)' },
                gap: 1.5,
              }}
            >
              <Stat
                label="Hours with arrivals"
                value={h?.sample_n ?? 0}
                note={`Needs ${d.history_min_sample_hours} to be used`}
              />
              <Stat label="Total arrivals" value={dash(h?.arrivals_total)} />
              <Stat
                label="Peak arrivals / hour"
                value={dash(h?.peak_arrivals_per_hr)}
                note="A minimum, not a limit"
              />
              <Stat
                label="Average / active hour"
                value={dash(h?.avg_arrivals_per_active_hr)}
                note="Hours with traffic only"
              />
              <Stat
                label="Peak on ground"
                value={dash(h?.peak_ground)}
                note="A minimum, not a limit"
              />
              <Stat
                label="Average on ground"
                value={dash(h?.avg_ground)}
                note="Needs 7+ days of span"
              />
            </Box>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {h?.basis}
            </Typography>
            <Typography variant="subtitle2">
              Arrivals by hour of day (UTC), whole history
            </Typography>
            <BarChart
              height={220}
              colors={[theme.palette.primary.main]}
              xAxis={[
                { scaleType: 'band', data: byHour.map((x) => String(x.hour).padStart(2, '0')) },
              ]}
              series={[{ data: byHour.map((x) => x.arrivals), label: 'Arrivals' }]}
            />

            <Divider />
            <Typography variant="h6">On the ground now</Typography>
            <FlightRows
              rows={d.on_ground}
              timeKey="arrived_utc"
              timeLabel="Arrived"
              extra={[
                'Departure',
                (f) => (f.departure_utc ? fmtZL(ms(f.departure_utc)) : 'none known'),
              ]}
            />
            <Typography variant="h6">Inbound</Typography>
            <FlightRows
              rows={d.inbound}
              timeKey="arrival_utc"
              timeLabel="Arrival"
              extra={['From', (f) => f.origin]}
            />
            <Typography variant="h6">Outbound</Typography>
            <FlightRows
              rows={d.outbound}
              timeKey="departure_utc"
              timeLabel="Departure"
              extra={['To', (f) => f.destination]}
            />
          </Stack>
        )}
      </Box>
    </Drawer>
  );
}
