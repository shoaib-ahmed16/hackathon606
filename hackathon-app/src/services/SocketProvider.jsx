import { useEffect } from 'react';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { selectIsAuthed } from '@/features/auth/authSlice';
import { setSocketStatus } from '@/features/socket/socketSlice';
import { WS_URL } from '@/config/env';
import { socket } from './socket';

// Connects while logged in, disconnects on logout. Mount once (main.jsx).
export default function SocketProvider({ children }) {
  const dispatch = useAppDispatch();
  const token = useAppSelector((s) => s.auth.token);
  const authed = useAppSelector(selectIsAuthed);

  useEffect(() => socket.onStatus((s) => dispatch(setSocketStatus(s))), [dispatch]);

  useEffect(() => {
    if (!authed) return;
    socket.connect(WS_URL, token);
    return () => socket.disconnect();
  }, [authed, token]);

  return children;
}
