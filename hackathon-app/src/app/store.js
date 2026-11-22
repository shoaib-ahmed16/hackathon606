import { configureStore, createListenerMiddleware } from '@reduxjs/toolkit';
import { setupListeners } from '@reduxjs/toolkit/query';
import { api } from './api';
import authReducer from '@/features/auth/authSlice';
import uiReducer from '@/features/ui/uiSlice';
import opsReducer, { refreshed } from '@/features/ops/opsSlice';

// An action (station update, approval, crew change ...) already refetches everything the moment it succeeds (its tag invalidates the
// reads). The background worker then recomputes legality, advice and deadlines a second or two later, so refresh again at +1.5 s and +5 s
// instead of waiting for the timer. Each refresh re-arms the one timer. A newer action cancels the older follow-ups.
const afterAction = createListenerMiddleware();
afterAction.startListening({
  predicate: (action) => typeof action.type === 'string' && action.type.startsWith(`${api.reducerPath}/executeMutation/fulfilled`),
  effect: async (_action, lapi) => {
    lapi.cancelActiveListeners();
    lapi.dispatch(refreshed(Date.now()));
    for (const wait of [1500, 3500]) {
      await lapi.delay(wait);
      lapi.dispatch(api.util.invalidateTags(['Ops']));
      lapi.dispatch(refreshed(Date.now()));
    }
  },
});

// Factory so tests can create a fresh store. The app uses the `store` singleton below.
export const makeStore = (preloadedState) =>
  configureStore({
    reducer: {
      [api.reducerPath]: api.reducer,
      auth: authReducer,
      ui: uiReducer,
      ops: opsReducer,
      // add new slices here
    },
    preloadedState,
    middleware: (getDefault) => getDefault().prepend(afterAction.middleware).concat(api.middleware),
  });

export const store = makeStore();

setupListeners(store.dispatch); // refetchOnFocus / refetchOnReconnect
