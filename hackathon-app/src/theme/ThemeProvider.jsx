import { useMemo } from 'react';
import { ThemeProvider as MuiThemeProvider } from '@mui/material/styles';
import CssBaseline from '@mui/material/CssBaseline';
import { useAppSelector } from '@/app/hooks';
import { selectMode } from '@/features/ui/uiSlice';
import { buildTheme } from './index';

export default function ThemeProvider({ children }) {
  const mode = useAppSelector(selectMode);
  const theme = useMemo(() => buildTheme(mode), [mode]);
  return (
    <MuiThemeProvider theme={theme}>
      <CssBaseline />
      {children}
    </MuiThemeProvider>
  );
}
