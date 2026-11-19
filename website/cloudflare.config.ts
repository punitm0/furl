import { defineConfig } from "cf/config";

// The Furl website: a static Astro build served as an assets-only Worker on getfurl.app.
// Deploy: `npm run build && npx cf deploy ./dist` (see README).
export default defineConfig({
  accountId: "a3f7125b1104e2f3b6cf1612eb224333",
  worker: {
    name: "furl-website",
    compatibilityDate: "2026-11-18",
    domains: ["getfurl.app", "www.getfurl.app"],
    workersDev: false,
    assets: {
      htmlHandling: "auto-trailing-slash",
      // Serves dist/404.html (src/pages/404.astro) with a 404 status for unknown paths.
      notFoundHandling: "404-page",
    },
  },
});
