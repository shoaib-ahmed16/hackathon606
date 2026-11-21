// 🔤 ALL FONT SETTINGS LIVE HERE (family, sizes, weights). Sizes are in px.
// Use variants in code: <Typography variant="h4">, "body1", "body2", "caption"... never hardcode fontSize.
export const fontFamily = '"IBM Plex Sans", "Segoe UI", system-ui, sans-serif';

const h = (size, lineHeight, weight = 600) => ({
  fontSize: `${size / 16}rem`,
  lineHeight,
  fontWeight: weight,
  letterSpacing: '-0.01em',
});

export const typography = {
  fontFamily,
  fontSize: 14, // base size (body)
  fontWeightRegular: 400,
  fontWeightMedium: 500,
  fontWeightBold: 600,

  // Headings -- compact scale
  h1: h(30, 1.2, 700),
  h2: h(26, 1.25, 700),
  h3: h(22, 1.3),
  h4: h(20, 1.35), // page titles
  h5: h(17, 1.4), // section titles
  h6: h(15, 1.4), // card titles / app name

  subtitle1: { fontSize: '0.9375rem', lineHeight: 1.5, fontWeight: 500 },
  subtitle2: { fontSize: '0.8125rem', lineHeight: 1.5, fontWeight: 600 },

  body1: { fontSize: '0.875rem', lineHeight: 1.55 }, // 14px default text
  body2: { fontSize: '0.8125rem', lineHeight: 1.5 }, // 13px secondary text

  button: { fontSize: '0.8125rem', fontWeight: 600, textTransform: 'none' },
  caption: { fontSize: '0.75rem', lineHeight: 1.4 },
  overline: { fontSize: '0.6875rem', lineHeight: 1.4, fontWeight: 600, letterSpacing: '0.08em' },
};
