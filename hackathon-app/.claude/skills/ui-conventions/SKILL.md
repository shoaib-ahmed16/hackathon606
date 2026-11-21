---
name: ui-conventions
description: Styling rules for this app -- central theme (colors, typography), MUI 9 sx usage, dark mode, layouts. Use whenever writing or changing any UI, or when asked to change colors/fonts/spacing/branding.
---

# UI conventions

**Change the look in ONE place**

- Colors: `src/theme/palette.js` (`brand`, `brandDark`, `lightSurface`, `darkSurface`).
- Fonts and sizes: `src/theme/typography.js` (family via `@fontsource-variable/inter`, h1-h6, body1/2, caption...).
- Radius, component defaults (Button, TextField small, Table small, Tooltip non-interactive): `src/theme/index.js`.

**In components**

- Use variants, not sizes: `variant="h4"` (page title), `h5` (section), `h6` (card title), `body1` (text), `body2` (secondary), `caption`.
- Use theme tokens: `color="primary"`, `sx={{ color: 'text.secondary', bgcolor: 'background.paper', borderColor: 'divider' }}`. Never hex values.
- MUI 9: NO system props on Box/Typography/Stack. `<Box sx={{ display:'flex', gap:2, p:2 }}>`. (`direction`/`spacing` on Stack are fine.)
- Spacing via `sx` numbers (8px units). `Grid` in MUI 9: `<Grid container><Grid size={{ xs:12, md:6 }}>`.
- Icons: `@mui/icons-material/<Name>` (default imports, one per file).
- Buttons: `variant="contained"` for the single primary action, default text buttons otherwise, `color="error"` for destructive.
- Everything must look right in light AND dark mode -- test both (toggle in the header), and in both layouts (sidebar / top menu).

**Layouts**: `components/layout/` (`SidebarLayout`, `TopbarLayout`, `MainLayout` picks one from Redux `ui.layout`). Menu items come from `config/navigation.jsx`.
