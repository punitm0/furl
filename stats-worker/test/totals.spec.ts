import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { bucketDown } from "../src/index";
import { batch, report, uuid } from "./helpers";

describe("GET /v1/totals", () => {
  it("returns aggregates only, with no ids, and is cacheable and CORS-readable", async () => {
    const installs = Array.from({ length: 12 }, () => uuid());
    const eventIds: string[] = [];
    for (const install of installs) {
      const id = uuid();
      eventIds.push(id);
      expect((await report(batch(install, [{ id, kind: "disk", category: "worktrees", bytes: 1000, items: 2 }]))).status).toBe(204);
    }
    await report(batch(installs[0], [{ id: uuid(), kind: "compress", category: "compress", bytes: 500, files: 3 }]));
    await report(batch(installs[1], [{ id: uuid(), kind: "memory", category: "processes", bytes: 64 }]));

    const res = await exports.default.fetch("https://stats.example/v1/totals?bust=1");
    expect(res.status).toBe(200);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(res.headers.get("Cache-Control")).toContain("max-age=600");
    const raw = await res.text();
    const body = JSON.parse(raw);

    expect(Object.keys(body).sort()).toEqual(
      ["cleanupFreedBytes", "compressSavedBytes", "diskFreedBytes", "downloads", "filesCompressed", "installs", "itemsCleaned", "memoryFreedBytes", "updatedAt"].sort(),
    );
    expect(body.cleanupFreedBytes).toBe(12_000);
    expect(body.compressSavedBytes).toBe(500);
    expect(body.diskFreedBytes).toBe(12_500);
    expect(body.memoryFreedBytes).toBe(64);
    expect(body.filesCompressed).toBe(3);
    expect(body.itemsCleaned).toBe(24);
    expect(body.installs).toBe(10); // 12 rounded down to its bucket
    // Fetched live from GitHub (DOWNLOADS_GITHUB_REPO): null when unreachable, a count otherwise.
    expect(body.downloads === null || typeof body.downloads === "number").toBe(true);

    // Nothing that looks like an id, and none of the ids that went in.
    expect(raw).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-/i);
    for (const id of [...installs, ...eventIds]) expect(raw).not.toContain(id);
  });

  it("answers CORS preflight and refuses writes", async () => {
    const pre = await exports.default.fetch("https://stats.example/v1/totals", { method: "OPTIONS" });
    expect(pre.status).toBe(204);
    expect(pre.headers.get("Access-Control-Allow-Methods")).toContain("GET");
    expect((await exports.default.fetch("https://stats.example/v1/totals", { method: "POST" })).status).toBe(405);
    expect((await exports.default.fetch("https://stats.example/v1/admin")).status).toBe(404);
    expect((await exports.default.fetch("https://stats.example/v1/events")).status).toBe(404);
  });

  it("buckets install counts down", () => {
    expect([0, 9, 10, 57, 100, 999, 1234, 98_765].map(bucketDown)).toEqual([0, 0, 10, 50, 100, 900, 1000, 90_000]);
  });
});
