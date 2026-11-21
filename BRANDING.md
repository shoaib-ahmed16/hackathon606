# Foooh!: brand sheet

## Name
**Foooh!**. The product name chosen by the team. Short, one word, easy to say on a call or put on a door sign.
Not yet checked for trademark or domain availability. Do that before any public launch.

## Tagline and one-liners
- **Tagline:** Disruption control for airline operations.
- **One line:** Foooh! turns the disruption "firefighter" group chat into one shared decision room, where the AI prepares the facts
  and options and people stay responsible for every decision.
- **Three proof points:** every affected flight ordered by how soon a decision is needed; crew legality, fuel and alternates on
  one screen; a full audit trail of who decided what and why.

## Logo
Wind sweeping fog away: three wind gusts blowing past an amber flame-shaped drop, a spray of dots trailing off. It is the sound of the name ("Foooh!") drawn.
The mark has no lettering; the name is set next to it in text.
- Two versions, as on the team's logo sheet: **blue tile** for the dark theme and **white tile** for the light theme. The app switches between them with the theme (`LogoMark` in `src/components/Logo.jsx`).
- Files in `hackathon-app/public/`: `logo-dark.png` (blue), `logo-light.png` (white), `favicon.png` and `apple-touch-icon.png` (blue; it reads on any browser theme).
- Source images: `image copy 4.png` (blue, 2048 px) and the "device sizes" sheet `image.png` (white version, cropped and upscaled, so re-export it at full size if it is ever needed above 128 px).
- Keep clear space of at least a quarter of the mark's width. Do not recolour, stretch or add effects.

## Colour
| Use | Colour |
|---|---|
| Logo blue tile (gradient) | `#00aeef` to `#0093d0` |
| Logo amber flame | `#ffc044` |
| Logo wind, light version | `#00aeef` and `#0a84c6` |
| Dark-mode primary | `#38bdf8` |

Status colours (green, amber, red) are reserved for operational meaning and are never used for decoration.

## Where the name lives in the code
`hackathon-app/src/config/brand.js` (name, tagline, description), `index.html` (tab title and description), `Logo.jsx`,
`favicon.png`, the login screen, and the API title in `backend/app/main.py`.
Internal identifiers (database name, schema `fogops`, `FOGOPS_DSN`) are deliberately unchanged so existing databases and
deployments keep working. The demo password `FogOps@2026` is also unchanged because existing demo accounts use it.
