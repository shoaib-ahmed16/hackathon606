import { createSlice } from '@reduxjs/toolkit';

const socketSlice = createSlice({
  name: 'socket',
  initialState: { status: 'disconnected' },
  reducers: { setSocketStatus: (state, { payload }) => void (state.status = payload) },
});

export const { setSocketStatus } = socketSlice.actions;
export const selectSocketStatus = (s) => s.socket.status;
export default socketSlice.reducer;
