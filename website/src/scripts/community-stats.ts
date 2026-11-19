/*
 * Community totals from the Furl stats Worker (stats-worker/, GET /v1/totals).
 * Shared by Stats.astro at build time and by the small client refresh below.
 * Every Furl install reports anonymous totals (see the privacy page for exactly what is sent).
 */
import { site } from "../site.config";

/** Shape of GET /v1/totals (see PublicTotals in stats-worker/src/index.ts). */
export interface CommunityTotals {
  diskFreedBytes: number;
  memoryFreedBytes: number;
  filesCompressed: number;
  installs: number;
  downloads: number | null;
}

export interface StatTile {
  key: "disk" | "memory" | "files" | "downloads";
  value: string;
  label: string;
  short: string;
}

const TB = 1e12;
const GB = 1e9;
const fmt = (n: number, digits: number) => n.toLocaleString("en-US", { maximumFractionDigits: digits });

function isTotals(x: unknown): x is CommunityTotals {
  const t = x as Record<string, unknown>;
  return !!t && ["diskFreedBytes", "memoryFreedBytes", "filesCompressed", "installs"].every((k) => typeof t[k] === "number");
}

export async function fetchTotals(url = site.communityStats.totalsUrl, timeoutMs = 5000): Promise<CommunityTotals | null> {
  if (!url) return null;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) return null;
    const json: unknown = await res.json();
    return isTotals(json) ? json : null;
  } catch {
    return null;
  }
}

/** The tiles to show, or null while the totals are below the threshold (small numbers never show). */
export function tilesFor(t: CommunityTotals | null): StatTile[] | null {
  const c = site.communityStats;
  if (!t || t.diskFreedBytes < c.minDiskFreedTB * TB || t.installs < c.minInstalls) return null;
  const tiles: StatTile[] = [
    { key: "disk", value: `${fmt(t.diskFreedBytes / TB, 1)} TB`, label: "of disk space freed", short: "disk space freed" },
  ];
  if (t.memoryFreedBytes >= 100 * GB) {
    tiles.push({ key: "memory", value: `${fmt(t.memoryFreedBytes / GB, 0)} GB`, label: "of memory freed from leftover processes", short: "memory freed" });
  }
  if (t.filesCompressed >= 1000) {
    tiles.push({ key: "files", value: fmt(t.filesCompressed, 0), label: "files compressed", short: "files compressed" });
  }
  if (t.downloads != null && t.downloads >= 1000) {
    tiles.push({ key: "downloads", value: fmt(t.downloads, 0), label: "downloads", short: "downloads" });
  }
  return tiles;
}
