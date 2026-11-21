# FOO: brand sheet

## Name
**FOO**. The product name chosen by the team. Short, one word, easy to say on a call or put on a door sign.
Not yet checked for trademark or domain availability. Do that before any public launch.

## Tagline and one-liners
- **Tagline:** Disruption control for airline operations.
- **One line:** FOO turns the disruption "firefighter" group chat into one shared decision room, where the AI prepares the facts
  and options and people stay responsible for every decision.
- **Three proof points:** every affected flight ordered by how soon a decision is needed; crew legality, fuel and alternates on
  one screen; a full audit trail of who decided what and why.

## Logo
An aircraft climbing out of fog: a white aircraft silhouette over two fading fog bands, on a deep-to-sky blue tile. (An earlier runway version read as a warning triangle at small sizes, so it was dropped.)
- Files: `hackathon-app/public/favicon.svg` (also the app icon) and `hackathon-app/src/components/Logo.jsx` (`LogoMark`, `Logo`).
- Use the mark alone at small sizes (favicon, collapsed sidebar); use mark plus the word "FOO" elsewhere.
- Keep clear space of at least a quarter of the mark's width. Do not recolour, stretch or add effects.

## Colour
| Use | Colour |
|---|---|
| Logo tile, dark end | `#0c4a6e` |
| Logo tile, light end / app primary | `#0284c7` |
| Dark-mode primary | `#38bdf8` |
| Tile gradient mid-tone | `#0369a1` |
| Aircraft and fog bands | white |

Status colours (green, amber, red) are reserved for operational meaning and are never used for decoration.

## Where the name lives in the code
`hackathon-app/src/config/brand.js` (name, tagline, description), `index.html` (tab title and description), `Logo.jsx`,
`favicon.svg`, the login screen, and the API title in `backend/app/main.py`.
Internal identifiers (database name, schema `fogops`, `FOGOPS_DSN`) are deliberately unchanged so existing databases and
deployments keep working. The demo password `FogOps@2026` is also unchanged because existing demo accounts use it.
