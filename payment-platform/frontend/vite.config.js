import { defineConfig } from 'vite'

export default defineConfig({
  server: {
    allowedHosts: ['app.pearlpay.example', 'localhost'],
    host: '0.0.0.0',
    port: 5173,
  },
})
