import { NavLink, Outlet } from 'react-router-dom';
import {
  AppBar,
  Box,
  Divider,
  Drawer,
  IconButton,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Toolbar,
  Tooltip,
} from '@mui/material';
import MenuIcon from '@mui/icons-material/Menu';
import LogoutIcon from '@mui/icons-material/Logout';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import {
  selectSidebarCollapsed,
  selectSidebarOpen,
  setSidebarOpen,
  toggleSidebarCollapsed,
} from '@/features/ui/uiSlice';
import { useSignOut } from '@/features/auth/useSignOut';
import { navItems } from '@/config/navigation';
import Logo from '@/components/Logo';
import UserMenu from './UserMenu';

const WIDTH = 240;
const WIDTH_COLLAPSED = 68;

export default function SidebarLayout() {
  const dispatch = useAppDispatch();
  const signOut = useSignOut();
  const open = useAppSelector(selectSidebarOpen);
  const collapsed = useAppSelector(selectSidebarCollapsed);
  const close = () => dispatch(setSidebarOpen(false));
  const width = collapsed ? WIDTH_COLLAPSED : WIDTH;

  // mini = icons only (desktop collapsed). Mobile drawer is always full.
  const renderContent = (mini) => (
    <Box sx={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <Toolbar sx={{ justifyContent: mini ? 'center' : 'flex-start' }}>
        <Logo iconOnly={mini} />
      </Toolbar>
      <List sx={{ px: 1 }}>
        {navItems.map((i) => (
          <Tooltip key={i.to} title={mini ? i.label : ''} placement="right">
            <ListItemButton
              component={NavLink}
              to={i.to}
              end={i.end}
              onClick={close}
              sx={{
                borderRadius: 2,
                mb: 0.5,
                justifyContent: mini ? 'center' : 'flex-start',
                '&.active': {
                  bgcolor: 'action.selected',
                  color: 'primary.main',
                  '& .MuiListItemIcon-root': { color: 'primary.main' },
                },
              }}
            >
              <ListItemIcon sx={{ minWidth: mini ? 0 : 40, justifyContent: 'center' }}>
                {i.icon}
              </ListItemIcon>
              {!mini && <ListItemText primary={i.label} />}
            </ListItemButton>
          </Tooltip>
        ))}
      </List>
      <Box sx={{ flexGrow: 1 }} />
      <Divider />
      <List sx={{ px: 1 }}>
        <Tooltip title={mini ? 'Logout' : ''} placement="right">
          <ListItemButton
            onClick={signOut}
            sx={{ borderRadius: 2, justifyContent: mini ? 'center' : 'flex-start' }}
          >
            <ListItemIcon sx={{ minWidth: mini ? 0 : 40, justifyContent: 'center' }}>
              <LogoutIcon />
            </ListItemIcon>
            {!mini && <ListItemText primary="Logout" />}
          </ListItemButton>
        </Tooltip>
      </List>
    </Box>
  );

  const transition = (t) =>
    t.transitions.create('width', { duration: t.transitions.duration.shorter });

  return (
    <Box sx={{ display: 'flex', minHeight: '100vh' }}>
      <Box component="nav" sx={{ width: { md: width }, flexShrink: { md: 0 }, transition }}>
        {/* mobile drawer */}
        <Drawer
          variant="temporary"
          open={open}
          onClose={close}
          sx={{ display: { xs: 'block', md: 'none' }, '& .MuiDrawer-paper': { width: WIDTH } }}
        >
          {renderContent(false)}
        </Drawer>
        {/* desktop permanent (collapsible) */}
        <Drawer
          variant="permanent"
          open
          sx={{
            display: { xs: 'none', md: 'block' },
            '& .MuiDrawer-paper': {
              width,
              boxSizing: 'border-box',
              overflowX: 'hidden',
              transition,
            },
          }}
        >
          {renderContent(collapsed)}
        </Drawer>
      </Box>

      <Box sx={{ flex: 1, minWidth: 0 }}>
        <AppBar
          position="sticky"
          sx={{ borderBottom: 1, borderColor: 'divider', bgcolor: 'background.paper' }}
        >
          <Toolbar>
            {/* mobile: open drawer */}
            <IconButton
              edge="start"
              sx={{ display: { md: 'none' }, mr: 1 }}
              onClick={() => dispatch(setSidebarOpen(true))}
            >
              <MenuIcon />
            </IconButton>
            {/* desktop: collapse / expand */}
            <Tooltip title={collapsed ? 'Expand menu' : 'Collapse menu'}>
              <IconButton
                edge="start"
                sx={{ display: { xs: 'none', md: 'inline-flex' }, mr: 1 }}
                onClick={() => dispatch(toggleSidebarCollapsed())}
              >
                <MenuIcon />
              </IconButton>
            </Tooltip>
            <Box sx={{ flexGrow: 1 }} />
            <UserMenu showLogout={false} />
          </Toolbar>
        </AppBar>
        <Box component="main" sx={{ p: 3 }}>
          <Outlet />
        </Box>
      </Box>
    </Box>
  );
}
