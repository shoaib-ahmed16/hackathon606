import { createSlice } from '@reduxjs/toolkit';

const saved = (() => {
  try {
    return JSON.parse(localStorage.getItem('auth')) ?? {};
  } catch {
    return {};
  }
})();

const authSlice = createSlice({
  name: 'auth',
  initialState: { user: saved.user ?? null, token: saved.token ?? null },
  reducers: {
    setCredentials: (state, { payload }) => {
      state.user = payload.user;
      state.token = payload.token;
      localStorage.setItem('auth', JSON.stringify(payload));
    },
    logout: (state) => {
      state.user = null;
      state.token = null;
      localStorage.removeItem('auth');
    },
  },
});

export const { setCredentials, logout } = authSlice.actions;
export const selectUser = (s) => s.auth.user;
export const selectIsAuthed = (s) => Boolean(s.auth.token);
export default authSlice.reducer;
