import { Paper, Stack, Typography } from '@mui/material';

// KPI tile: <StatCard label="Total posts" value={251} icon={<ArticleIcon />} />
export default function StatCard({ label, value, icon }) {
  return (
    <Paper sx={{ p: 2.5 }}>
      <Stack direction="row" sx={{ alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <Typography variant="body2" sx={{ color: 'text.secondary' }}>
            {label}
          </Typography>
          <Typography variant="h4">{value}</Typography>
        </div>
        {icon && <Stack sx={{ color: 'primary.main' }}>{icon}</Stack>}
      </Stack>
    </Paper>
  );
}
