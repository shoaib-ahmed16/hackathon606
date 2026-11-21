import { Stack, Typography } from '@mui/material';
import { APP_NAME, BrandIcon } from '@/config/brand';

// <Logo /> icon + name   |   <Logo iconOnly /> icon only (collapsed sidebar)
export default function Logo({ iconOnly = false }) {
  return (
    <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
      <BrandIcon color="primary" />
      {!iconOnly && (
        <Typography variant="h6" noWrap>
          {APP_NAME}
        </Typography>
      )}
    </Stack>
  );
}
