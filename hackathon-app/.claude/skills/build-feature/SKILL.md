---
name: build-feature
description: Fast path to ship a whole feature end-to-end (data, UI, route, menu) from a one-line idea. Use first for any "build/add X feature" request; it picks and chains the other project skills.
---

# Build a feature fast

1. **Clarify in one line** what the user sees and does. Don't over-plan; hackathon speed wins.
2. **Pick the data source**
   - Backend endpoint exists -> `add-crud-resource` (REST collection) or `api.injectEndpoints` (custom). See `backend-integration`.
   - Backend not ready -> mock (see below) and keep the hook names so swapping to the real API is a one-file change.
   - Client-only state -> `redux-state`.
   - Live updates -> `realtime-websocket`.
3. **Reuse UI blocks already in the repo** instead of writing new ones:
   `PageHeader`, `StatCard`, `EmptyState`, `Loader`, `ConfirmDialog`, `PasswordField`, `Logo`, MUI `Table` + `TablePagination` (see `pages/Posts.jsx`), `BarChart/LineChart` (`dashboard-charts`), forms (`forms`), helpers (`utils-helpers`).
4. **Wire it**: page -> lazy route -> menu entry (`add-page`).
5. **Polish only what is visible**: loading, error + retry, empty state, success/error toast. Light + dark.
6. **Verify**: `verify-ui`, then `npm run check`.

## Mocking when the backend is not ready

In `features/<x>/<x>Api.js` use `queryFn` with local data:

```js
getThings: build.query({ queryFn: async () => ({ data: { items: MOCK, total: MOCK.length } }) }),
```

or use dummyjson.com (`/products`, `/todos`, `/users`, `/carts`, `/recipes`... full CRUD, no key) by setting `path` in `createCrudApi`.
