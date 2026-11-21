import { createTheme } from '@mui/material/styles';
import { typography } from './typography';
import { brand, brandDark, lightSurface, darkSurface } from './palette';

// Build a theme for 'light' | 'dark'. Colors -> palette.js, everything else (shape, fonts,
// default component props/styles) -> here.
export const buildTheme = (mode = 'light') => {
  const dark = mode === 'dark';
  const s = dark ? darkSurface : lightSurface;

  return createTheme({
    palette: {
      mode,
      primary: { main: dark ? brandDark.primary : brand.primary },
      secondary: { main: dark ? brandDark.secondary : brand.secondary },
      success: { main: brand.success },
      warning: { main: brand.warning },
      error: { main: brand.error },
      info: { main: brand.info },
      background: { default: s.background, paper: s.paper },
      text: { primary: s.text, secondary: s.textSecondary },
      divider: s.divider,
    },
    shape: { borderRadius: 10 },
    typography,
    components: {
      // popups never intercept clicks on the controls underneath
      MuiTooltip: { defaultProps: { disableInteractive: true } },
      MuiTable: { defaultProps: { size: 'small' } },
      MuiButton: { defaultProps: { disableElevation: true } },
      MuiTextField: { defaultProps: { size: 'small', fullWidth: true } },
      MuiPaper: { styleOverrides: { root: { backgroundImage: 'none' } } },
      MuiAppBar: { defaultProps: { elevation: 0, color: 'inherit' } },
    },
  });
};
