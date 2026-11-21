import { Stack, Typography } from '@mui/material';
import { APP_NAME } from '@/config/brand';

// The FOO mark: an aircraft climbing out of fog bands. Keep in sync with public/favicon.svg.
export function LogoMark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" role="img" aria-label={`${APP_NAME} logo`}>
      <defs>
        <linearGradient id="cw-grad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#0c4a6e" />
          <stop offset="1" stopColor="#0284c7" />
        </linearGradient>
      </defs>
      <rect width="48" height="48" rx="11" fill="url(#cw-grad)" />
      <path d="M24 7c1.5 0 2.3 1.3 2.3 3.2v9.6l11.7 7v3.2l-11.7-3.4v7.4l3.3 2.6v2.4L24 36.4l-5.6 1.6v-2.4l3.3-2.6v-7.4L10 30v-3.2l11.7-7v-9.6C21.7 8.3 22.5 7 24 7z" fill="#fff" />
      <g stroke="#fff" strokeWidth="2.6" strokeLinecap="round" fill="none">
        <path d="M10 41h28" opacity=".55" />
        <path d="M15 45h18" opacity=".3" />
      </g>
    </svg>
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
