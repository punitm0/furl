import { z } from "zod";
import {
  MAX_COMPRESS_BYTES_PER_EVENT,
  MAX_DISK_BYTES_PER_EVENT,
  MAX_EVENTS_PER_REPORT,
  MAX_FILES_PER_EVENT,
  MAX_ITEMS_PER_EVENT,
  MAX_MEMORY_BYTES_PER_EVENT,
  MAX_OS_MAJOR,
  MIN_OS_MAJOR,
} from "./limits";

/** Lowercase RFC 4122 UUID (the app sends `UUID().uuidString.lowercased()`). */
const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);

/** Where in the app the space came from. A closed list, so nothing free-form is ever stored. */
export const DISK_CATEGORIES = [
  "junk",
  "worktrees",
  "apps",
  "large_files",
  "duplicates",
  "smart_review",
  "trash",
  "auto_sweep",
  "other",
] as const;

const byteCount = (max: number) => z.number().int().min(1).max(max);

const diskEvent = z.strictObject({
  id: uuid,
  kind: z.literal("disk"),
  category: z.enum(DISK_CATEGORIES),
  bytes: byteCount(MAX_DISK_BYTES_PER_EVENT),
  /** Things removed (a cache folder, an app, a worktree each count as one). Optional: 0 when absent. */
  items: z.number().int().min(1).max(MAX_ITEMS_PER_EVENT).optional(),
});

const memoryEvent = z.strictObject({
  id: uuid,
  kind: z.literal("memory"),
  category: z.enum(["processes", "auto_sweep"]),
  bytes: byteCount(MAX_MEMORY_BYTES_PER_EVENT),
});

const compressEvent = z.strictObject({
  id: uuid,
  kind: z.literal("compress"),
  category: z.enum(["compress", "shrink"]),
  bytes: z.number().int().min(0).max(MAX_COMPRESS_BYTES_PER_EVENT),
  files: z.number().int().min(1).max(MAX_FILES_PER_EVENT),
});

const reversalEvent = z.strictObject({
  id: uuid,
  kind: z.literal("reversal"),
  reverses: uuid,
});

export const reportEvent = z.discriminatedUnion("kind", [diskEvent, memoryEvent, compressEvent, reversalEvent]);

export const reportBody = z.strictObject({
  v: z.literal(1),
  installId: uuid,
  appVersion: z.string().regex(/^\d{1,4}(\.\d{1,4}){0,3}$/),
  /** macOS major version (14, 15, 26, …). */
  os: z.number().int().min(MIN_OS_MAJOR).max(MAX_OS_MAJOR),
  /** CPU of the Mac itself (not the build: an x86_64 build under Rosetta still reports arm64). */
  arch: z.enum(["arm64", "x86_64"]),
  /** Whether Full Disk Access is granted. */
  fda: z.boolean(),
  events: z.array(reportEvent).min(1).max(MAX_EVENTS_PER_REPORT),
});

export type ReportBody = z.infer<typeof reportBody>;
export type ReportEvent = z.infer<typeof reportEvent>;
