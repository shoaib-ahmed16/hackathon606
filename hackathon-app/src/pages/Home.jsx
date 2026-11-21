import { Box, Paper, Typography, useTheme } from '@mui/material';
import { BarChart } from '@mui/x-charts/BarChart';
import ArticleIcon from '@mui/icons-material/Article';
import BoltIcon from '@mui/icons-material/Bolt';
import PeopleIcon from '@mui/icons-material/People';
import { useAppSelector } from '@/app/hooks';
import { selectUser } from '@/features/auth/authSlice';
import { useList } from '@/features/posts/postsApi';
import PageHeader from '@/components/PageHeader';
import StatCard from '@/components/StatCard';

// Dashboard starter: KPI cards + chart. Replace the sample data with real queries.
const weekly = { days: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'], values: [12, 19, 8, 24, 16] };

export default function Home() {
  const theme = useTheme();
  const user = useAppSelector(selectUser);
  const { data } = useList({ limit: 1 }); // `total` comes back with any list call

  return (
    <Box sx={{ display: 'grid', gap: 2 }}>
      <PageHeader title={`Welcome, ${user?.name ?? ''} 👋`} subtitle="Your dashboard starter" />
      <Box
        sx={{ display: 'grid', gap: 2, gridTemplateColumns: { xs: '1fr', sm: 'repeat(3, 1fr)' } }}
      >
        <StatCard label="Total posts" value={data?.total ?? '-'} icon={<ArticleIcon />} />
        <StatCard label="Active users" value="1,284" icon={<PeopleIcon />} />
        <StatCard label="Events today" value="342" icon={<BoltIcon />} />
      </Box>
      <Paper sx={{ p: 2.5 }}>
        <Typography variant="h6" sx={{ mb: 1 }}>
          Activity this week
        </Typography>
        {/* dark mode / text follow the theme; series colors come from `colors` (theme tokens) */}
        <BarChart
          height={280}
          colors={[theme.palette.primary.main]}
          xAxis={[{ scaleType: 'band', data: weekly.days }]}
          series={[{ data: weekly.values, label: 'Events' }]}
        />
      </Paper>
    </Box>
  );
}
