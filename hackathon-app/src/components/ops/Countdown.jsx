import { Typography } from '@mui/material';
import { useNow } from '@/hooks/useNow';
import { cdText, cdTone, fmtZL } from '@/features/ops/time';

// Ticking countdown to a UTC time. <Countdown at={ms} /> ; `big` for the board; `showTime` appends "02:38Z / 06:38 SHJ".
export default function Countdown({ at, big = false, showTime = false, sx }) {
  const now = useNow();
  const tone = cdTone(at, now);
  return (
    <Typography
      component="span"
      variant={big ? 'h6' : 'body2'}
      sx={{ color: `${tone}.main`, fontWeight: 700, fontVariantNumeric: 'tabular-nums', ...sx }}
    >
      {cdText(at, now)}
      {showTime && at != null && (
        <Typography
          component="span"
          variant="caption"
          sx={{ color: 'text.secondary', fontWeight: 400, ml: 0.75 }}
        >
          {fmtZL(at)}
        </Typography>
      )}
    </Typography>
  );
}

// Time with both zones, no countdown: <TimeZL at={ms} />
export function TimeZL({ at }) {
  return <span style={{ fontVariantNumeric: 'tabular-nums' }}>{fmtZL(at)}</span>;
}
