import { useMemo, useState } from 'react';
import {
  Box,
  Button,
  Chip,
  LinearProgress,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtDur, fmtZ, MIN } from '@/features/ops/time';
import { useNow } from '@/hooks/useNow';
import Countdown from '../Countdown';
import StatusChip from '../StatusChip';

const LANES = [
  ['act', 'Act now', 'under 15 min or passed'],
  ['soon', 'Decide soon', '15 to 45 min, or needs verifying'],
  ['mon', 'Monitoring', 'more than 45 min or no deadline'],
  ['done', 'Arrived / recovered', ''],
];
const CAP = 40;
const RISK = ['AT_RISK', 'EXCEEDED', 'DISCRETION_REQUIRED', 'VERIFICATION_REQUIRED'];

function FuelMeter({ f, fuelEnd }) {
  const now = useNow();
  if (['ON_BLOCKS', 'LANDED'].includes(f.status) || f.diverted_to)
    return <Meter label="Fuel" text="On ground" tone="default" pct={100} />;
  if (!['AIRBORNE', 'HOLDING', 'DIVERTING'].includes(f.status))
    return <Meter label="Fuel" text="-" tone="default" pct={0} />;
  if (fuelEnd == null) return <Meter label="Fuel" text="? verify" tone="warning" pct={0} dashed />;
  const m = Math.floor((fuelEnd - now) / MIN);
  return (
    <Meter
      label="Fuel"
      text={`${m} min*`}
      tone={m < 20 ? 'error' : m < 45 ? 'warning' : 'success'}
      pct={Math.max(4, Math.min(100, (m / 120) * 100))}
    />
  );
}
function Meter({ label, text, tone, pct, dashed }) {
  return (
    <Box
      data-src={
        label === 'Fuel'
          ? 'flight_fuel_estimate (quality labelled)'
          : 'v_flight_watch (binding crew)'
      }
    >
      <Stack direction="row" sx={{ justifyContent: 'space-between' }}>
        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {label}
        </Typography>
        <Typography
          variant="caption"
          sx={{ fontWeight: 700, color: tone === 'default' ? 'text.secondary' : `${tone}.main` }}
        >
          {text}
        </Typography>
      </Stack>
      <LinearProgress
        variant="determinate"
        value={pct}
        color={tone === 'default' ? 'inherit' : tone}
        sx={{ height: 6, borderRadius: 3, opacity: dashed ? 0.35 : 1 }}
      />
    </Box>
  );
}
function CrewMeter({ f }) {
  if (f.crew_margin_min == null)
    return <Meter label="Crew" text="no crew data" tone="warning" pct={0} dashed />;
  const m = f.crew_margin_min;
  const tone = m < 0 ? 'error' : m < 60 ? 'warning' : 'success';
  return (
    <Meter
      label="Crew"
      text={m < 0 ? 'Needs discretion' : m < 60 ? `${m} min margin` : fmtDur(m)}
      tone={tone}
      pct={Math.max(4, Math.min(100, (m / 240) * 100))}
    />
  );
}

function Row({ f, dl, fuelEnd, selected, onOpen }) {
  const rec = f.recommendation;
  const lvpBad = f.lvp_required && f.lvp_crew_ok === false;
  return (
    <Box
      role="option"
      aria-selected={selected}
      tabIndex={0}
      onClick={onOpen}
      onKeyDown={(e) => e.key === 'Enter' && onOpen()}
      data-id={f.flight_id}
      data-src="v_flight_watch"
      sx={{
        display: 'grid',
        gridTemplateColumns: { xs: '1fr 1fr', lg: '1.1fr 1.4fr 1fr 1fr 0.7fr 1.5fr 1fr' },
        gap: 1.5,
        alignItems: 'center',
        p: 1.25,
        borderRadius: 2,
        border: 1,
        borderColor: selected ? 'primary.main' : 'divider',
        cursor: 'pointer',
        '&:hover': { bgcolor: 'action.hover' },
      }}
    >
      <Box>
        <Typography variant="subtitle2">{f.flight_no}</Typography>
        <Typography variant="caption" sx={{ color: 'text.secondary', display: 'block' }}>
          {f.dep_iata} to {f.diverted_to ?? f.current_dest_iata}
        </Typography>
        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {f.registration ?? 'no tail'}
        </Typography>
      </Box>
      <Box>
        <StatusChip status={f.status} />
        <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
          {f.waiting_for
            ? `waiting: ${f.waiting_for.replaceAll('_', ' ').toLowerCase()}`
            : `ETA ${fmtZ(ms(f.eta_utc ?? f.sta_utc))}`}
          {!f.waiting_for && f.arr_delay_min > 0 ? ` (+${f.arr_delay_min}m)` : ''}
        </Typography>
        <Typography
          variant="caption"
          sx={{ color: f.data_age_min > 15 ? 'warning.main' : 'text.disabled' }}
        >
          {f.data_age_min != null ? `data ${f.data_age_min} min old` : 'no live feed'}
        </Typography>
      </Box>
      <FuelMeter f={f} fuelEnd={fuelEnd} />
      <CrewMeter f={f} />
      <Box>
        {f.lvp_required ? (
          <Chip
            size="small"
            color={lvpBad ? 'error' : f.lvp_crew_ok ? 'success' : 'warning'}
            label={lvpBad ? 'LVP ✕' : f.lvp_crew_ok ? 'LVP ✓' : 'LVP ?'}
          />
        ) : (
          <Typography variant="caption" sx={{ color: 'text.disabled' }}>
            -
          </Typography>
        )}
      </Box>
      <Box data-src="v_recommendation_options (rank 1)">
        {f.decision_status === 'PROPOSED' ? (
          <Chip size="small" color="warning" label={`Waiting for approval: ${f.last_decision}`} />
        ) : f.last_decision && ['APPROVED', 'EXECUTED'].includes(f.decision_status) ? (
          <Chip
            size="small"
            color="success"
            label={`${f.decision_status === 'EXECUTED' ? 'Done' : 'Approved'}: ${f.last_decision}${f.diverted_to ? ` ${f.diverted_to}` : ''}`}
          />
        ) : rec ? (
          <Chip
            size="small"
            color={
              rec === 'DIVERT' || rec === 'CREW_REPLACE'
                ? 'error'
                : rec === 'HOLD'
                  ? 'warning'
                  : 'info'
            }
            variant="outlined"
            label={`Engine: ${rec.replaceAll('_', ' ').toLowerCase()}${f.recommended_alternate ? ` ${f.recommended_alternate}` : ''}`}
          />
        ) : (
          <Typography variant="caption" sx={{ color: 'text.disabled' }}>
            no action
          </Typography>
        )}
      </Box>
      <Box sx={{ textAlign: { lg: 'right' } }} data-src="deadlines (computed)">
        {dl?.deadline_utc ? (
          <>
            <Countdown at={ms(dl.deadline_utc)} big />
            <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
              {fmtZ(ms(dl.deadline_utc))}
            </Typography>
          </>
        ) : dl ? (
          <Typography variant="caption" sx={{ color: 'warning.main' }}>
            Verify fuel
          </Typography>
        ) : (
          <Typography variant="caption" sx={{ color: 'text.disabled' }}>
            -
          </Typography>
        )}
      </Box>
    </Box>
  );
}

// OCC / Dispatch lens: flights in urgency lanes, with filters.
export default function BoardLens({ d, lens }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const minute = Math.floor(now / MIN);
  const [q, setQ] = useState('');
  const [chips, setChips] = useState([]);
  const [owner, setOwner] = useState('ALL');
  const [open, setOpen] = useState({});
  const dlBy = useMemo(
    () => Object.fromEntries(d.deadlines.map((x) => [x.flight_id, x])),
    [d.deadlines],
  );
  const fuelBy = useMemo(
    () =>
      Object.fromEntries(
        d.fuel.map((x) => [x.flight_id, ms(x.as_of_utc) + x.est_holding_endurance_min * MIN]),
      ),
    [d.fuel],
  );

  const FILTERS = {
    approval: ['Needs approval', (f) => f.decision_status === 'PROPOSED'],
    crew: ['Crew at risk', (f) => RISK.includes(f.crew_status)],
    lvp: ['No LVP', (f) => f.lvp_required && f.lvp_crew_ok === false],
    fuel: [
      'Fuel unverified',
      (f) => ['AIRBORNE', 'HOLDING', 'DIVERTING'].includes(f.status) && fuelBy[f.flight_id] == null,
    ],
    holding: ['Holding', (f) => f.is_holding],
    diverted: ['Diverted', (f) => Boolean(f.diverted_to)],
  };
  const owners = ['ALL', ...new Set(d.flights.map((f) => f.owner ?? f.owner_role).filter(Boolean))];

  const lanes = useMemo(() => {
    const t = q.trim().toLowerCase();
    const list = d.flights.filter(
      (f) =>
        (!t ||
          `${f.flight_no} ${f.registration} ${f.dep_iata} ${f.planned_arr_iata} ${f.diverted_to ?? ''} ${f.captain ?? ''}`
            .toLowerCase()
            .includes(t)) &&
        chips.every((c) => FILTERS[c][1](f)) &&
        (owner === 'ALL' || (f.owner ?? f.owner_role) === owner),
    );
    const laneOf = (f) => {
      if (['LANDED', 'ON_BLOCKS'].includes(f.status) && !f.diverted_to) return 'done';
      const dl = dlBy[f.flight_id];
      if (!dl) return 'mon';
      if (!dl.deadline_utc) return 'soon';
      const m = (ms(dl.deadline_utc) - minute * MIN) / MIN;
      return m < 15 ? 'act' : m <= 45 ? 'soon' : 'mon';
    };
    const key = (f) => ms(dlBy[f.flight_id]?.deadline_utc) ?? ms(f.eta_utc ?? f.sta_utc) ?? 0;
    const out = Object.fromEntries(LANES.map(([k]) => [k, []]));
    for (const f of list) out[laneOf(f)].push(f);
    for (const k in out) out[k].sort((a, b) => key(a) - key(b));
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d.flights, dlBy, fuelBy, q, chips, owner, minute]);

  const toggle = (k) => setChips((c) => (c.includes(k) ? c.filter((x) => x !== k) : [...c, k]));
  const total = d.flights.length;

  return (
    <Stack spacing={1.5}>
      <Paper sx={{ p: 1.5 }}>
        <Stack
          direction={{ xs: 'column', lg: 'row' }}
          spacing={1.5}
          sx={{ alignItems: { lg: 'center' } }}
        >
          <TextField
            size="small"
            label="Search flight, tail, airport, captain"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            sx={{ minWidth: 260 }}
          />
          <TextField
            select
            size="small"
            label="Owner"
            value={owner}
            onChange={(e) => setOwner(e.target.value)}
            sx={{ minWidth: 150 }}
          >
            {owners.map((o) => (
              <MenuItem key={o} value={o}>
                {o === 'ALL' ? 'All owners' : o}
              </MenuItem>
            ))}
          </TextField>
          <Stack direction="row" sx={{ gap: 0.75, flexWrap: 'wrap' }}>
            {Object.entries(FILTERS).map(([k, [label]]) => (
              <Chip
                key={k}
                size="small"
                label={`${label} (${d.flights.filter(FILTERS[k][1]).length})`}
                color={chips.includes(k) ? 'primary' : 'default'}
                variant={chips.includes(k) ? 'filled' : 'outlined'}
                onClick={() => toggle(k)}
              />
            ))}
            {(chips.length > 0 || q || owner !== 'ALL') && (
              <Button
                size="small"
                onClick={() => {
                  setChips([]);
                  setQ('');
                  setOwner('ALL');
                }}
              >
                Clear
              </Button>
            )}
          </Stack>
        </Stack>
      </Paper>
      {LANES.map(([k, name, sub]) => {
        if (lens === 'dispatch' && k === 'done') return null;
        const items = lanes[k];
        if (!items.length) return null;
        const collapsedDefault = k === 'done';
        const expanded = open[k] ?? !collapsedDefault;
        const shown = expanded ? items.slice(0, open[`${k}+`] ? items.length : CAP) : [];
        return (
          <Box key={k}>
            <Stack
              direction="row"
              spacing={1}
              sx={{
                alignItems: 'baseline',
                mb: 0.75,
                cursor: collapsedDefault ? 'pointer' : 'default',
              }}
              onClick={() => collapsedDefault && setOpen({ ...open, [k]: !expanded })}
            >
              <Typography
                variant="h6"
                sx={{
                  color:
                    k === 'act' ? 'error.main' : k === 'soon' ? 'warning.main' : 'text.primary',
                }}
              >
                {name}
              </Typography>
              <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                {sub ? `${sub} - ` : ''}
                {items.length} flight{items.length > 1 ? 's' : ''}
                {collapsedDefault ? (expanded ? ' (click to hide)' : ' (click to show)') : ''}
              </Typography>
            </Stack>
            <Stack spacing={0.75} role="listbox">
              {shown.map((f) => (
                <Row
                  key={f.flight_id}
                  f={f}
                  dl={dlBy[f.flight_id]}
                  fuelEnd={fuelBy[f.flight_id]}
                  selected={d.ops.selectedFlightId === f.flight_id}
                  onOpen={() => dispatch(selectFlight(f.flight_id))}
                />
              ))}
              {expanded && items.length > shown.length && (
                <Button size="small" onClick={() => setOpen({ ...open, [`${k}+`]: true })}>
                  Show {items.length - shown.length} more
                </Button>
              )}
            </Stack>
          </Box>
        );
      })}
      {Object.values(lanes).every((l) => !l.length) && (
        <Typography variant="body2" sx={{ color: 'text.secondary' }}>
          No flights match ({total} on this case).
        </Typography>
      )}
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        * Fuel values are estimates entered by dispatch or crew (quality is stored with each one). A
        dashed bar means not verified. It is never treated as safe.
      </Typography>
    </Stack>
  );
}
