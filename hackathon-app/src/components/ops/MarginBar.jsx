import { Box, LinearProgress, Typography } from '@mui/material';
import { fmtDur } from '@/features/ops/time';

// Remaining FDP margin: bar is full at 180+ min, empty at 0, error color when negative.
export default function MarginBar({ margin }) {
  const color = margin < 0 ? 'error' : margin < 60 ? 'warning' : 'success';
  return (
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, minWidth: 130 }}>
      <LinearProgress
        variant="determinate"
        color={color}
        value={Math.max(0, Math.min(100, (margin / 180) * 100))}
        sx={{ flex: 1, height: 6, borderRadius: 3 }}
      />
      <Typography variant="caption" sx={{ width: 58, textAlign: 'right', color: `${color}.main` }}>
        {fmtDur(margin)}
      </Typography>
    </Box>
  );
}
