---
name: realtime-websocket
description: Work with WebSockets/realtime features -- live data, notifications, chat, presence. Use when asked for realtime updates, push events, or to change the socket server/auth.
---

# Realtime / WebSocket

- Client: `src/services/socket.js` (single instance `socket`): `connect/disconnect/send(type, payload)/subscribe(type, fn)/onStatus`. Auto-reconnect with backoff. Messages are JSON `{ type, payload }`.
- Lifecycle: `src/services/SocketProvider.jsx` connects while logged in (token sent as `?token=`), disconnects on logout. Status is in Redux: `selectSocketStatus`.
- Server URL: `VITE_WS_URL` (`.env`, documented in `.env.example`). Demo is a public echo server.

**Pattern A -- data in RTK Query cache (preferred for lists/feeds)**: see `features/realtime/realtimeApi.js`: `queryFn` returns initial data (or fetch via HTTP), `onCacheEntryAdded` subscribes with `socket.subscribe` and calls `updateCachedData`; unsubscribe after `cacheEntryRemoved`.

**Pattern B -- one-off events (toasts, badges)**: `useSocketEvent('notification', (payload) => toast(payload.text))` from `src/hooks/useSocketEvent.js`.

**Pattern C -- send**: `socket.send('type', payload)` returns false if not connected; wrap in a mutation `queryFn` (see `sendMessage`).

Changing the server protocol (auth via header/first message, different message envelope, socket.io): edit `socket.js` only; keep the public API the same.
Show connection state with `<Chip>` as in `pages/Realtime.jsx`.
