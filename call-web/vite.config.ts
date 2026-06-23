import { defineConfig } from "vite";

// Static SPA for the guest call client. matrix-js-sdk is bundled (not CDN).
export default defineConfig({
  build: {
    target: "es2020",
    outDir: "dist",
  },
  server: {
    // For local dev: proxy /api to the provisioner backend.
    proxy: {
      "/api": "http://localhost:8090",
    },
  },
});
