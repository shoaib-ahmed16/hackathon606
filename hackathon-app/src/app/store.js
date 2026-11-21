import { configureStore } from '@reduxjs/toolkit';
import { setupListeners } from '@reduxjs/toolkit/query';
import { api } from './api';
import authReducer from '@/features/auth/authSlice';
import uiReducer from '@/features/ui/uiSlice';
import opsReducer from '@/features/ops/opsSlice';

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
    middleware: (getDefault) => getDefault().concat(api.middleware),
  });

export const store = makeStore();

setupListeners(store.dispatch); // refetchOnFocus / refetchOnReconnect
