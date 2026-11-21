import { createSlice } from '@reduxjs/toolkit';

const read = (k, fallback) => {
  try {
    return localStorage.getItem(k) ?? fallback;
  } catch {
    return fallback;
  }
};
const save = (k, v) => {
  try {
    localStorage.setItem(k, v);
  } catch {
    /* ignore */
  }
};

const uiSlice = createSlice({
  name: 'ui',
  initialState: {
    mode: read('mode', 'dark'), // 'light' | 'dark'
    sidebarCollapsed: read('sidebarCollapsed', 'false') === 'true', // desktop mini mode
    sidebarOpen: false, // mobile drawer
  },
  reducers: {
    toggleMode: (state) => {
      state.mode = state.mode === 'dark' ? 'light' : 'dark';
      save('mode', state.mode);
    },
    toggleSidebarCollapsed: (state) => {
      state.sidebarCollapsed = !state.sidebarCollapsed;
      save('sidebarCollapsed', String(state.sidebarCollapsed));
    },
    setSidebarOpen: (state, { payload }) => {
      state.sidebarOpen = payload;
    },
  },
});

export const { toggleMode, toggleSidebarCollapsed, setSidebarOpen } = uiSlice.actions;
export const selectMode = (s) => s.ui.mode;
export const selectSidebarCollapsed = (s) => s.ui.sidebarCollapsed;
export const selectSidebarOpen = (s) => s.ui.sidebarOpen;
export default uiSlice.reducer;
