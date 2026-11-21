import { Stack, Typography } from '@mui/material';
import { APP_NAME } from '@/config/brand';

// The mark: the team's logo (wind sweeping past an aircraft; mark only, no lettering). Files: public/logo-512.png (square, rounded),
// public/logo-full.png (the original artwork, for slides). Keep in sync with public/favicon.png.
export function LogoMark({ size = 28 }) {
  return <img src="/logo-512.png" width={size} height={size} alt={`${APP_NAME} logo`} style={{ display: 'block', borderRadius: size * 0.22 }} />;
}

// The full logo (wind, aircraft, wordmark) on the same navy as the artwork, so it sits cleanly on both themes.
export function LogoFull({ height = 30, bar = false }) {
  return (
    <span style={{ display: 'inline-flex', background: '#0b1a31', borderRadius: Math.round(height * 0.28), overflow: 'hidden' }}>
      <img src={bar ? '/logo-bar.png' : '/logo-full.png'} alt={`${APP_NAME} logo`} style={{ display: 'block', height, width: 'auto' }} />
    </span>
  );
}

// <Logo /> mark + name   |   <Logo iconOnly /> mark only (collapsed sidebar)
export default function Logo({ iconOnly = false, size = 28 }) {
  return (
    <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
      <LogoMark size={size} />
      {!iconOnly && (
        <Typography variant="h6" noWrap sx={{ fontWeight: 700, letterSpacing: 0.2 }}>
          {APP_NAME}
        </Typography>
      )}
    </Stack>
  );
}
