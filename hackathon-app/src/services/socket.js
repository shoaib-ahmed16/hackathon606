/**
 * Tiny WebSocket client (no dependency): auto-reconnect with backoff, JSON messages shaped
 * { type, payload }, subscribe by type. Single shared instance: `import { socket } from '@/services/socket'`.
 *
 *   const off = socket.subscribe('chat', (payload) => ...);  off();
 *   socket.send('chat', { text: 'hi' });
 *
 * Prefer socket.io? `npm i socket.io-client` and keep this same connect/send/subscribe API.
 */
class SocketService {
  ws = null;
  url = null;
  token = null;
  retries = 0;
  timer = null;
  manualClose = false;
  status = 'disconnected'; // 'connecting' | 'connected' | 'disconnected'
  handlers = new Map(); // type -> Set<fn>
  statusHandlers = new Set();

  connect(url, token) {
    if (!url) return;
    this.url = url;
    this.token = token;
    this.manualClose = false;
    this.#open();
  }

  disconnect() {
    this.manualClose = true;
    clearTimeout(this.timer);
    this.ws?.close();
    this.ws = null;
    this.#setStatus('disconnected');
  }

  send(type, payload) {
    if (this.ws?.readyState !== WebSocket.OPEN) return false;
    this.ws.send(JSON.stringify({ type, payload }));
    return true;
  }

  subscribe(type, fn) {
    if (!this.handlers.has(type)) this.handlers.set(type, new Set());
    this.handlers.get(type).add(fn);
    return () => this.handlers.get(type)?.delete(fn);
  }

  onStatus(fn) {
    this.statusHandlers.add(fn);
    return () => this.statusHandlers.delete(fn);
  }

  #setStatus(s) {
    this.status = s;
    this.statusHandlers.forEach((fn) => fn(s));
  }

  #emit(type, payload) {
    this.handlers.get(type)?.forEach((fn) => fn(payload));
  }

  #open() {
    clearTimeout(this.timer);
    this.ws?.close();
    this.#setStatus('connecting');
    // Token goes in the query string (browsers can't set WS headers). Adapt to your server.
    const url = this.token ? `${this.url}?token=${encodeURIComponent(this.token)}` : this.url;
    const ws = new WebSocket(url);
    this.ws = ws;

    ws.onopen = () => {
      this.retries = 0;
      this.#setStatus('connected');
    };
    ws.onmessage = (e) => {
      try {
        const { type, payload } = JSON.parse(e.data);
        this.#emit(type, payload);
      } catch {
        this.#emit('raw', e.data); // non-JSON frame
      }
    };
    ws.onclose = () => {
      if (this.ws !== ws) return; // replaced by a newer socket
      this.#setStatus('disconnected');
      if (this.manualClose) return;
      const delay = Math.min(1000 * 2 ** this.retries++, 10000); // 1s,2s,4s... max 10s
      this.timer = setTimeout(() => this.#open(), delay);
    };
  }
}

export const socket = new SocketService();
