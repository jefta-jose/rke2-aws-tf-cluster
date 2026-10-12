import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Static build only; nginx serves dist/ and proxies /api/* to the services in-cluster.
export default defineConfig({
  plugins: [react()],
})
