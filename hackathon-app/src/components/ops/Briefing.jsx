import { Box, Button, Chip, Paper, Stack, Typography } from '@mui/material';
import { useAppDispatch } from '@/app/hooks';
import { useGetBriefingQuery } from '@/features/ops/opsApi';
import { markSeen } from '@/features/ops/opsSlice';
import { iso, ms } from '@/features/ops/helpers';
import { fmtZ } from '@/features/ops/time';
import { useNow } from '@/hooks/useNow';

// What changed since the operator last looked, from the case timeline (decisions, status changes, diversions, comments).
export default function Briefing({ d }) {
  const dispatch = useAppDispatch();
  const now = useNow();
  const since = d.ops.lastSeenAt;
  const { data } = useGetBriefingQuery(
    { ...d.ctx, since: since ?? undefined },
    { skip: !d.ctx.case_id, pollingInterval: 15000 },
  );
  const items = data?.items ?? [];
  return (
    <Paper
      sx={{ p: 2, borderLeft: 4, borderColor: 'info.main' }}
      data-src="v_case_timeline since last_seen"
    >
      <Stack direction="row" sx={{ alignItems: 'center', gap: 1, flexWrap: 'wrap' }}>
        <Chip size="small" color="info" label="Briefing" />
        <Typography variant="subtitle1">
          {since ? `Since you last looked at ${fmtZ(ms(since))}` : 'Latest activity on this case'}
        </Typography>
        {data?.new_recommendations > 0 && (
          <Chip
            size="small"
            variant="outlined"
            label={`${data.new_recommendations} engine recommendation updates`}
          />
        )}
        <Box sx={{ flex: 1 }} />
        <Button size="small" onClick={() => dispatch(markSeen(iso(now)))}>
          Mark as seen
        </Button>
      </Stack>
      <Stack spacing={0.5} sx={{ mt: 1 }}>
        {items.length === 0 && (
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            Nothing new.
          </Typography>
        )}
        {items.map((i, k) => (
          <Stack key={k} direction="row" spacing={1.5}>
            <Typography
              variant="caption"
              sx={{ width: 52, fontFamily: 'monospace', color: 'text.secondary' }}
            >
              {fmtZ(ms(i.occurred_at))}
            </Typography>
            <Typography variant="body2" sx={{ flex: 1 }}>
              {i.summary}
              {i.actor ? ` (${i.actor})` : ''}
            </Typography>
          </Stack>
        ))}
      </Stack>
    </Paper>
  );
}
