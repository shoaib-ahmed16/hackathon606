# FOOH!: brand sheet

## Name
**FOOH!**. The product name chosen by the team. Short, one word, easy to say on a call or put on a door sign.
Not yet checked for trademark or domain availability. Do that before any public launch.

## Tagline and one-liners
- **Tagline:** Disruption control for airline operations.
- **One line:** FOOH! turns the disruption "firefighter" group chat into one shared decision room, where the AI prepares the facts
  and options and people stay responsible for every decision.
- **Three proof points:** every affected flight ordered by how soon a decision is needed; crew legality, fuel and alternates on
  one screen; a full audit trail of who decided what and why.

## Logo
The team's logo (`image.png` in the project root): wind swirls sweeping fog away behind a climbing aircraft, with the wordmark "FOOH!" in brushed-silver letters on deep navy. The AI-tool watermark in the original corner was painted out.
- Files in `hackathon-app/public/`: `logo-full.png` (wide logo with the wordmark, edges faded into the navy; top bar and login), `logo-bar.png` (tighter crop for the top bar), `logo-source.png` (cleaned full square artwork, for slides and posters), `logo-512.png` (mark without the lettering, rounded; app icon), `favicon.png`, `apple-touch-icon.png`.
- `LogoFull` in `src/components/Logo.jsx` shows the wide logo on the same navy as the artwork. Use the lettering-free mark only at small sizes (tab icon).
- Keep clear space of at least a quarter of the logo's height. Do not recolour, stretch or add effects.

## Colour
| Use | Colour |
|---|---|
| Logo tile, dark end | `#0c4a6e` |
| Logo tile, light end / app primary | `#0284c7` |
| Dark-mode primary | `#38bdf8` |
| Tile gradient mid-tone | `#0369a1` |
| Logo background navy | `#0b1a31` |
| Logo silver and ice blue | `#c9d6df` / `#9fd3dc` |

Status colours (green, amber, red) are reserved for operational meaning and are never used for decoration.

## Where the name lives in the code
`hackathon-app/src/config/brand.js` (name, tagline, description), `index.html` (tab title and description), `Logo.jsx`,
`favicon.svg`, the login screen, and the API title in `backend/app/main.py`.
Internal identifiers (database name, schema `fogops`, `FOGOPS_DSN`) are deliberately unchanged so existing databases and
deployments keep working. The demo password `FogOps@2026` is also unchanged because existing demo accounts use it.
