import { defineConfig } from 'vite'
export default defineConfig({
  server: {
    allowedHosts: ['pearlpay.pearlservices.co.uk', 'app.pearlpay.example', 'localhost'],
    host: '0.0.0.0',
    port: 5173,
  },
})
