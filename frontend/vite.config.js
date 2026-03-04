import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', sourcemap: true },
  // Dev-only proxies (not used inside Docker — nginx handles routing there)
  server: {
    proxy: {
      '/graphql': 'http://localhost:4000',
      '/v1':      'http://localhost:4318',
    },
  },
});
