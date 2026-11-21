import { Box, Stack, Typography } from '@mui/material';
import { useNow } from '@/hooks/useNow';
import { fmtZ } from '@/features/ops/time';

// Crew duty ribbon: sign-in -> legal end -> +3h commander discretion. Marks: now, projected landing, legal end.
export default function Ribbon({ signIn, legal, disc, proj, compact = false }) {
  const now = useNow();
  if (!signIn || !legal)
    return (
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>
        No duty timeline
      </Typography>
    );
  const end = disc ?? legal + 3 * 3600000;
  const span = end - signIn;
  const p = (t) => Math.max(0, Math.min(100, ((t - signIn) / span) * 100));
  const mark = (t, color, title) => (
    <Box
      title={title}
      sx={{ position: 'absolute', left: `${p(t)}%`, top: -3, bottom: -3, width: 2, bgcolor: color }}
    />
  );
  return (
    <Box>
      <Box
        sx={{
          position: 'relative',
          height: 12,
          borderRadius: 1,
          bgcolor: 'action.hover',
          overflow: 'visible',
          my: 0.5,
        }}
      >
        <Box
          sx={{
            position: 'absolute',
            inset: 0,
            width: `${p(now)}%`,
            bgcolor: 'success.main',
            opacity: 0.45,
            borderRadius: 1,
          }}
        />
        <Box
          sx={{
            position: 'absolute',
            top: 0,
            bottom: 0,
            left: `${p(legal)}%`,
            right: 0,
            borderRadius: 1,
            backgroundImage:
              'repeating-linear-gradient(45deg, transparent 0 4px, rgba(244,67,54,.35) 4px 8px)',
          }}
        />
        {mark(now, 'info.main', `Now ${fmtZ(now)}`)}
        {proj && mark(proj, 'primary.main', `Projected landing ${fmtZ(proj)}`)}
        {mark(legal, 'error.main', `Legal end ${fmtZ(legal)}`)}
      </Box>
      {!compact && (
        <Stack direction="row" spacing={1.5} sx={{ flexWrap: 'wrap' }}>
          <Typography variant="caption">Sign-in {fmtZ(signIn)}</Typography>
          {proj && (
            <Typography variant="caption" sx={{ color: 'primary.main' }}>
              Lands {fmtZ(proj)}
            </Typography>
          )}
          <Typography variant="caption" sx={{ color: 'error.main' }}>
            Legal end {fmtZ(legal)}
          </Typography>
          <Typography variant="caption" sx={{ color: 'text.secondary' }}>
            Discretion to {fmtZ(end)}
          </Typography>
        </Stack>
      )}
    </Box>
  );
}
