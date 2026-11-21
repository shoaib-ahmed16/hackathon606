---
name: backend-integration
description: Integrate the real backend into this app -- base URL/env, auth (login/signup/token/refresh), CRUD endpoints from an API spec (OpenAPI/Swagger/Postman/curl examples), error format, pagination, file upload, CORS/proxy, websockets. Use at hackathon start, when the API contract changes, or whenever asked to "connect/integrate the API".
---

# Backend integration

Everything server-related goes through **one RTK Query api** (`src/app/api.js`). Backend-specific details live in only these places, so integration is a handful of edits:

| What                                             | File                                                                                   |
| ------------------------------------------------ | -------------------------------------------------------------------------------------- |
| Base URL, WS URL                                 | `.env` + `.env.example` (`VITE_API_URL`, `VITE_WS_URL`) -> read in `src/config/env.js` |
| Auth header / 401 handling / refresh             | `src/app/api.js` (`prepareHeaders`, `baseQueryWithAuth`)                               |
| Login / signup / me endpoints + response mapping | `src/features/auth/authApi.js` (`toSession`)                                           |
| Resource endpoints                               | `src/features/<x>/<x>Api.js` via `createCrudApi`                                       |
| List shape, paging params, verbs                 | `src/app/createCrudApi.js`                                                             |
| Socket protocol                                  | `src/services/socket.js`                                                               |

The demo backend is dummyjson.com (login `emilys` / `emilyspass`; writes are simulated).

## Procedure

1. **Get the contract.** Ask for (or find) an OpenAPI/Swagger URL, Postman collection, or 2-3 real curl examples with responses. Do not guess field names -- `curl` the endpoints yourself when a base URL is given and read real responses.
2. **Environment**: set `VITE_API_URL` (and `VITE_WS_URL`); keep `.env.example` in sync (`.env` is git-ignored). Restart `npm run dev`.
3. **CORS**: if the browser console shows CORS errors, add to `vite.config.js`: `server: { proxy: { '/api': { target: 'https://backend-host', changeOrigin: true } } }` and set `VITE_API_URL=/api`. For production, the backend must allow the origin (or deploy behind the same domain).
4. **Auth** (`authApi.js`): set `url`s and bodies; `identifier` is username OR email -- map to whatever the backend expects. Make `toSession` return `{ token, user: { id, username, email, name } }`. Signup auto-logs-in when a token is returned, otherwise redirects to Login. Add a `me` query if the backend has `GET /me` and call it on app start.
   - Token as cookie instead of bearer? Set `credentials: 'include'` in `fetchBaseQuery` and drop the header.
   - Refresh token: in `baseQueryWithAuth`, on 401 call the refresh endpoint once, `dispatch(setCredentials(...))`, retry the original request; logout if refresh fails (RTK Query docs: "Automatic re-authorization").
5. **Resources**: for each entity add `createCrudApi({ name, path, addPath?, listKey? })`. Adapt in `createCrudApi.js` once: list envelope -> `{ items, total }`, paging params (`limit/skip` vs `page/pageSize` vs cursors), `PUT` vs `PATCH`, id field if not `id` (change the `providesTags`/`invalidatesTags` mapping).
   - OpenAPI available? Generate one `createCrudApi` per REST collection; hand-write only unusual endpoints with `api.injectEndpoints`.
6. **Non-CRUD endpoints**: `api.injectEndpoints({ endpoints: (build) => ({ ... }) })`, with `providesTags` / `invalidatesTags` so lists refresh. Reuse tag names from `createCrudApi` (the `name`).
7. **File upload**: `body: formData` (do NOT set Content-Type; the browser adds the boundary).
8. **Errors**: normalize in `src/utils/getErrorMessage.js` to the backend's error shape (e.g. `err.data.errors[0].message`). UI always shows `getErrorMessage(e)`; mutations use `.unwrap()` in try/catch + toast.
9. **Realtime**: confirm the WS URL, auth method (query token / first message / cookie) and message envelope with the backend team; adapt `socket.js` only. See the `realtime-websocket` skill.
10. **Verify end to end**: log in, exercise create/edit/delete on one resource, check the Network tab for request/response shapes and status codes, test a wrong password and a 401 (token expiry), then `npm run check`.

## Don'ts

- No `fetch`/`axios` calls inside components -- always RTK Query.
- Don't scatter base URLs or tokens; no secrets in `VITE_*` vars (they ship to the browser).
- Don't edit generated cache behaviour per page; fix it in `createCrudApi.js`.
