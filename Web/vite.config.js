import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Запити на /api проксуються на бекенд, тому CORS у режимі розробки не потрібен.
// Інший бекенд: VITE_PROXY_TARGET=http://host:port npm run dev
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: process.env.VITE_PROXY_TARGET || 'http://localhost:8080',
        changeOrigin: true
      }
    }
  }
});
