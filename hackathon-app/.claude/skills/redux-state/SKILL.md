---
name: redux-state
description: Add client-side (non-server) state with a Redux Toolkit slice -- UI state, wizard steps, cart, filters, preferences, persisted settings. Use when state is shared across components/pages and is not fetched from the API.
---

# Redux slice

Server data -> RTK Query (never copy it into slices). Client state -> slice.

1. `src/features/<name>/<name>Slice.js` (see `features/ui/uiSlice.js`, `features/auth/authSlice.js`):
   ```js
   import { createSlice } from '@reduxjs/toolkit';
   const slice = createSlice({
     name: 'cart',
     initialState: { items: [] },
     reducers: {
       added: (s, { payload }) => void s.items.push(payload),
       removed: (s, { payload: id }) => {
         s.items = s.items.filter((i) => i.id !== id);
       },
       cleared: (s) => {
         s.items = [];
       },
     },
   });
   export const { added, removed, cleared } = slice.actions;
   export const selectCartItems = (s) => s.cart.items;
   export default slice.reducer;
   ```
2. Register in `src/app/store.js`: `cart: cartReducer`.
3. Use: `const dispatch = useAppDispatch(); const items = useAppSelector(selectCartItems);` (from `@/app/hooks`).

- Persist across refresh: read/write `localStorage` in try/catch like `uiSlice.js`.
- Derived data -> selector functions next to the slice.
- State used by one component only -> `useState`, not Redux.
