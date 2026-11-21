import { Stack, Typography } from '@mui/material';
import { APP_NAME } from '@/config/brand';
import { useAppSelector } from '@/app/hooks';

// The mark: wind sweeping fog away. Blue tile in the dark theme, white tile in the light theme (both from the team's logo sheet).
// Files: public/logo-dark.png, public/logo-light.png (512 px, rounded), public/favicon.png (the blue one works on any browser theme).
export function LogoMark({ size = 28 }) {
  const dark = useAppSelector((s) => s.ui.mode) === 'dark';
  return <img src={dark ? '/logo-dark.png' : '/logo-light.png'} width={size} height={size} alt={`${APP_NAME} logo`} style={{ display: 'block' }} />;
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
