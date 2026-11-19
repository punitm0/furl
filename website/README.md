# Furl website

Astro static site. `npm run build` writes plain HTML, CSS and a little JS to `dist/`, ready for any static host.

```
npm install
npm run dev       # http://localhost:4321
npm run build     # → dist/
npm run check     # type and template checks
```

## Layout

- `src/site.config.ts`: everything to fill in before launch (see below).
- `src/pages/index.astro`: the page, assembled from `src/components/*.astro`.
- `src/layouts/Base.astro`: `<head>`, fonts, global CSS.
- `src/styles/global.css`: all styles (desktop first, phone layout below 720px).
- `src/scripts/`: client-side behaviour: menu, pay-what-you-like chips, share button, Windows waitlist.
- `src/content/guides/*.md`: the guides (one Markdown file each; frontmatter schema in `src/content.config.ts`). Pages: `/guides/` and `/guides/<file-name>/`; the first three by `order` also show on the home page.
- `public/guides/*.svg`: guide cover images, 1200×630 (designed on the Furl Redesign canvas, "Website guides: cover images").
- `public/favicon.svg`

## Before launch: `src/site.config.ts`

- `downloadUrl`: the .dmg link (used for $0, and for every amount until `checkoutUrl` is set).
- `checkoutUrl`: pay-what-you-like checkout page; `{amount}` is replaced with the chosen amount (see `buildCheckoutUrl` in `src/scripts/pricing.ts`).
- `githubUrl`: the repository URL (also drives the Changelog and Report a problem links).
- `siteUrl`: canonical page URL, shared by the mobile "Send it to your Mac" button. Also set `site` in `astro.config.mjs`.
- `waitlistUrl`: form endpoint for the Windows waitlist (POST with one field, `email`). Until set, the form says the waitlist isn't open yet.
- `stats`: keep `null` (the band isn't rendered) until there are real users; totals come from every install (anonymous, always on; see the privacy page).
