---
name: dashboard-charts
description: Build dashboards -- KPI cards, bar/line/pie charts, tables -- with MUI X Charts (installed) and the existing StatCard. Use for analytics/overview/report screens.
---

# Dashboards & charts

Reference: `src/pages/Home.jsx`. Library: `@mui/x-charts` (dark mode follows the MUI theme, but series colors do NOT -- pass `colors`).

```jsx
import { BarChart } from '@mui/x-charts/BarChart';
import { LineChart } from '@mui/x-charts/LineChart';
import { PieChart } from '@mui/x-charts/PieChart';

<BarChart height={280} xAxis={[{ scaleType: 'band', data: labels }]} series={[{ data: values, label: 'Sales' }]} />
<LineChart height={280} xAxis={[{ scaleType: 'point', data: labels }]} series={[{ data: values, label: 'Users', area: true }]} />
<PieChart height={240} series={[{ data: [{ id: 0, value: 10, label: 'A' }, { id: 1, value: 20, label: 'B' }] }]} />
```

- Layout: CSS grid via `Box sx={{ display:'grid', gap:2, gridTemplateColumns:{ xs:'1fr', sm:'repeat(3,1fr)' } }}`; each chart in `<Paper sx={{ p: 2.5 }}>` with an `h6` title.
- KPI tiles: `StatCard label value icon`.
- Data: RTK Query hook -> map to arrays; guard `isLoading` (`Loader`) and empty (`EmptyState`) first. Always set `height`.
- Series colors: always pass `colors={[theme.palette.primary.main, theme.palette.secondary.main, ...]}` (`const theme = useTheme()`); never hex. Recolor the app via `src/theme/palette.js`.
- Need a data grid (sorting/filter/export)? `@mui/x-data-grid` -- install on demand.
