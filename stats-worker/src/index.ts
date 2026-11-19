/*
 * Furl community totals.
 *
 *   POST /v1/report  write-only. Accepts one batch of events from one install; never returns data.
 *   GET  /v1/totals  aggregate sums plus a bucketed install count, edge-cached for 10 minutes. Not served on
 *                    *.workers.dev, where the Cache API is a no-op and every request would hit D1.
 *   GET  /v1/support the Dodo Payments checkout link for "pay what you like" (DODO_CHECKOUT_URL var),
 *                    so shipped apps pick it up without an update. Static config; reads no request data.
 *
 * There are deliberately no admin, list or per-install endpoints. D1 is reached only through the
 * DB binding with prepared statements; no SQL is ever built from request input.
 */
import { verifySignature } from "./hmac";
import {
  MAX_BODY_BYTES,
  MAX_CLOCK_SKEW_SECONDS,
  MAX_EVENTS_BEFORE_MATURITY,
  MAX_NEW_INSTALLS_PER_IP_PER_DAY,
  MAX_REPORTS_PER_IP_PER_DAY,
  TOTALS_CACHE_SECONDS,
} from "./limits";
import { reportBody, type ReportBody, type ReportEvent } from "./schema";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/v1/report") {
        if (request.method !== "POST") return text(405, "Method not allowed", { Allow: "POST" });
        return await handleReport(request, env);
      }
      if (url.pathname === "/v1/totals") {
        if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
        if (request.method !== "GET" && request.method !== "HEAD") {
          return text(405, "Method not allowed", { Allow: "GET, HEAD, OPTIONS", ...corsHeaders() });
        }
        // Edge caching doesn't work on workers.dev, so every hit there would be a D1 read.
        if (url.hostname.endsWith(".workers.dev")) return text(404, "Not found", corsHeaders());
        return await handleTotals(request, env, ctx);
      }
      if (url.pathname === "/v1/support") {
        if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
        if (request.method !== "GET" && request.method !== "HEAD") {
          return text(405, "Method not allowed", { Allow: "GET, HEAD, OPTIONS", ...corsHeaders() });
        }
        return handleSupport(request, env);
      }
      return text(404, "Not found");
    } catch (err) {
      // Log the failure without anything identifying (no body, no IP).
      console.error(JSON.stringify({ msg: "unhandled", path: url.pathname, error: String(err) }));
      return text(500, "Internal error");
    }
  },
} satisfies ExportedHandler<Env>;

// MARK: - POST /v1/report

async function handleReport(request: Request, env: Env): Promise<Response> {
  // 1. Per-IP rate limit. The IP is used only as a transient rate-limit key and is never stored or logged.
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await env.REPORT_LIMIT_IP.limit({ key: ip })).success) return text(429, "Too many requests");

  // 2. Shape of the request itself.
  if (!(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json")) {
    return text(415, "Expected application/json");
  }
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > MAX_BODY_BYTES) return text(413, "Body too large");
  const body = await readCapped(request, MAX_BODY_BYTES);
  if (body === null) return text(413, "Body too large");

  // 3. Signature speed bump (see hmac.ts: not real security).
  const timestamp = request.headers.get("X-SweepMac-Timestamp") ?? "";
  const signature = (request.headers.get("X-SweepMac-Signature") ?? "").toLowerCase();
  if (!env.REPORT_HMAC_KEY) return text(503, "Not configured");
  const ts = Number(timestamp);
  if (!/^\d{1,12}$/.test(timestamp) || Math.abs(Date.now() / 1000 - ts) > MAX_CLOCK_SKEW_SECONDS) {
    return text(401, "Bad timestamp");
  }
  if (!(await verifySignature(env.REPORT_HMAC_KEY, timestamp, body, signature))) return text(401, "Bad signature");

  // 4. Strict schema: unknown fields, unknown kinds/categories and out-of-range values are rejected.
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch {
    return text(400, "Invalid JSON");
  }
  const parsed = reportBody.safeParse(json);
  if (!parsed.success) return text(400, "Invalid report");
  const report = parsed.data;

  // 5. Per-install rate limit.
  if (!(await env.REPORT_LIMIT_INSTALL.limit({ key: report.installId })).success) {
    return text(429, "Too many requests");
  }

  const day = utcDay(new Date());

  // 6. An install that hasn't matured yet (see migrations/0003) may only store so many events, which bounds
  //    the backlog maturity has to process. On a later day a report over the cap still gets through when it
  //    will mature the install: today's install ceiling has room and the batch holds a disk, memory or
  //    compress event not stored yet (only those fire maturity; reversals and retried events don't). So the
  //    install is never locked out, and nothing else can grow its backlog past the cap.
  const install = await env.DB.prepare(
    `SELECT matured, first_day,
            CASE WHEN matured = 0 THEN (SELECT COUNT(*) FROM events e WHERE e.install_id = ?1) ELSE 0 END AS stored,
            COALESCE((SELECT g.value FROM public_growth g WHERE g.day = ?2 AND g.metric = 'installs'), 0)
              < COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'installs'), 0) AS room
       FROM installs WHERE install_id = ?1`,
  )
    .bind(report.installId, day)
    .first<{ matured: number; first_day: string; stored: number; room: number }>();
  let overCap = false;
  if (install !== null && install.matured === 0) {
    if (install.first_day >= day) {
      overCap = install.stored + report.events.length > MAX_EVENTS_BEFORE_MATURITY;
    } else if (install.stored > MAX_EVENTS_BEFORE_MATURITY) {
      overCap = install.room === 0 || !(await hasNewCountedEvent(env.DB, report));
    }
  }
  if (overCap) {
    return text(429, "Too many requests");
  }

  // 7. Per-network daily budget: reports, and installs this server has never seen. Keyed on a salted hash
  //    of the IP (see ipHash); the IP itself is never stored.
  if (!(await spendIpBudget(env.DB, ip, day, install === null))) return text(429, "Too many requests");

  // 8. One INSERT OR IGNORE per event, all in one D1 batch (a single transaction). The triggers in
  //    migrations (latest: 0003_poisoning_limits.sql) update the aggregates atomically with each insert.
  await env.DB.batch(insertStatements(env.DB, report, day));

  // Write-only: success carries no body.
  return new Response(null, { status: 204 });
}

/** True if the batch holds a disk, memory or compress event this install hasn't stored yet. */
async function hasNewCountedEvent(db: D1Database, report: ReportBody): Promise<boolean> {
  const ids = report.events.filter((e) => e.kind !== "reversal").map((e) => e.id);
  if (ids.length === 0) return false;
  const row = await db
    .prepare(
      `SELECT 1 FROM json_each(?2) j
        WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.install_id = ?1 AND e.event_id = j.value) LIMIT 1`,
    )
    .bind(report.installId, JSON.stringify(ids))
    .first();
  return row !== null;
}

/**
 * Atomically counts one report (and one new install, if this id is unknown) against the network's daily
 * budget. False when either cap is already reached; nothing is written then.
 */
async function spendIpBudget(db: D1Database, ip: string, day: string, newInstall: boolean): Promise<boolean> {
  const isNew = newInstall ? 1 : 0;
  const row = await db
    .prepare(
      `INSERT INTO ip_daily (ip_hash, day, reports, new_installs) VALUES (?1, ?2, 1, ?3)
         ON CONFLICT (ip_hash, day) DO UPDATE SET reports = reports + 1, new_installs = new_installs + ?3
         WHERE reports < ?4 AND new_installs + ?3 <= ?5
       RETURNING reports`,
    )
    .bind(await ipHash(db, ip, day), day, isNew, MAX_REPORTS_PER_IP_PER_DAY, MAX_NEW_INSTALLS_PER_IP_PER_DAY)
    .first();
  return row !== null;
}

/**
 * Hex SHA-256 of today's random salt plus the client's network: the full IPv4 address, or the /64 prefix
 * of an IPv6 address (one subscriber usually holds a whole /64). The salt is new each UTC day, and making
 * it clears earlier days' salts and counters, so a hash only lives for the day it was made.
 */
export async function ipHash(db: D1Database, ip: string, day: string): Promise<string> {
  const salt = await dailySalt(db, day);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${networkKey(ip)}`));
  return toHex(new Uint8Array(digest));
}

export function networkKey(ip: string): string {
  if (!ip.includes(":")) return ip;
  // Expand "::" so the first four groups are the /64, whatever the notation.
  const [head, tail = ""] = ip.toLowerCase().split("::");
  const left = head ? head.split(":") : [];
  const right = ip.includes("::") ? (tail ? tail.split(":") : []) : [];
  const groups = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

async function dailySalt(db: D1Database, day: string): Promise<string> {
  const read = () => db.prepare("SELECT salt FROM ip_salts WHERE day = ?1").bind(day).first<{ salt: string }>();
  const existing = await read();
  if (existing) return existing.salt;
  const fresh = toHex(crypto.getRandomValues(new Uint8Array(32)));
  await db.batch([
    db.prepare("DELETE FROM ip_salts WHERE day < ?1").bind(day),
    db.prepare("DELETE FROM ip_daily WHERE day < ?1").bind(day),
    db.prepare("INSERT OR IGNORE INTO ip_salts (day, salt) VALUES (?1, ?2)").bind(day, fresh),
  ]);
  // Another request may have made today's salt first; everyone uses the stored one.
  return (await read())?.salt ?? fresh;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

const INSERT_SQL = `INSERT OR IGNORE INTO events
  (install_id, event_id, day, app_version, kind, category, bytes, files, items, reverses)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`;

/** Latest environment per install, overwritten each report (no history). */
const ENV_SQL = `INSERT INTO install_env (install_id, os_major, arch, fda, day) VALUES (?1, ?2, ?3, ?4, ?5)
  ON CONFLICT (install_id) DO UPDATE SET
    os_major = excluded.os_major, arch = excluded.arch, fda = excluded.fda, day = excluded.day`;

function insertStatements(db: D1Database, report: ReportBody, day: string): D1PreparedStatement[] {
  const stmt = db.prepare(INSERT_SQL);
  const events = report.events.map((e) => {
    const row = eventRow(e);
    return stmt.bind(report.installId, e.id, day, report.appVersion, e.kind, row.category, row.bytes, row.files, row.items, row.reverses);
  });
  const env = db.prepare(ENV_SQL).bind(report.installId, report.os, report.arch, report.fda ? 1 : 0, day);
  return [...events, env];
}

function eventRow(e: ReportEvent): { category: string; bytes: number; files: number; items: number; reverses: string | null } {
  switch (e.kind) {
    case "disk":
      return { category: e.category, bytes: e.bytes, files: 0, items: e.items ?? 0, reverses: null };
    case "memory":
      return { category: e.category, bytes: e.bytes, files: 0, items: 0, reverses: null };
    case "compress":
      return { category: e.category, bytes: e.bytes, files: e.files, items: 0, reverses: null };
    case "reversal":
      return { category: "reversal", bytes: 0, files: 0, items: 0, reverses: e.reverses };
  }
}

/** Reads at most `limit` bytes of the body; null if it is longer. Never buffers an unbounded body. */
async function readCapped(request: Request, limit: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    joined.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder().decode(joined);
}

// MARK: - GET /v1/totals

export interface PublicTotals {
  /** Cleanups plus Compress/Shrink savings. */
  diskFreedBytes: number;
  cleanupFreedBytes: number;
  compressSavedBytes: number;
  memoryFreedBytes: number;
  filesCompressed: number;
  /** Things removed by cleanups (a cache folder, an app, a worktree each count as one). */
  itemsCleaned: number;
  /** Rounded down to its leading digit (1,234 → 1,000), so small changes can't single anyone out. */
  installs: number;
  /** Sum of release asset downloads from the distribution host, when configured. */
  downloads: number | null;
  updatedAt: string;
}

async function handleTotals(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  // Query strings are ignored so they can't be used to bust the cache.
  const cacheKey = new Request(new URL("/v1/totals", request.url).toString(), { method: "GET" });
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) return request.method === "HEAD" ? new Response(null, hit) : hit;

  const rows = await env.DB.prepare("SELECT metric, value FROM totals").all<{ metric: string; value: number }>();
  const m = new Map(rows.results.map((r) => [r.metric, Math.max(0, r.value)]));
  const disk = m.get("disk") ?? 0;
  const compress = m.get("compress") ?? 0;
  const totals: PublicTotals = {
    diskFreedBytes: disk + compress,
    cleanupFreedBytes: disk,
    compressSavedBytes: compress,
    memoryFreedBytes: m.get("memory") ?? 0,
    filesCompressed: m.get("files") ?? 0,
    itemsCleaned: m.get("items") ?? 0,
    installs: bucketDown(m.get("installs") ?? 0),
    downloads: await fetchDownloads(env.DOWNLOADS_GITHUB_REPO),
    updatedAt: new Date().toISOString(),
  };

  const response = new Response(JSON.stringify(totals), {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": `public, max-age=${TOTALS_CACHE_SECONDS}, s-maxage=${TOTALS_CACHE_SECONDS}`,
      ...corsHeaders(),
    },
  });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return request.method === "HEAD" ? new Response(null, response) : response;
}

/** 0–9 → 0, then keep only the leading digit: 57 → 50, 1,234 → 1,000, 98,765 → 90,000. */
export function bucketDown(n: number): number {
  if (n < 10) return 0;
  const magnitude = 10 ** Math.floor(Math.log10(n));
  return Math.floor(n / magnitude) * magnitude;
}

/** Total downloads of all release assets on GitHub, or null if unset or unavailable. */
async function fetchDownloads(repo: string | undefined): Promise<number | null> {
  if (!repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) return null;
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=100`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "furl-stats-worker" },
    });
    if (!res.ok) return null;
    const releases = (await res.json()) as Array<{ assets?: Array<{ download_count?: number }> }>;
    let sum = 0;
    for (const r of releases) for (const a of r.assets ?? []) sum += a.download_count ?? 0;
    return sum;
  } catch {
    return null;
  }
}

// MARK: - GET /v1/support

export interface PublicSupport {
  /** Dodo Payments static payment link for the Pay What You Want product, or null while unset. */
  checkoutUrl: string | null;
}

const SUPPORT_CACHE_SECONDS = 300;
const CHECKOUT_HOSTS = new Set(["checkout.dodopayments.com", "test.checkout.dodopayments.com"]);

/** Only an https Dodo checkout link ("/buy/pdt_…") is ever served; anything else becomes null. */
export function validCheckoutUrl(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    const url = new URL(raw.trim());
    if (url.protocol !== "https:" || !CHECKOUT_HOSTS.has(url.hostname) || url.port !== "") return null;
    if (url.username || url.password || !/^\/buy\/pdt_[A-Za-z0-9]+\/?$/.test(url.pathname)) return null;
    return url.toString();
  } catch {
    return null;
  }
}

function handleSupport(request: Request, env: Env): Response {
  const body: PublicSupport = { checkoutUrl: validCheckoutUrl(env.DODO_CHECKOUT_URL) };
  const response = new Response(JSON.stringify(body), {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": `public, max-age=${SUPPORT_CACHE_SECONDS}, s-maxage=${SUPPORT_CACHE_SECONDS}`,
      ...corsHeaders(),
    },
  });
  return request.method === "HEAD" ? new Response(null, response) : response;
}

// MARK: - Helpers

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}

function text(status: number, message: string, headers: Record<string, string> = {}): Response {
  return new Response(message, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...headers } });
}

function utcDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}
