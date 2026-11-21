import {
  Box,
  Chip,
  IconButton,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TableSortLabel,
  Typography,
} from '@mui/material';
import ChevronRightIcon from '@mui/icons-material/ChevronRight';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtTime } from '@/features/ops/time';
import EmptyState from '@/components/EmptyState';
import StatusChip from './StatusChip';
import MarginBar from './MarginBar';

export function Legend() {
  return (
    <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
      <Chip size="small" color="error" variant="outlined" label="Act now / illegal" />
      <Chip size="small" color="warning" variant="outlined" label="Hold / tight margin" />
      <Chip size="small" color="success" variant="outlined" label="Feasible / legal" />
    </Box>
  );
}

const T = (iso) => (iso ? fmtTime(ms(iso)) : '-');

// The decision table: status + freshness, crew margin, recommendation, latest legal vs target, owner.
export default function DecisionTable({ flights, sort, onSort }) {
  const dispatch = useAppDispatch();
  const head = (key, label) =>
    onSort ? (
      <TableSortLabel
        active={sort.by === key}
        direction={sort.desc ? 'desc' : 'asc'}
        onClick={() => onSort(key)}
      >
        {label}
      </TableSortLabel>
    ) : (
      label
    );
  if (flights.length === 0)
    return <EmptyState title="No flights match" hint="Clear the filters or pick another case" />;
  return (
    <TableContainer sx={{ maxHeight: 640 }}>
      <Table stickyHeader>
        <TableHead>
          <TableRow>
            <TableCell>{head('flight_no', 'Flight & tail')}</TableCell>
            <TableCell>{head('eta_utc', 'Live status')}</TableCell>
            <TableCell>{head('crew_margin_min', 'Crew & FDP margin')}</TableCell>
            <TableCell>Agent recommendation</TableCell>
            <TableCell>Latest legal vs target</TableCell>
            <TableCell>Decision</TableCell>
            <TableCell>Owner</TableCell>
            <TableCell />
          </TableRow>
        </TableHead>
        <TableBody>
          {flights.map((f) => {
            const dest = f.diverted_to ?? f.current_dest_iata;
            return (
              <TableRow
                key={f.flight_id}
                hover
                sx={{ cursor: 'pointer', '& td': { verticalAlign: 'top' } }}
                onClick={() => dispatch(selectFlight(f.flight_id))}
              >
                <TableCell>
                  <Typography component="div" variant="subtitle2">
                    {f.flight_no}{' '}
                    <Chip size="small" variant="outlined" label={f.registration ?? 'no tail'} />
                  </Typography>
                  <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                    {f.dep_iata} to {dest}
                    {f.diverted_to ? ` (planned ${f.planned_arr_iata})` : ''}
                  </Typography>
                </TableCell>
                <TableCell>
                  <StatusChip status={f.status} />
                  <Typography variant="body2" sx={{ color: 'text.secondary' }}>
                    ETA {T(f.eta_utc ?? f.sta_utc)}
                    {f.arr_delay_min > 0 ? ` (+${f.arr_delay_min}m)` : ''}
                  </Typography>
                  <Typography
                    variant="caption"
                    sx={{ color: f.data_age_min > 15 ? 'warning.main' : 'text.secondary' }}
                  >
                    {f.waiting_for
                      ? `waiting: ${f.waiting_for.replaceAll('_', ' ').toLowerCase()} - `
                      : ''}
                    {f.data_age_min != null ? `data ${f.data_age_min}m old` : 'no live feed'}
                  </Typography>
                </TableCell>
                <TableCell>
                  <Typography variant="body2" sx={{ color: 'text.secondary' }}>
                    {f.captain ? `Capt. ${f.captain}` : 'crew n/a'}
                  </Typography>
                  <StatusChip status={f.crew_status} />
                  {f.lvp_required && f.lvp_crew_ok === false && (
                    <Chip
                      size="small"
                      color="error"
                      label={`No LVP: ${f.lvp_not_qualified?.map((p) => p.position).join('/')}`}
                      sx={{ ml: 0.5 }}
                    />
                  )}
                  {f.lvp_required && f.lvp_crew_ok === null && (
                    <Chip size="small" color="warning" label="LVP?" sx={{ ml: 0.5 }} />
                  )}
                  {f.crew_margin_min != null && <MarginBar margin={f.crew_margin_min} />}
                </TableCell>
                <TableCell>
                  {f.recommendation ? (
                    <>
                      <StatusChip status={f.recommendation} />
                      {f.recommended_alternate && (
                        <Typography variant="caption" sx={{ display: 'block' }}>
                          via {f.recommended_alternate}
                        </Typography>
                      )}
                    </>
                  ) : (
                    <Typography variant="body2" sx={{ color: 'text.secondary' }}>
                      -
                    </Typography>
                  )}
                </TableCell>
                <TableCell sx={{ fontFamily: 'monospace' }}>
                  <Typography
                    variant="body2"
                    sx={{
                      fontFamily: 'inherit',
                      color:
                        f.departure_legality === 'EXCEEDED'
                          ? 'error.main'
                          : f.departure_legality === 'DISCRETION_REQUIRED'
                            ? 'warning.main'
                            : 'text.primary',
                    }}
                  >
                    Legal {T(f.latest_legal_offblocks_utc)}
                  </Typography>
                  <Typography
                    variant="caption"
                    sx={{ fontFamily: 'inherit', color: 'text.secondary' }}
                  >
                    Target {T(f.operational_target_utc)}
                  </Typography>
                </TableCell>
                <TableCell>
                  {f.last_decision ? (
                    <>
                      <Typography variant="body2">{f.last_decision}</Typography>
                      <StatusChip status={f.decision_status} />
                    </>
                  ) : (
                    '-'
                  )}
                </TableCell>
                <TableCell>{f.owner ?? f.owner_role ?? '-'}</TableCell>
                <TableCell>
                  <IconButton size="small" aria-label="Inspect">
                    <ChevronRightIcon />
                  </IconButton>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
