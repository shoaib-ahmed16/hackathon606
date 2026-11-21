import { Button, IconButton, Stack, Tooltip, Typography } from '@mui/material';
import DarkModeIcon from '@mui/icons-material/DarkMode';
import LightModeIcon from '@mui/icons-material/LightMode';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { selectUser } from '@/features/auth/authSlice';
import { useSignOut } from '@/features/auth/useSignOut';
import { selectMode, toggleMode } from '@/features/ui/uiSlice';

export default function UserMenu({ showLogout = true }) {
  const dispatch = useAppDispatch();
  const signOut = useSignOut();
  const user = useAppSelector(selectUser);
  const mode = useAppSelector(selectMode);

  return (
    <Stack direction="row" spacing={0.5} sx={{ alignItems: 'center' }}>
      <Tooltip title="Toggle dark mode">
        <IconButton onClick={() => dispatch(toggleMode())}>
          {mode === 'dark' ? <LightModeIcon /> : <DarkModeIcon />}
        </IconButton>
      </Tooltip>
      {user && (
        <Typography
          variant="body2"
          color="text.secondary"
          sx={{ display: { xs: 'none', sm: 'block' }, px: 1 }}
        >
          {user.name}
        </Typography>
      )}
      {showLogout && <Button onClick={signOut}>Logout</Button>}
    </Stack>
  );
}
