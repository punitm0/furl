# Furl stats worker

Cloudflare Worker + D1 behind the "X TB freed by Furl users" counter on the website. (Resource names such as
`sweepmac-stats` and the `X-SweepMac-*` headers keep the project's earlier name for compatibility.)

- `POST /v1/report`: write-only. The app sends batches of events here at most once a day. Sending is always on
  (there's no setting), and the website's privacy page lists what is sent. A successful request returns `204`
  with no body.
- `GET /v1/totals`: sums only, plus an install count rounded down to its leading digit. It's public (CORS `*`)
  and edge-cached for 10 minutes. It returns `404` on `*.workers.dev`, where the edge cache does nothing and
  every request would read D1; use the custom domain.
- `GET /v1/support`: `{"checkoutUrl": "https://checkout.dodopayments.com/buy/pdt_…" | null}`, the Dodo Payments
  link for "pay what you like". The app stores it and checks again every 24 hours (6 while unset), so a shipped build picks up a new link without an
  update. Set it with `vars.DODO_CHECKOUT_URL` in `wrangler.jsonc` (not a secret) and redeploy. Only https links on
  `checkout.dodopayments.com` or `test.checkout.dodopayments.com` under `/buy/pdt_…` are served; anything else is
  `null`. Public (CORS `*`), `Cache-Control: max-age=300`, reads nothing from the request.

There are no admin, list or per-install endpoints. The database stores a random install UUID, the app version,
the event kind and category, byte, file and item counts, and a server-assigned UTC day. Per install it also
keeps the latest macOS major version, CPU architecture (`arm64` / `x86_64`, from the hardware) and whether
Full Disk Access is granted, overwritten on each report with no history (`install_env`). It stores no paths, file
names, usernames, hostnames or IPs. IPs are used only as a short-lived rate-limit key, and for the per-network
daily budget below, which stores a salted SHA-256 of the IP (IPv6: its /64), never the IP. The salt is random,
made fresh each UTC day, and making it deletes earlier days' salts and counters, so a hash can't be linked
across days. While the day lasts, someone with read access to the database could still brute-force an IPv4
hash, since the salt sits next to it; after the day both are gone.

## How counting stays correct

- Every event has a client-generated UUID, and `events` has the primary key `(install_id, event_id)`. Inserts
  use `INSERT OR IGNORE`, so a retried request is ignored and counts nothing.
- The triggers (latest version in `migrations/0003_poisoning_limits.sql`) update the `totals` table during each insert, inside the D1 batch
  (one transaction). `/v1/totals` then needs only one small read.
- An undo/restore is sent as `{kind: "reversal", reverses: <event id>}`. It subtracts exactly what the original
  added, and only if the original was counted and hasn't already been reversed. If a reversal arrives before
  its original, the original is cancelled when it lands.
- Abuse limits:
  - Strict schema: unknown fields, kinds or categories are rejected.
  - Per-event ceilings (4 TiB disk or compress, 256 GiB memory, 100,000 files or items). A request with anything larger is rejected.
  - Per-install daily caps, applied in SQL (256 GiB disk, 64 GiB compress, 256 GiB memory, 100,000 files compressed, 50,000 items
    cleaned; each at most 5% of the global ceilings below, so two installs can't use up a day). Anything over
    the cap that day is stored but adds nothing to the totals.
  - Body capped at 16 KB and 40 events.
  - Rate limits: 6 requests/min per install and 60 requests/min per IP.
  - Per-network daily budget (IPv4 address or IPv6 /64, keyed on the salted hash above): 200 reports and 10
    never-seen install ids per UTC day. Past either, the Worker answers `429` and writes nothing; the app keeps
    its events and tries again later.
  - Maturity: an install adds nothing to the public totals until it reports on a second UTC day. Then its
    earlier events that still stand are added in one go, and it joins the install count. Before that it may
    store at most 200 events; same-day reports past that get `429`, and the app sends them the next day. Maturity
    also needs room under that day's install ceiling (below); without it the install stays unmatured, adds
    nothing, and is delayed rather than lost. On a later day it may store one more batch while under the cap.
    Past the cap, a report gets through only if it will mature the install: the ceiling has room and the batch
    holds a disk, memory or compress event not stored before. Anything else (reversals only, retries) gets `429`.
  - Global daily growth ceiling on each public metric: 5 TiB disk, 2 TiB compress, 5 TiB memory, 5M files,
    2M items and 200 new installs per UTC day. A single event is clipped to what's left; a maturing install's
    backlog is added whole if it fits, otherwise dropped. Each event records what it actually added
    (`public_*`), so a reversal takes back exactly that. Under an attack the totals stop growing for the day
    instead of jumping.
  - An HMAC signature. This is only a speed bump, because the key ships in the app (see `src/hmac.ts`).

  What's left: someone with many IPs (or IPv6 /64s) can still add up to the daily ceiling each day, and enough
  traffic can use up the D1 Free plan's daily write quota (100,000 rows). The ceilings bound the first; the
  second needs Workers Paid or a Cloudflare WAF rate-limiting rule.

- Write cost (D1 bills every row written, including trigger writes). Each accepted report writes 2 rows
  (`install_env`, `ip_daily`) plus, per event: 3 for an install that hasn't matured; 6 for a counted disk,
  memory or compress event, 8 if it also carries items or files; 4 for a reversal. The first event of an install
  on a new day adds 1 (`daily_usage`), the first event anywhere on a new day adds 6 (`public_growth`), and
  maturity rewrites each backlog event once (at most about 240). A full batch of 40 counted events is about 250
  rows, so the Free plan quota covers roughly 400 such reports a day. A rejected report (`4xx`) writes nothing,
  except the first report of a UTC day, which makes the day's salt.

## Deploy (run these yourself, with your own Cloudflare account)

```bash
cd stats-worker
npm ci
npx wrangler login
```

1. **Create the database**

   ```bash
   npx wrangler d1 create sweepmac-stats
   ```

   Paste the printed `database_id` into `wrangler.jsonc`, replacing the one that is there (it belongs to the
   official deployment and won't work with your account).

2. **Apply the schema**

   ```bash
   npx wrangler d1 migrations apply sweepmac-stats --remote
   ```

3. **Set the HMAC key.** Generate one with `openssl rand -hex 32`, then:

   ```bash
   npx wrangler secret put REPORT_HMAC_KEY
   ```

   Paste the same value into `CommunityStatsConfig.hmacKey` in
   `Sources/Furl/State/CommunityStatsReporter.swift`. The two must match, or every report gets a `401`.

4. **Optional: download count.** Set `vars.DOWNLOADS_GITHUB_REPO` in `wrangler.jsonc` to `"owner/repo"`.
   `/v1/totals` then includes the total downloads of all GitHub release assets.

5. **Deploy**

   ```bash
   npx wrangler deploy
   ```

   A custom domain (for example `stats.example.com`, set under the Worker's *Domains & Routes*) is recommended.
   The Cache API used for `/v1/totals` does nothing on `*.workers.dev`. Then set:

   - `CommunityStatsConfig.endpoint` in the app to `https://<host>/v1/report`
   - `communityStats.totalsUrl` in `website/src/site.config.ts` to `https://<host>/v1/totals`

Before step 2 you can check the schema locally with `npx wrangler d1 migrations apply sweepmac-stats --local`.

## Develop

```bash
npm test          # vitest + @cloudflare/vitest-plugin (D1 and rate limits run locally in workerd)
npm run typecheck
npm run types     # regenerate worker-configuration.d.ts after editing wrangler.jsonc
cp .dev.vars.example .dev.vars && npm run dev
```

## Changing the caps

The per-event ceilings and the per-network budget are in `src/limits.ts`. The per-install daily caps live in
the `events_count` trigger. To change them, add a new migration that drops and recreates the trigger, and update
`DAILY_CAP` in `src/limits.ts` to match.

The global daily ceilings are rows in `public_ceilings`, so they change without a migration:

```bash
npx wrangler d1 execute sweepmac-stats --remote \
  --command "UPDATE public_ceilings SET value = 400 WHERE metric = 'installs'"
```

That takes effect at once. To keep it, put the same `UPDATE` in a new migration and change
`DAILY_PUBLIC_CEILING` in `src/limits.ts` to match; a test checks the migrations against it.

## Current deployment

- Worker `sweepmac-stats` at `https://stats.getfurl.app` (custom domain, so the `/v1/totals` edge cache works).
  The app reports to `/v1/report` and the website reads `/v1/totals` there.
- `DOWNLOADS_GITHUB_REPO` is `punitm0/furl`. `downloads` stays `null` until that repo has releases.
- D1 `sweepmac-stats`, migrations `0001_init.sql` and `0002_items_and_env.sql` applied. `0003_poisoning_limits.sql`
  is not applied yet: run `npx wrangler d1 migrations apply sweepmac-stats --remote` before deploying this
  Worker version (the new code needs its tables).
- `REPORT_HMAC_KEY` is a Worker secret that matches `CommunityStatsConfig.hmacKey` in the app. That key ships in
  the app and is public in this repo, so it only keeps out drive-by junk; it is not authentication. The rate
  limits, per-network budget, maturity rule and daily ceilings are the real limits, and the public totals are
  best-effort.
