import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import dualmark from "@dualmark/astro";

// Static site: `npm run build` writes plain HTML/CSS/JS to dist/.
// `site` is the planned domain; change it here if the domain changes (canonical URLs, sitemap).
export default defineConfig({
  site: "https://getfurl.app",
  integrations: [
    sitemap(),
    // Markdown twins for AI agents (dualmark.dev): /index.md, /guides.md and /guides/<id>.md.
    // llms.txt and llms-full.txt come from src/pages/ instead, so they can list every page and guide.
    dualmark({
      siteUrl: "https://getfurl.app",
      collections: { guides: { converter: "docs", route: "guides", slugStrategy: "single" } },
      staticPages: [
        {
          pattern: "/",
          // Keep the text inline: dualmark copies this function into a generated route, so it can't use outer variables.
          render: () => `# Furl

> Get your Mac's space back. Without the guesswork.

Furl is a free, open-source macOS app that frees disk space. It finds caches, merged git worktrees, app leftovers, duplicates, large files and leftover dev servers, explains why each one is safe, and uses the Trash by default so it can be undone. The few actions that delete for good are marked and never selected for you. Your files, file names and paths never leave your Mac.

- Download: https://github.com/punitm0/furl/releases/latest/download/Furl.dmg
- First launch (not notarized yet): https://getfurl.app/install/
- Privacy, everything Furl sends: https://getfurl.app/privacy/
- Guides: https://getfurl.app/guides.md
- Source code: https://github.com/punitm0/furl
- Index for AI assistants: https://getfurl.app/llms.txt
`,
        },
      ],
      llmsTxt: { enabled: false },
      // The site is static files on Cloudflare, so the Link header comes from public/_headers instead.
      middleware: { injectLinkHeader: false },
    }),
  ],
});
