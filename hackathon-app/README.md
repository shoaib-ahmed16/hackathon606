# Hackathon Boilerplate

React 19 · Vite · Redux Toolkit · RTK Query · React Router 7 · MUI 9 · react-hook-form + zod · lodash · date-fns · Docker

## Run

```bash
nvm use            # Node 24 (22.12+ also works)
npm install
cp .env.example .env
npm run dev        # http://localhost:3000
```

## Commands

|                             |                                           |
| --------------------------- | ----------------------------------------- |
| `npm run dev`               | dev server                                |
| `npm run check`             | lint + build (run before every push)      |
| `npm run format`            | Prettier                                  |
| `docker compose up --build` | production image on http://130.61.182.207:8080/ |

## What's included

Login / Sign up (username or email) · protected routes · sidebar **or** top layout (toggle, collapsible, mobile drawer) ·
light/dark theme · central theme (`src/theme/`: colors, typography) · generic CRUD generator (`createCrudApi`) with a full example page ·
WebSocket client + realtime demo · dashboard starter (stat cards + charts) · shared components · CI · Dockerfile.

## Structure

```
src/
  app/          store.js, api.js (single RTK Query api), createCrudApi.js, hooks.js
  features/     one folder per feature: xxxApi.js (server data) + xxxSlice.js (client state)
  pages/        route-level components
  routes/       route table + ProtectedRoute
  components/   layout/, PageHeader, StatCard, EmptyState, Loader, ConfirmDialog, Logo ...
  services/     socket.js (WebSocket), SocketProvider
  theme/        palette.js (ALL colors), typography.js (ALL fonts), index.js (MUI theme)
  config/       env.js, brand.js (app name + logo), navigation.jsx (menu)
```

## Add things fast

- **New CRUD resource**: `createCrudApi({ name, path })` -> copy `pages/Posts.jsx`. Then add a route (`routes/index.jsx`) and a menu item (`config/navigation.jsx`).
- **Client state**: slice in `features/<x>/` + one line in `app/store.js`.
- **Forms**: `useZodForm(schema)` + `<FormTextField control name label />` (see `pages/Signup.jsx`); rules in `utils/validators.js`.
- **Data helpers**: `lodash-es` (`sumBy`, `groupBy`, `orderBy`...), `utils/format.js` (dates, currency).
- **Change look**: colors `theme/palette.js`, fonts/sizes `theme/typography.js`, app name/logo `config/brand.js`.
- **Real backend**: see `.claude/skills/backend-integration/SKILL.md` (env, login mapping, CRUD shape, CORS).

## Rules of thumb

- Style only with MUI + theme tokens (`color="primary"`, `variant="h4"`). **MUI 9 removed system props**: `<Box sx={{ display: 'flex', p: 2 }}>`, not `<Box display="flex" p={2}>`.
- Mutations: `await fn(x).unwrap()` in try/catch + `toast` + `getErrorMessage`.
- Import with the alias: `import x from '@/utils/x'`.

## Docker

```bash
docker build -t hackathon-app --build-arg VITE_API_URL=https://api.example.com --build-arg VITE_WS_URL=wss://api.example.com/ws .
docker run -p 8080:80 hackathon-app
```

`VITE_*` values are baked in at build time (pass them as build args). Details: `.claude/skills/deploy/SKILL.md`.

## Claude Code skills

Project skills live in `.claude/skills/` and `CLAUDE.md` (shared via git): start with `build-feature`.
