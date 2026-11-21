import { useMemo, useState } from 'react';
import { Box, MenuItem, Paper, Stack, TextField } from '@mui/material';
import { sortBy } from 'lodash-es';
import { useDebounce } from '@/hooks/useDebounce';
import PageHeader from '@/components/PageHeader';
import OpsPage from '@/components/ops/OpsPage';
import DecisionTable, { Legend } from '@/components/ops/DecisionTable';

const CREW = [
  'ALL',
  'EXCEEDED',
  'DISCRETION_REQUIRED',
  'VERIFICATION_REQUIRED',
  'AT_RISK',
  'LEGAL',
];
const STATUS = [
  'ALL',
  'SCHEDULED',
  'TAXI_OUT',
  'AIRBORNE',
  'HOLDING',
  'DIVERTING',
  'LANDED',
  'ON_BLOCKS',
  'CANCELLED',
];

function Body({ d }) {
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('ALL');
  const [crew, setCrew] = useState('ALL');
  const [sort, setSort] = useState({ by: 'eta_utc', desc: false });
  const dq = useDebounce(q, 200);

  const rows = useMemo(() => {
    const t = dq.trim().toLowerCase();
    const r = d.flights.filter(
      (f) =>
        (status === 'ALL' || f.status === status) &&
        (crew === 'ALL' || f.crew_status === crew) &&
        (!t ||
          `${f.flight_no} ${f.registration} ${f.dep_iata} ${f.planned_arr_iata} ${f.diverted_to ?? ''} ${f.captain ?? ''}`
            .toLowerCase()
            .includes(t)),
    );
    const sorted = sortBy(r, (f) => f[sort.by] ?? Infinity);
    return sort.desc ? sorted.reverse() : sorted;
  }, [d.flights, dq, status, crew, sort]);

  return (
    <Box sx={{ display: 'grid', gap: 2 }}>
      <PageHeader
        title="Flight Watch"
        subtitle={`${rows.length} of ${d.flights.length} flights on this case - click a row for crew legality, recommendation and decisions`}
      />
      <Paper sx={{ p: 2 }}>
        <Stack
          direction={{ xs: 'column', md: 'row' }}
          spacing={2}
          sx={{ alignItems: { md: 'center' } }}
        >
          <TextField
            label="Search flight, tail, airport, captain"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
          <TextField
            select
            label="Flight status"
            value={status}
            onChange={(e) => setStatus(e.target.value)}
            sx={{ minWidth: 170 }}
          >
            {STATUS.map((s) => (
              <MenuItem key={s} value={s}>
                {s === 'ALL' ? 'All statuses' : s.replaceAll('_', ' ')}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            select
            label="Crew legality"
            value={crew}
            onChange={(e) => setCrew(e.target.value)}
            sx={{ minWidth: 190 }}
          >
            {CREW.map((s) => (
              <MenuItem key={s} value={s}>
                {s === 'ALL' ? 'All' : s.replaceAll('_', ' ')}
              </MenuItem>
            ))}
          </TextField>
          <Legend />
        </Stack>
      </Paper>
      <Paper>
        <DecisionTable
          flights={rows}
          sort={sort}
          onSort={(key) => setSort((s) => ({ by: key, desc: s.by === key ? !s.desc : false }))}
        />
      </Paper>
    </Box>
  );
}

export default function FlightWatch() {
  return <OpsPage>{(d) => <Body d={d} />}</OpsPage>;
}
