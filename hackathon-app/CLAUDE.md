# Hackathon App

React 19 + Vite + Redux Toolkit + RTK Query + React Router 7 + MUI 9 (JavaScript, JSX). Node 24 (22.12+ works).

## Commands

- `npm run dev` -> http://localhost:3000
- `npm run check` (lint + build) -- run before finishing any task
- `npm run format` -- Prettier

## Architecture (read before coding)

- `src/app/api.js` -- the ONE RTK Query api (auth header, auto-logout on 401). Never call `createApi` elsewhere.
- `src/app/createCrudApi.js` -- generates list/get/add/update/delete hooks for a resource.
- `src/features/<name>/` -- `xxxApi.js` (server data) and `xxxSlice.js` (client-only state, register in `app/store.js`).
- `src/pages/` -- route components. Routes: `src/routes/index.jsx`. Menu: `src/config/navigation.jsx`.
- `src/config/brand.js` -- app name + logo icon (used by `components/Logo.jsx`, tab title is in `index.html`).
- `src/theme/` -- ALL colors (`palette.js`) and fonts/sizes (`typography.js`); `index.js` = MUI theme + component defaults.
- `src/services/socket.js` -- WebSocket client; `SocketProvider` connects while logged in.
- Backend-specific shaping (paths, field names) lives in `features/auth/authApi.js` and `createCrudApi` calls only.

## Rules

- No unit tests in this project (team decision, for speed). Verify with `npm run check` and by running the app (`verify-ui` skill). Don't add test files or test dependencies.

- Style ONLY with MUI + theme tokens. No hardcoded hex colors, no fontSize numbers: use `color="primary"`, `sx={{ bgcolor: 'background.paper' }}`, `<Typography variant="h4|h5|body1|body2|caption">`.
- MUI 9 removed system props: write `<Box sx={{ display: 'flex', p: 2 }}>`, never `<Box display="flex" p={2}>`.
- Mutations: `await fn(arg).unwrap()` in try/catch, then `toast.success/error(getErrorMessage(e))`.
- Use `useAppDispatch` / `useAppSelector` from `@/app/hooks`; import with the `@/` alias.
- Pages are lazy-loaded in the route table.
- Env vars start with `VITE_` and are read only in `src/config/env.js`. Update `.env.example` when adding one.

## Project skills (in `.claude/skills/`)

Ours: `build-feature` (start here), `add-crud-resource`, `add-page`, `forms`, `utils-helpers`, `redux-state`, `dashboard-charts`, `realtime-websocket`, `backend-integration`, `ui-conventions`, `verify-ui`, `team-workflow`, `deploy`.
Anthropic's (vendored from github.com/anthropics/skills, license in each folder):

- `frontend-design` -- for making a screen look distinctive/polished. Express any resulting look through `src/theme/*` and MUI, never Tailwind/raw CSS; `ui-conventions` rules win on conflicts.
- `webapp-testing` -- browser testing with Python Playwright (`pip install playwright && playwright install chromium`). Start the app with `scripts/with_server.py --server "npm run dev" --port 3000 -- python test.py`.

## Libraries already installed (don't re-implement)

`lodash-es` (arrays/objects/calcs), `date-fns` (dates), `zod` + `react-hook-form` (forms/validation), `@mui/x-charts` (charts), `react-hot-toast`. Helpers: `src/utils/{lodash,format,validators}.js`.

## Shared UI blocks (reuse, don't rewrite)

`PageHeader`, `StatCard`, `EmptyState`, `Loader`, `ConfirmDialog`, `PasswordField`, `Logo`, `form/FormTextField` + `form/useZodForm`; hooks `useDebounce`, `useSocketEvent`.

## Deploy

Docker: `docker build --build-arg VITE_API_URL=... --build-arg VITE_WS_URL=... -t app .` (nginx serves the SPA). See `deploy` skill.
