import {
  Box,
  Chip,
  IconButton,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Tooltip,
  Typography,
} from '@mui/material';
import EditIcon from '@mui/icons-material/Edit';
import { fmtZL } from '@/features/ops/time';
import { SourceChip } from './CapacityBits';
import { dash, lowerBound, ms } from './capacityHelpers';

const HEAD = [
  ['Airport', 'Airport code'],
  ['Name', null],
  [
    'Total stands',
    'Stands the airport can take. A status entry means stands FREE at the time it was entered.',
  ],
  [
    'Occupied',
    'Aircraft on the ground, derived from Air Arabia movements only. Not verified real-time occupancy.',
  ],
  ['Available', 'Free stands now. A dash means unknown, never zero.'],
  ['Diverted in', 'Flights diverted to this airport that have not landed yet (approved or executed diversions). Each will need a stand; the second number is stands left after they land.'],
  ['Arrivals / hr', 'Arrivals the airport can handle in one hour'],
  ['Projected arrivals', 'Arrivals scheduled in the current hour'],
  ['Remaining', 'Arrivals per hour minus projected arrivals'],
  ['Source', 'Where the stand and arrival figures come from'],
  ['History hours', 'Hours with at least one recorded arrival in the Jan-Nov 2026 history'],
  ['Peak arr / hr', 'Most arrivals seen in one hour. A minimum of what was handled, not a limit.'],
  ['Peak on ground', 'Most aircraft seen on the ground at once. A minimum, not a limit.'],
  ['Last updated', 'Newest source timestamp (UTC / SHJ)'],
];

function SourceCell({ r }) {
  return (
    <Stack direction="row" spacing={0.5} sx={{ flexWrap: 'wrap', rowGap: 0.5 }}>
      <Tooltip title="Stands">
        <span>
          <SourceChip source={r.stands_source} basis={r.stands_basis} />
        </span>
      </Tooltip>
      {r.arrivals_source !== r.stands_source && (
        <Tooltip title="Arrivals per hour">
          <span>
            <SourceChip source={r.arrivals_source} basis={r.arrivals_basis} />
          </span>
        </Tooltip>
      )}
    </Stack>
  );
}

export default function CapacityTable({ rows, canEdit, selected, onSelect, onEdit }) {
  return (
    <Paper>
      <TableContainer>
        <Table size="small" stickyHeader sx={{ tableLayout: 'auto', '& th, & td': { px: 1, py: 0.75, fontSize: 13 }, '& th': { lineHeight: 1.2, verticalAlign: 'bottom' }, '& td:nth-of-type(2)': { minWidth: 110, maxWidth: 170 } }}>
          <TableHead>
            <TableRow>
              {HEAD.map(([h, tip]) => (
                <TableCell key={h} sx={{ whiteSpace: 'normal' }}>
                  {tip ? (
                    <Tooltip title={tip}>
                      <span>{h}</span>
                    </Tooltip>
                  ) : (
                    h
                  )}
                </TableCell>
              ))}
              {canEdit && <TableCell />}
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow
                key={r.airport}
                hover
                selected={selected === r.airport}
                onClick={() => onSelect(r.airport)}
                sx={{ cursor: 'pointer' }}
              >
                <TableCell>
                  <Stack direction="row" spacing={0.5} sx={{ alignItems: 'center' }}>
                    <Typography variant="subtitle2">{r.airport}</Typography>
                    {r.is_hub && <Chip size="small" variant="outlined" label="hub" />}
                  </Stack>
                </TableCell>
                <TableCell>{r.name}</TableCell>
                <TableCell>{lowerBound(r.stands_total, r.stands_source)}</TableCell>
                <TableCell>
                  {dash(r.occupied_stands)}
                  {r.occupied_without_known_departure > 0 && (
                    <Tooltip
                      title={`${r.occupied_without_known_departure} with no known departure`}
                    >
                      <Typography component="span" variant="caption" sx={{ color: 'warning.main' }}>
                        {' '}
                        ({r.occupied_without_known_departure}?)
                      </Typography>
                    </Tooltip>
                  )}
                </TableCell>
                <TableCell sx={{ color: r.available_stands < 0 ? 'error.main' : undefined }}>
                  {dash(r.available_stands)}
                </TableCell>
                <TableCell sx={{ whiteSpace: 'nowrap' }}>
                  {r.diverted_inbound > 0 ? (
                    <Tooltip title={`${r.diverted_inbound_flights}${r.diverted_inbound_first_eta ? `, first due ${String(r.diverted_inbound_first_eta).slice(11, 16)}Z` : ''}`}>
                      <span>
                        <b>{r.diverted_inbound}</b>
                        {r.available_after_diverted != null && (
                          <span style={{ color: r.available_after_diverted < 0 ? 'var(--exceeded)' : undefined }}> → {r.available_after_diverted} free</span>
                        )}
                      </span>
                    </Tooltip>
                  ) : '–'}
                </TableCell>
                <TableCell>{lowerBound(r.arrivals_per_hr, r.arrivals_source)}</TableCell>
                <TableCell>{dash(r.projected_arrivals)}</TableCell>
                <TableCell
                  sx={{ color: r.remaining_arrival_capacity < 0 ? 'error.main' : undefined }}
                >
                  {dash(r.remaining_arrival_capacity)}
                </TableCell>
                <TableCell>
                  <SourceCell r={r} />
                </TableCell>
                <TableCell>{r.history_sample_n}</TableCell>
                <TableCell>{dash(r.history_peak_arrivals_per_hr)}</TableCell>
                <TableCell>{dash(r.history_peak_ground)}</TableCell>
                <TableCell sx={{ whiteSpace: 'nowrap' }}>
                  <Typography variant="caption">{fmtZL(ms(r.last_updated_utc))}</Typography>
                </TableCell>
                {canEdit && (
                  <TableCell>
                    <Tooltip title="Set assumed capacity">
                      <IconButton
                        size="small"
                        aria-label={`Set capacity for ${r.airport}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          onEdit(r);
                        }}
                      >
                        <EditIcon fontSize="small" />
                      </IconButton>
                    </Tooltip>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
      <Box sx={{ p: 1.5 }}>
        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {'≥'} marks a figure taken from history: the most the airport has been seen to handle, not
          its limit. A dash means unknown. Occupancy is derived from Air Arabia movements, not
          verified real-time data.
        </Typography>
      </Box>
    </Paper>
  );
}
