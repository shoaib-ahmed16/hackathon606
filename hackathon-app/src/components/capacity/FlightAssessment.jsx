import { useMemo, useState } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Typography,
  useTheme,
} from '@mui/material';
import { BarChart } from '@mui/x-charts/BarChart';
import {
  useGetCapacityAssessQuery,
  useGetCapacityCompareQuery,
  useGetFlightsQuery,
} from '@/features/ops/opsApi';
import { fmtZL } from '@/features/ops/time';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { OutcomeChip, SourceChip } from './CapacityBits';
import { dash, hourLabel, ms, scenarioParams } from './capacityHelpers';

const OPEN = new Set(['SCHEDULED', 'TAXI_OUT', 'AIRBORNE', 'HOLDING', 'DIVERTING']);

const flightLabel = (f) =>
  `${f.flight_no}  ${f.dep_iata} → ${f.planned_arr_iata}  ETA ${fmtZL(ms(f.eta_utc ?? f.sta_utc))}`;

function Row({ label, before, after, note }) {
  return (
    <TableRow>
      <TableCell>{label}</TableCell>
      <TableCell>{before}</TableCell>
      <TableCell>{after}</TableCell>
      <TableCell sx={{ color: 'text.secondary' }}>{note}</TableCell>
    </TableRow>
  );
}

// "Can this airport take this flight?" plus what-if: one more flight, three in the same hour, a 30 or 60 minute delay,
// which alternate has most room, and when it gets tight. Read-only: it never approves or executes a diversion.
export default function FlightAssessment({ airports, scenarioId }) {
  const theme = useTheme();
  const [flight, setFlight] = useState(null);
  const [iata, setIata] = useState('RKT');
  const [extra, setExtra] = useState(0);
  const [delay, setDelay] = useState(0);
  const { data: flights = [] } = useGetFlightsQuery(scenarioParams(scenarioId));
  const options = useMemo(
    () =>
      flights
        .filter((f) => OPEN.has(f.status))
        .sort((a, b) => Date.parse(a.eta_utc ?? a.sta_utc) - Date.parse(b.eta_utc ?? b.sta_utc))
        .slice(0, 300),
    [flights],
  );
  const q = {
    ...scenarioParams(scenarioId),
    ...(flight ? { flight_id: flight.flight_id } : {}),
    extra,
    delay_min: delay,
    window_h: 12,
  };
  const {
    data: a,
    error,
    isFetching,
  } = useGetCapacityAssessQuery({ iata, ...q }, { pollingInterval: 10000 });
  const { data: cmp = [] } = useGetCapacityCompareQuery(q, { pollingInterval: 10000 });
  const hourly = a?.hourly ?? [];
  const proposed = a?.proposed_flights ?? 0;
  const st = a?.stands;
  const ar = a?.arrivals_per_hr;
  const oc = a?.occupancy;
  const hasFlight = Boolean(flight);

  return (
    <Paper sx={{ p: 2.5 }}>
      <Stack spacing={2}>
        <div>
          <Typography variant="h6">Incoming flight capacity assessment and what-if</Typography>
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            Choose a flight and an alternate. The assessment explains whether the airport could take
            it. It does not approve or execute a diversion: a person decides.
          </Typography>
        </div>

        <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
          <Autocomplete
            sx={{ flex: 2 }}
            options={options}
            value={flight}
            onChange={(_, v) => setFlight(v)}
            getOptionLabel={flightLabel}
            isOptionEqualToValue={(o, v) => o.flight_id === v.flight_id}
            renderInput={(p) => <TextField {...p} label="Flight (optional)" />}
          />
          <TextField
            select
            label="Proposed alternate"
            value={iata}
            onChange={(e) => setIata(e.target.value)}
            sx={{ flex: 1 }}
          >
            {airports.map((x) => (
              <MenuItem key={x.airport} value={x.airport}>
                {x.airport} {x.name}
              </MenuItem>
            ))}
          </TextField>
        </Stack>
        <Stack
          direction={{ xs: 'column', sm: 'row' }}
          spacing={3}
          sx={{ alignItems: { sm: 'center' } }}
        >
          <Box>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              Additional flights in the same hour
            </Typography>
            <br />
            <ToggleButtonGroup
              exclusive
              size="small"
              value={extra}
              onChange={(_, v) => v !== null && setExtra(v)}
            >
              {[0, 1, 2, 3].map((n) => (
                <ToggleButton key={n} value={n}>
                  {n === 0 ? 'None' : `+${n}`}
                </ToggleButton>
              ))}
            </ToggleButtonGroup>
          </Box>
          <Box>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              Delay of the flight
            </Typography>
            <br />
            <ToggleButtonGroup
              exclusive
              size="small"
              value={delay}
              onChange={(_, v) => v !== null && setDelay(v)}
            >
              {[0, 30, 60].map((n) => (
                <ToggleButton key={n} value={n}>
                  {n === 0 ? 'On time' : `+${n} min`}
                </ToggleButton>
              ))}
            </ToggleButtonGroup>
          </Box>
        </Stack>

        {error && <Alert severity="error">{getErrorMessage(error)}</Alert>}
        {a && (
          <Stack spacing={2} sx={{ opacity: isFetching ? 0.7 : 1 }}>
            <Stack
              direction="row"
              spacing={1.5}
              sx={{ alignItems: 'center', flexWrap: 'wrap', rowGap: 1 }}
            >
              <OutcomeChip outcome={a.outcome} size="medium" />
              <Typography variant="body2">
                {hasFlight
                  ? `${flight.flight_no} (${dash(flight.registration)}), ${flight.dep_iata} → ${flight.planned_arr_iata}, to ${iata}`
                  : `${proposed} additional flight(s) at ${iata}`}
                {'  ·  expected arrival '}
                <b>{fmtZL(ms(a.arrival_utc))}</b>
              </Typography>
            </Stack>
            <Typography variant="caption" sx={{ color: 'text.secondary' }}>
              {a.arrival_basis}
            </Typography>
            {a.verification_required && (
              <Alert severity="warning">
                Verification required: a figure here is assumed, estimated from history (a minimum,
                not a limit) or unknown.
              </Alert>
            )}
            <Box component="ul" sx={{ m: 0, pl: 2.5 }}>
              {a.reasons?.map((r) => (
                <li key={r}>
                  <Typography variant="body2">{r}</Typography>
                </li>
              ))}
            </Box>

            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Capacity</TableCell>
                  <TableCell>Before</TableCell>
                  <TableCell>After {proposed} proposed</TableCell>
                  <TableCell>Source</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                <Row
                  label="Stands free at arrival"
                  before={dash(st.free_before)}
                  after={dash(st.free_after)}
                  note={<SourceChip source={st.source} basis={st.basis} />}
                />
                <Row
                  label="Arrival slots left in the hour"
                  before={dash(ar.remaining_before)}
                  after={dash(ar.remaining_after)}
                  note={<SourceChip source={ar.source} basis={ar.basis} />}
                />
                <Row
                  label="Arrivals scheduled in that hour"
                  before={ar.scheduled_in_hour}
                  after={ar.projected_in_hour}
                  note="Existing traffic around the ETA"
                />
                <Row
                  label="Aircraft on the ground at arrival"
                  before={`${oc.on_ground_at_arrival_known_departure + oc.on_ground_at_arrival_no_known_departure}`}
                  after={`${oc.on_ground_at_arrival_known_departure + oc.on_ground_at_arrival_no_known_departure + proposed}`}
                  note={`${oc.on_ground_at_arrival_no_known_departure} with no known departure. Derived, not verified.`}
                />
                <Row
                  label="Departures in that hour"
                  before={oc.departures_in_arrival_hour}
                  after={oc.departures_in_arrival_hour}
                  note="Expected outbound"
                />
              </TableBody>
            </Table>

            <Typography variant="subtitle2">
              Next 12 hours with the proposed flight(s) added to each hour (UTC)
            </Typography>
            <BarChart
              height={220}
              colors={[theme.palette.primary.main, theme.palette.success.main]}
              xAxis={[{ scaleType: 'band', data: hourly.map((x) => hourLabel(x.hour_utc)) }]}
              series={[
                {
                  data: hourly.map((x) => x.arrival_slots_left_with_proposed),
                  label: 'Arrival slots left',
                },
                { data: hourly.map((x) => x.stands_free_with_proposed), label: 'Stands free' },
              ]}
            />
          </Stack>
        )}

        <Typography variant="subtitle1">
          Which alternate has the most room? (same flight, extras and delay)
        </Typography>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Airport</TableCell>
              <TableCell>Outcome</TableCell>
              <TableCell>Stands free</TableCell>
              <TableCell>Arrival slots left</TableCell>
              <TableCell>First tight hour (UTC)</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {cmp.map((r) => (
              <TableRow
                key={r.airport}
                hover
                selected={r.airport === iata}
                onClick={() => setIata(r.airport)}
                sx={{ cursor: 'pointer' }}
              >
                <TableCell>
                  {r.airport} {r.name}
                </TableCell>
                <TableCell>
                  <OutcomeChip outcome={r.outcome} />
                </TableCell>
                <TableCell>
                  {dash(r.stands_free_before)} {'→'} {dash(r.stands_free_after)}
                </TableCell>
                <TableCell>
                  {dash(r.arrival_slots_before)} {'→'} {dash(r.arrival_slots_after)}
                </TableCell>
                <TableCell>
                  {r.first_constrained_hour_utc
                    ? `${hourLabel(r.first_constrained_hour_utc)}:00`
                    : 'none in 12 h'}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          What-if values are computed on the fly and stored nowhere: imported data and the live
          scenario are never changed.
        </Typography>
      </Stack>
    </Paper>
  );
}
