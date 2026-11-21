---
name: add-crud-resource
description: Add a new server resource with full CRUD (list, search/pagination, create, edit, delete) -- API hooks, page, form dialog, route and menu entry. Use when asked to add users/products/orders/etc. or "CRUD for X".
---

# Add a CRUD resource

Reference implementation: `src/features/posts/*` + `src/pages/Posts.jsx`. Copy its structure.

1. **API** -- create `src/features/<name>/<name>Api.js`:
   ```js
   import { createCrudApi } from '@/app/createCrudApi';
   export const { useList, useGet, useAdd, useUpdate, useRemove } = createCrudApi({
     name: 'Product', // unique, singular, PascalCase (cache tag)
     path: '/products',
     listKey: 'products', // key holding the array in the list response; omit if API returns a plain array
     // addPath: '/products/add' // only if create URL differs
   });
   ```
   If two resources are imported in one page, rename on import: `import { useList as useProducts } ...` -- or export aliased names like `postsApi.js` does.
   If the backend uses other verbs (PATCH) or other paging params, change `createCrudApi.js` once.
2. **Form dialog** -- copy `PostFormDialog.jsx`, change the fields. Render with a `key` so the form resets.
3. **Page** -- copy `pages/Posts.jsx`: table columns, search, pagination (`limit`/`skip`), `ConfirmDialog` for delete, toasts. Adjust the search param name for the backend.
4. **Route + menu** -- lazy import and `<Route path="products">` in `src/routes/index.jsx`; entry with an MUI icon in `src/config/navigation.jsx`.
5. Run `npm run check`.

Do not add `tagTypes` manually: `createCrudApi` registers the tag.
