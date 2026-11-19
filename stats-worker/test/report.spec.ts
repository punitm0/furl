import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { DAILY_CAP } from "../src/limits";
import { GiB, TiB, batch, dbTotals, report, uuid } from "./helpers";

const disk = (bytes: number, id = uuid()) => ({ id, kind: "disk", category: "junk", bytes });

function delta(before: Record<string, number>, after: Record<string, number>) {
  return Object.fromEntries(Object.keys(after).map((k) => [k, after[k] - (before[k] ?? 0)]));
}

describe("idempotency", () => {
  it("counts a retried batch exactly once", async () => {
    const install = uuid();
    const body = batch(install, [disk(1000), disk(2000), { id: uuid(), kind: "memory", category: "processes", bytes: 500 }]);
    const before = await dbTotals();
    expect((await report(body)).status).toBe(204);
    expect((await report(body)).status).toBe(204); // network retry
    expect((await report(body)).status).toBe(204);
    const d = delta(before, await dbTotals());
    expect(d.disk).toBe(3000);
    expect(d.memory).toBe(500);
    expect(d.installs).toBe(1);
  });

  it("counts a duplicated event inside one batch once", async () => {
    const id = uuid();
    const before = await dbTotals();
    expect((await report(batch(uuid(), [disk(700, id), disk(700, id)]))).status).toBe(204);
    expect(delta(before, await dbTotals()).disk).toBe(700);
  });

  it("keeps the same event id from different installs apart", async () => {
    const id = uuid();
    const before = await dbTotals();
    await report(batch(uuid(), [disk(10, id)]));
    await report(batch(uuid(), [disk(10, id)]));
    const d = delta(before, await dbTotals());
    expect(d.disk).toBe(20);
    expect(d.installs).toBe(2);
  });

  it("keeps memory separate from disk", async () => {
    const before = await dbTotals();
    await report(batch(uuid(), [{ id: uuid(), kind: "memory", category: "processes", bytes: 4 * GiB }]));
    const d = delta(before, await dbTotals());
    expect(d.memory).toBe(4 * GiB);
    expect(d.disk).toBe(0);
    expect(d.compress).toBe(0);
  });
});

describe("reversal", () => {
  it("subtracts a compress event that was undone, once", async () => {
    const install = uuid();
    const original = { id: uuid(), kind: "compress", category: "compress", bytes: 9000, files: 12 };
    const before = await dbTotals();
    await report(batch(install, [original]));
    let d = delta(before, await dbTotals());
    expect(d.compress).toBe(9000);
    expect(d.files).toBe(12);

    const undo = { id: uuid(), kind: "reversal", reverses: original.id };
    await report(batch(install, [undo]));
    await report(batch(install, [undo])); // retry of the same reversal
    await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: original.id }])); // a second, different reversal
    d = delta(before, await dbTotals());
    expect(d.compress).toBe(0);
    expect(d.files).toBe(0);
  });

  it("ignores a reversal of an event that was never counted", async () => {
    const before = await dbTotals();
    await report(batch(uuid(), [{ id: uuid(), kind: "reversal", reverses: uuid() }]));
    const d = delta(before, await dbTotals());
    expect(d.disk).toBe(0);
    expect(d.compress).toBe(0);
  });

  it("can't reverse another install's event", async () => {
    const original = disk(5000);
    const before = await dbTotals();
    await report(batch(uuid(), [original]));
    await report(batch(uuid(), [{ id: uuid(), kind: "reversal", reverses: original.id }]));
    expect(delta(before, await dbTotals()).disk).toBe(5000);
  });

  it("cancels an original that arrives after its reversal", async () => {
    const install = uuid();
    const original = { id: uuid(), kind: "compress", category: "shrink", bytes: 300, files: 2 };
    const before = await dbTotals();
    await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: original.id }, original]));
    const d = delta(before, await dbTotals());
    expect(d.compress).toBe(0);
    expect(d.files).toBe(0);
  });

  it("doesn't let a reversal target a reversal", async () => {
    const install = uuid();
    const original = disk(100);
    const firstUndo = { id: uuid(), kind: "reversal", reverses: original.id };
    const before = await dbTotals();
    await report(batch(install, [original, firstUndo]));
    await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: firstUndo.id }]));
    expect(delta(before, await dbTotals()).disk).toBe(0);
  });
});

describe("validation and clamping", () => {
  const install = uuid();
  const cases: Array<[string, unknown]> = [
    ["disk above 4 TiB", batch(install, [disk(4 * TiB + 1)])],
    ["memory above 256 GiB", batch(install, [{ id: uuid(), kind: "memory", category: "processes", bytes: 256 * GiB + 1 }])],
    ["negative bytes", batch(install, [disk(-5)])],
    ["fractional bytes", batch(install, [disk(1.5)])],
    ["unknown event field", batch(install, [{ ...disk(10), path: "/Users/me/secret" }])],
    ["unknown top-level field", { ...batch(install, [disk(10)]), hostname: "my-mac" }],
    ["unknown kind", batch(install, [{ id: uuid(), kind: "network", category: "junk", bytes: 1 }])],
    ["free-form category", batch(install, [{ ...disk(10), category: "/Users/me/Downloads" }])],
    ["bad install id", batch("not-a-uuid", [disk(10)])],
    ["uppercase install id", batch(uuid().toUpperCase(), [disk(10)])],
    ["empty batch", batch(install, [])],
    ["too many events", batch(install, Array.from({ length: 41 }, () => disk(1)))],
    ["wrong version", { ...batch(install, [disk(10)]), v: 2 }],
    ["missing os", (({ os, ...rest }) => rest)(batch(install, [disk(10)]))],
    ["os below 14", { ...batch(install, [disk(10)]), os: 13 }],
    ["os as string", { ...batch(install, [disk(10)]), os: "15" }],
    ["unknown arch", { ...batch(install, [disk(10)]), arch: "arm64e" }],
    ["fda as number", { ...batch(install, [disk(10)]), fda: 1 }],
    ["zero items", batch(install, [{ ...disk(10), items: 0 }])],
    ["items above ceiling", batch(install, [{ ...disk(10), items: 100_001 }])],
    ["items on memory", batch(install, [{ id: uuid(), kind: "memory", category: "processes", bytes: 1, items: 1 }])],
    ["items on compress", batch(install, [{ id: uuid(), kind: "compress", category: "compress", bytes: 1, files: 1, items: 1 }])],
    ["bytes as string", batch(install, [{ ...disk(10), bytes: "10" }])],
  ];

  for (const [name, body] of cases) {
    it(`rejects ${name}`, async () => {
      const before = await dbTotals();
      expect((await report(body)).status).toBe(400);
      expect(await dbTotals()).toEqual(before);
    });
  }

  it("accepts the per-event ceiling exactly", async () => {
    expect((await report(batch(uuid(), [disk(4 * TiB)]))).status).toBe(204);
  });

  it("rejects a bad signature, wrong key, and stale timestamp", async () => {
    const body = batch(uuid(), [disk(10)]);
    expect((await report(body, { signature: "0".repeat(64) })).status).toBe(401);
    expect((await report(body, { key: "someone-elses-key" })).status).toBe(401);
    expect((await report(body, { timestamp: Math.floor(Date.now() / 1000) - 3600 })).status).toBe(401);
    expect((await report(body, { signature: "nothex" })).status).toBe(401);
  });

  it("rejects a body over the size cap and non-JSON content types", async () => {
    const huge = JSON.stringify({ ...batch(uuid(), [disk(1)]), pad: "x".repeat(20_000) });
    expect((await report(null, { rawBody: huge })).status).toBe(413);
    expect((await report(batch(uuid(), [disk(1)]), { contentType: "text/plain" })).status).toBe(415);
    expect((await report(null, { rawBody: "{not json" })).status).toBe(400);
  });

  it("returns no body on success and rejects GET on /v1/report", async () => {
    const res = await report(batch(uuid(), [disk(1)]));
    expect(res.status).toBe(204);
    expect(await res.text()).toBe("");
    const { exports } = await import("cloudflare:workers");
    expect((await exports.default.fetch("https://stats.example/v1/report")).status).toBe(405);
  });
});

describe("daily outlier cap", () => {
  // These derive from DAILY_CAP, so they also check the trigger and src/limits.ts agree.
  const over = (cap: number, perEvent: number) => Array.from({ length: Math.ceil(cap / perEvent) + 1 }, () => perEvent);

  for (const [kind, category, metric] of [["disk", "junk", "disk"], ["compress", "compress", "compress"], ["memory", "processes", "memory"]] as const) {
    it(`stops counting an install's ${kind} bytes past DAILY_CAP.${metric} per day`, async () => {
      const install = uuid();
      const before = await dbTotals();
      const events = over(DAILY_CAP[metric], 100 * GiB).map((bytes) => ({ id: uuid(), kind, category, bytes, ...(kind === "compress" ? { files: 1 } : {}) }));
      await report(batch(install, events));
      expect(delta(before, await dbTotals())[metric]).toBe(DAILY_CAP[metric]);
      // Another install is unaffected.
      await report(batch(uuid(), [{ id: uuid(), kind, category, bytes: 1000, ...(kind === "compress" ? { files: 1 } : {}) }]));
      expect(delta(before, await dbTotals())[metric]).toBe(DAILY_CAP[metric] + 1000);
    });
  }

  it("stops counting an install's compressed files past DAILY_CAP.files per day", async () => {
    const before = await dbTotals();
    const events = over(DAILY_CAP.files, 30_000).map((files) => ({ id: uuid(), kind: "compress", category: "compress", bytes: 1, files }));
    await report(batch(uuid(), events));
    expect(delta(before, await dbTotals()).files).toBe(DAILY_CAP.files);
  });

  it("stops counting an install's items past DAILY_CAP.items per day", async () => {
    const before = await dbTotals();
    const events = over(DAILY_CAP.items, 20_000).map((items) => ({ ...disk(1), items }));
    await report(batch(uuid(), events));
    expect(delta(before, await dbTotals()).items).toBe(DAILY_CAP.items);
  });

  it("reverses only what an event actually contributed", async () => {
    const install = uuid();
    const a = disk(DAILY_CAP.disk - 10 * GiB);
    const b = disk(100 * GiB); // only 10 GiB of this counts
    const before = await dbTotals();
    await report(batch(install, [a, b, { id: uuid(), kind: "reversal", reverses: b.id }]));
    expect(delta(before, await dbTotals()).disk).toBe(DAILY_CAP.disk - 10 * GiB);
  });
});

describe("storage", () => {
  it("stores no IP, path or hostname, only the documented columns", async () => {
    const { results } = await env.DB.prepare("SELECT name FROM pragma_table_info('events')").all<{ name: string }>();
    expect(results.map((r) => r.name).sort()).toEqual(
      ["app_version", "bytes", "category", "counted_bytes", "counted_files", "counted_items", "day", "event_id", "files", "install_id", "items", "kind", "public_bytes", "public_files", "public_items", "reversed", "reverses"].sort(),
    );
    const envCols = await env.DB.prepare("SELECT name FROM pragma_table_info('install_env')").all<{ name: string }>();
    expect(envCols.results.map((r) => r.name).sort()).toEqual(["arch", "day", "fda", "install_id", "os_major"]);
    const install = uuid();
    await report(batch(install, [disk(1)]), { ip: "203.0.113.77" });
    const dump = JSON.stringify(
      (await env.DB.prepare("SELECT * FROM events WHERE install_id = ?").bind(install).all()).results,
    );
    expect(dump).not.toContain("203.0.113.77");
  });
});

describe("cleanup items", () => {
  it("counts disk items into their own metric, never into files", async () => {
    const before = await dbTotals();
    await report(batch(uuid(), [{ ...disk(100), items: 7 }, disk(50)]));
    const d = delta(before, await dbTotals());
    expect(d.items).toBe(7);
    expect(d.files).toBe(0);
    expect(d.disk).toBe(150);
  });

  it("keeps compress files out of items", async () => {
    const before = await dbTotals();
    await report(batch(uuid(), [{ id: uuid(), kind: "compress", category: "shrink", bytes: 10, files: 4 }]));
    const d = delta(before, await dbTotals());
    expect(d.files).toBe(4);
    expect(d.items).toBe(0);
  });

  it("reverses items with the event, once, including out of order", async () => {
    const install = uuid();
    const a = { ...disk(100), items: 5 };
    const b = { ...disk(100), items: 3 };
    const before = await dbTotals();
    await report(batch(install, [a, { id: uuid(), kind: "reversal", reverses: a.id }, { id: uuid(), kind: "reversal", reverses: a.id }]));
    // b's reversal lands before b itself.
    await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: b.id }]));
    await report(batch(install, [b]));
    const d = delta(before, await dbTotals());
    expect(d.items).toBe(0);
    expect(d.disk).toBe(0);
  });
});

describe("install environment", () => {
  const row = (install: string) =>
    env.DB.prepare("SELECT os_major, arch, fda FROM install_env WHERE install_id = ?").bind(install).first();

  it("keeps only the latest os, arch and Full Disk Access per install", async () => {
    const install = uuid();
    await report({ ...batch(install, [disk(1)]), os: 15, arch: "x86_64", fda: false });
    expect(await row(install)).toEqual({ os_major: 15, arch: "x86_64", fda: 0 });
    await report({ ...batch(install, [disk(1)]), os: 26, arch: "arm64", fda: true });
    expect(await row(install)).toEqual({ os_major: 26, arch: "arm64", fda: 1 });
    const { results } = await env.DB.prepare("SELECT COUNT(*) AS n FROM install_env WHERE install_id = ?").bind(install).all<{ n: number }>();
    expect(results[0].n).toBe(1);
  });

  it("accepts a full batch of 40 events plus the environment row", async () => {
    expect((await report(batch(uuid(), Array.from({ length: 40 }, () => disk(1))))).status).toBe(204);
  });
});
