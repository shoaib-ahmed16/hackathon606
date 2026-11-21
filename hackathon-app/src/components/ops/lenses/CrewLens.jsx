import { useMemo, useState } from 'react';
import { Box, Button, Chip, Paper, Stack, Typography } from '@mui/material';
import { useAppDispatch } from '@/app/hooks';
import { selectFlight } from '@/features/ops/opsSlice';
import { ms } from '@/features/ops/helpers';
import { fmtZ } from '@/features/ops/time';
import Countdown from '../Countdown';
import Ribbon from '../Ribbon';
import StandbyDialog from '../StandbyDialog';
import StatusChip from '../StatusChip';

const ORDER = ['CP', 'FO', 'SO', 'CS', 'CC', 'SEC', 'EN'];

// Crew Control lens: who runs out of legality next (Q1). One row per duty, worst crew member first.
export default function CrewLens({ d }) {
  const dispatch = useAppDispatch();
  const [pick, setPick] = useState(null);
  const rows = useMemo(() => {
    const byDuty = new Map();
    for (const c of d.crew) {
      const cur = byDuty.get(c.duty_id);
      const worse =
        !cur ||
        (c.margin_min ?? 1e9) < (cur.margin_min ?? 1e9) ||
        ((c.margin_min ?? 1e9) === (cur.margin_min ?? 1e9) &&
          ORDER.indexOf(c.position_code) < ORDER.indexOf(cur.position_code));
      if (worse) byDuty.set(c.duty_id, { ...c, crewCount: (cur?.crewCount ?? 0) + 1 });
      else cur.crewCount += 1;
    }
    return [...byDuty.values()]
      .filter((c) => c.legal_end_utc)
      .sort((a, b) => ms(a.legal_end_utc) - ms(b.legal_end_utc));
  }, [d.crew]);

  return (
    <Stack
      spacing={1}
      data-src="v_crew_legality_ranking ORDER BY minutes_until_legal_end (this case's duties)"
    >
      <Typography variant="h6">
        Who runs out of legality next{' '}
        <Typography component="span" variant="caption" sx={{ color: 'text.secondary' }}>
          {rows.length} duties on this case, soonest first
        </Typography>
      </Typography>
      {rows.slice(0, 60).map((c) => {
        const flight = d.flights.find((f) => f.duty_id === c.duty_id);
        const m = c.margin_min;
        return (
          <Paper
            key={c.duty_id}
            variant="outlined"
            sx={{
              p: 1.5,
              display: 'grid',
              gridTemplateColumns: { xs: '1fr', lg: '1.3fr 1fr 2fr 0.9fr 1fr' },
              gap: 1.5,
              alignItems: 'center',
            }}
          >
            <Box>
              <Typography variant="subtitle2" noWrap>
                {c.duty_legs}
              </Typography>
              <Typography variant="caption" sx={{ color: 'text.secondary' }}>
                {c.position_code} {c.full_name}
                {c.crewCount > 1 ? ` + ${c.crewCount - 1} crew` : ''} - {c.legs_counted} sector(s) -
                max {c.max_fdp_hhmm}
              </Typography>
              {['CP', 'FO'].includes(c.position_code) && !c.lvp_qualified && (
                <Chip
                  size="small"
                  color="error"
                  label={`${c.position_code} not LVP`}
                  sx={{ ml: 0.5 }}
                />
              )}
            </Box>
            <Box>
              <Countdown at={ms(c.legal_end_utc)} big />
              <Typography variant="caption" sx={{ display: 'block', color: 'text.secondary' }}>
                {fmtZ(ms(c.legal_end_utc))} legal end
              </Typography>
            </Box>
            <Ribbon
              signIn={ms(c.sign_in_utc)}
              legal={ms(c.legal_end_utc)}
              disc={ms(c.discretion_end_utc)}
              proj={ms(c.projected_end_utc)}
              compact
            />
            <Box>
              <StatusChip status={c.status} />
              <Typography
                variant="caption"
                sx={{ display: 'block', color: m < 0 ? 'error.main' : 'text.secondary' }}
              >
                {m < 0 ? `${-m} min over` : `${m} min margin at landing`}
              </Typography>
            </Box>
            <Stack direction="row" spacing={0.5}>
              {flight && (
                <Button size="small" onClick={() => dispatch(selectFlight(flight.flight_id))}>
                  Open
                </Button>
              )}
              {flight && (
                <Button size="small" variant="outlined" onClick={() => setPick(c)}>
                  Find replacement
                </Button>
              )}
            </Stack>
          </Paper>
        );
      })}
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        Bars run from sign-in to the end of commander discretion. Green = time used, red line =
        legal end, blue = now, hatched = discretion zone (a captain decision). Crew types without
        approved FDP rules show as "Verify" and are never treated as legal.
      </Typography>
      {pick && <StandbyDialog d={d} row={pick} onClose={() => setPick(null)} />}
    </Stack>
  );
}
