FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install

COPY . .
RUN echo "import { defineConfig } from 'vite'\nexport default defineConfig({\n  server: {\n    allowedHosts: ['pearlpay.pearlservices.co.uk', 'app.pearlpay.example', 'localhost'],\n    host: '0.0.0.0',\n    port: 5173,\n  },\n})" > vite.config.js

EXPOSE 5173
CMD ["npm", "run", "dev"]
