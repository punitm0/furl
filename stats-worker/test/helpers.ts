import { exports } from "cloudflare:workers";
import { env } from "cloudflare:workers";
import { sign } from "../src/hmac";

export const KEY = "test-hmac-key";
export const TiB = 1024 ** 4;
export const GiB = 1024 ** 3;

export const uuid = () => crypto.randomUUID();

/** A distinct fake client IP per call site, so the per-IP limiter doesn't couple tests. */
let ipCounter = 1;
export const freshIp = () => `198.51.100.${ipCounter++ % 250}`;

export interface SendOptions {
  key?: string;
  timestamp?: number;
  ip?: string;
  rawBody?: string;
  contentType?: string;
  signature?: string;
  /**
   * Send as a brand-new install. By default the install is first marked as seen yesterday, so this report
   * matures it and counts straight away (most tests aren't about maturity or the per-IP new-install cap).
   */
  fresh?: boolean;
}

export async function report(body: unknown, opts: SendOptions = {}): Promise<Response> {
  const raw = opts.rawBody ?? JSON.stringify(body);
  const installId = (body as { installId?: unknown } | null)?.installId;
  if (!opts.fresh && typeof installId === "string") await seenYesterday(installId);
  const ts = String(opts.timestamp ?? Math.floor(Date.now() / 1000));
  const signature = opts.signature ?? (await sign(opts.key ?? KEY, ts, raw));
  return exports.default.fetch("https://stats.example/v1/report", {
    method: "POST",
    headers: {
      "Content-Type": opts.contentType ?? "application/json",
      "X-SweepMac-Timestamp": ts,
      "X-SweepMac-Signature": signature,
      "CF-Connecting-IP": opts.ip ?? freshIp(),
    },
    body: raw,
  });
}

export function batch(installId: string, events: unknown[]) {
  return { v: 1, installId, appVersion: "1.4.0", os: 15, arch: "arm64", fda: true, events };
}

export async function dbTotals(): Promise<Record<string, number>> {
  const { results } = await env.DB.prepare("SELECT metric, value FROM totals").all<{ metric: string; value: number }>();
  return Object.fromEntries(results.map((r) => [r.metric, r.value]));
}

/** Marks an install as first seen yesterday (unless it's already known), as if it had reported then. */
export async function seenYesterday(installId: string): Promise<void> {
  await env.DB.prepare("INSERT OR IGNORE INTO installs (install_id, first_day) VALUES (?1, date('now', '-1 day'))")
    .bind(installId)
    .run();
}

/** Moves an install's first day back by one, so its next report lands on a "later day". */
export async function ageInstall(installId: string): Promise<void> {
  await env.DB.prepare("UPDATE installs SET first_day = date(first_day, '-1 day') WHERE install_id = ?1").bind(installId).run();
}

export const today = () => new Date().toISOString().slice(0, 10);

/** Sets today's ceiling for a metric to whatever it has grown by so far plus `room`. Returns a restore function. */
export async function ceilingRoom(metric: string, room: number): Promise<() => Promise<void>> {
  const old = await env.DB.prepare("SELECT value FROM public_ceilings WHERE metric = ?1").bind(metric).first<{ value: number }>();
  await env.DB.prepare("INSERT OR IGNORE INTO public_growth (day, metric) VALUES (?1, ?2)").bind(today(), metric).run();
  const grown = await env.DB.prepare("SELECT value FROM public_growth WHERE day = ?1 AND metric = ?2").bind(today(), metric).first<{ value: number }>();
  await env.DB.prepare("UPDATE public_ceilings SET value = ?2 WHERE metric = ?1").bind(metric, (grown?.value ?? 0) + room).run();
  return async () => {
    await env.DB.prepare("UPDATE public_ceilings SET value = ?2 WHERE metric = ?1").bind(metric, old!.value).run();
  };
}
