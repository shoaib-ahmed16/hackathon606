import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'node:path';

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { '@': path.resolve(import.meta.dirname, 'src') } },
  server: {
    port: 3000,
    open: true,
    // CORS problems with the backend? Uncomment, then set VITE_API_URL=/api in .env
    // proxy: { '/api': { target: 'https://your-backend.example.com', changeOrigin: true, rewrite: (p) => p.replace(/^\/api/, '') } },
  },
});
