---
name: add-page
description: Add a new page/screen (protected or public) with route and sidebar/top menu entry. Use for dashboards, detail pages, settings, forms that are not full CRUD.
---

# Add a page

1. Create `src/pages/<Name>.jsx` (default export). Title: `<Typography variant="h4">`. Layout with `Stack`/`Box sx={{...}}`, `Paper` for cards.
2. Data: use RTK Query hooks from a `features/<x>/<x>Api.js` (see `add-crud-resource` or `features/realtime/realtimeApi.js`). Handle `isLoading` (`<Loader />`), `isError` (`<Alert severity="error">` + retry), and empty states.
3. Route: in `src/routes/index.jsx` add `const Name = lazy(() => import('@/pages/Name'));`
   - private page -> inside the `<ProtectedRoute>` / `<MainLayout>` group
   - public page (like login) -> next to `/login`
4. Menu: add `{ label, to, icon }` to `src/config/navigation.jsx` (shows in both layouts). Skip for non-menu pages.
5. Client-only state shared across pages -> `features/<x>/<x>Slice.js` and register in `app/store.js`.
6. `npm run check`.
