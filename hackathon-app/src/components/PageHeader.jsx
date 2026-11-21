import { Stack, Typography } from '@mui/material';

// Consistent page title row: <PageHeader title="Orders" subtitle="..." actions={<Button>New</Button>} />
export default function PageHeader({ title, subtitle, actions }) {
  return (
    <Stack
      direction="row"
      spacing={2}
      sx={{ alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', rowGap: 1 }}
    >
      <div>
        <Typography variant="h4">{title}</Typography>
        {subtitle && (
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            {subtitle}
          </Typography>
        )}
      </div>
      {actions && (
        <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
          {actions}
        </Stack>
      )}
    </Stack>
  );
}
