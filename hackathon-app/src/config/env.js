// Foooh! API (login + all operational data). Server build uses the same-origin proxy '/ops-api'
// (nginx -> api:8000), so the browser never makes a cross-origin (CORS) call.
export const OPS_API_URL = import.meta.env.VITE_OPS_API_URL ?? 'http://localhost:8000';
export const API_URL = import.meta.env.VITE_API_URL ?? ''; // base for relative calls; ops calls use OPS_API_URL
