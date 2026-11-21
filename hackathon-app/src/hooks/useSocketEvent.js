import { useEffect, useRef } from 'react';
import { socket } from '@/services/socket';

// Listen to a socket event for the lifetime of a component:
//   useSocketEvent('notification', (payload) => toast(payload.text));
export function useSocketEvent(type, handler) {
  const ref = useRef(handler);
  useEffect(() => {
    ref.current = handler;
  });
  useEffect(() => socket.subscribe(type, (p) => ref.current(p)), [type]);
}
