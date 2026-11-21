import DashboardIcon from '@mui/icons-material/Dashboard';
import FlightLandIcon from '@mui/icons-material/FlightLand';
import NotificationsActiveIcon from '@mui/icons-material/NotificationsActive';
import HistoryIcon from '@mui/icons-material/History';
import FactCheckIcon from '@mui/icons-material/FactCheck';

// Single source of truth for menu items -- add a page here and both layouts show it.
// The role lenses (OCC, Dispatch, Crew Control, Station, Recovery) live inside the Console.
export const navItems = [
  { label: 'Console', to: '/', icon: <DashboardIcon />, end: true },
  { label: 'Flights', to: '/flights', icon: <FlightLandIcon /> },
  { label: 'Audit trail', to: '/audit', icon: <HistoryIcon /> },
  { label: 'Alerts & data', to: '/alerts', icon: <NotificationsActiveIcon /> },
  { label: 'Reports', to: '/reports', icon: <FactCheckIcon /> },
];
