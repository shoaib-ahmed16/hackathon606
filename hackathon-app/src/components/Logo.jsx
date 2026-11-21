import { Stack, Typography } from '@mui/material';
import { APP_NAME } from '@/config/brand';

// The FOOH mark: an aircraft climbing out of a fog bank, its contrail dissolving into the mist. Keep in sync with public/favicon.svg.
export function LogoMark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 48 48" role="img" aria-label={`${APP_NAME} logo`}>
      <defs>
      <linearGradient id="foo-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#0c4a6e"/><stop offset="1" stopColor="#0284c7"/></linearGradient>
      <linearGradient id="foo-trail" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stopColor="#7dd3fc" stopOpacity="0"/><stop offset=".5" stopColor="#7dd3fc" stopOpacity=".85"/><stop offset="1" stopColor="#f0f9ff"/></linearGradient>
      <filter id="foo-mist" x="-30%" y="-80%" width="160%" height="260%"><feGaussianBlur stdDeviation="2.1"/></filter>
      <clipPath id="foo-tile"><rect width="48" height="48" rx="11"/></clipPath>
      </defs>
      <g clipPath="url(#foo-tile)">
      <rect width="48" height="48" fill="url(#foo-bg)"/>
      <path d="M10.5 21C13 9.5 28 5.5 38 12" fill="none" stroke="#bae6fd" strokeWidth="1.5" strokeLinecap="round" opacity=".5"/>
      {/* fog behind: a dense bank that thickens toward the ground */}
      <g fill="#fff" filter="url(#foo-mist)">
      <ellipse cx="14" cy="32" rx="15" ry="3.6" opacity=".34"/>
      <ellipse cx="36" cy="35" rx="16" ry="3.8" opacity=".42"/>
      <ellipse cx="22" cy="41" rx="24" ry="5" opacity=".7"/>
      <ellipse cx="24" cy="49" rx="30" ry="6" opacity=".95"/>
      </g>
      {/* contrail cutting through the bank */}
      <path d="M2 37C13.5 36.6 25 31.4 33.6 23.4L35.1 25.4C26 34 14 39.6 2 39.4Z" fill="url(#foo-trail)"/>
      {/* a thin veil of fog in front of the trail's start: the aircraft is crossing it */}
      <g fill="#fff" filter="url(#foo-mist)"><ellipse cx="9" cy="37.5" rx="12" ry="2.6" opacity=".55"/></g>
      {/* aircraft climbing out */}
      <g transform="translate(31.5 17) rotate(-24)">
      <path d="M-12.5 -1.1L-13 -5.8L-9.6 -5.8L-6.2 -1.1Z" fill="#fff"/>
      <path d="M-12.6 -1.2L8.2 -1.7C12.3 -1.6 14.6 -0.6 14.6 0.4C14.6 1.4 12.3 2.2 8.2 2.3L-12.6 1.4Z" fill="#fff"/>
      <path d="M-2.4 1.4L-9 9.2L-5.4 9.2L4.8 1.7Z" fill="#fff"/>
      <ellipse cx="-3.6" cy="5.4" rx="2.2" ry="1.35" fill="#e0f2fe"/>
      </g>
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
