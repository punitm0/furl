/**
 * Ceilings and caps. The per-install daily caps are enforced in SQL (events_count trigger, latest in
 * migrations/0003_poisoning_limits.sql) and the public ceilings are rows seeded by that migration; keep them in sync.
 */

export const TiB = 1024 ** 4;
export const GiB = 1024 ** 3;

/** Largest accepted request body. A full batch of 40 events is about 6 KB. */
export const MAX_BODY_BYTES = 16 * 1024;
/** Events per request. Each event is one D1 statement (plus one for install_env), and the Free plan allows 50 per invocation. */
export const MAX_EVENTS_PER_REPORT = 40;

/** Per-event ceilings: a request containing anything above these is rejected outright. */
export const MAX_DISK_BYTES_PER_EVENT = 4 * TiB;
export const MAX_COMPRESS_BYTES_PER_EVENT = 4 * TiB;
export const MAX_MEMORY_BYTES_PER_EVENT = 256 * GiB;
export const MAX_FILES_PER_EVENT = 100_000;
export const MAX_ITEMS_PER_EVENT = 100_000;

/** Accepted macOS major versions (the app needs 14+; the top leaves room for future releases). */
export const MIN_OS_MAJOR = 14;
export const MAX_OS_MAJOR = 99;

/**
 * Per-install, per-day caps (the events_count trigger applies them; tests check the two agree). Each is at
 * most 5% of DAILY_PUBLIC_CEILING, so it takes many installs, not two, to use up a day's public growth.
 */
export const DAILY_CAP = {
  disk: 256 * GiB, // 5% of 5 TiB
  compress: 64 * GiB, // ~3% of 2 TiB
  memory: 256 * GiB, // 5% of 5 TiB
  files: 100_000, // 2% of 5M
  items: 50_000, // 2.5% of 2M
} as const;

/** Accepted clock skew for the signed timestamp. */
export const MAX_CLOCK_SKEW_SECONDS = 10 * 60;

/** Edge cache lifetime for GET /v1/totals. */
export const TOTALS_CACHE_SECONDS = 600;

/**
 * Per client network (IPv4 address or IPv6 /64), per UTC day. Counted under a salted hash, never the IP.
 * Generous for a household or office behind one address; a script minting install ids hits them quickly.
 */
export const MAX_REPORTS_PER_IP_PER_DAY = 200;
export const MAX_NEW_INSTALLS_PER_IP_PER_DAY = 10;

/**
 * Events an install may store before it matures (reports on a second UTC day). Bounds the work maturity
 * does in one go. Past it, same-day reports get 429 and the app sends them the next day, when they mature it.
 */
export const MAX_EVENTS_BEFORE_MATURITY = 200;

/**
 * Most each public metric may grow per UTC day, whatever installs report (seeded into `public_ceilings`;
 * change them there with `wrangler d1 execute`, then update this to match).
 */
export const DAILY_PUBLIC_CEILING = {
  disk: 5 * TiB,
  compress: 2 * TiB,
  memory: 5 * TiB,
  files: 5_000_000,
  items: 2_000_000,
  installs: 200,
} as const;
