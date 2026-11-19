import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ipHash, networkKey } from "../src/index";
import { MAX_EVENTS_BEFORE_MATURITY, MAX_NEW_INSTALLS_PER_IP_PER_DAY, MAX_REPORTS_PER_IP_PER_DAY } from "../src/limits";
import { ageInstall, batch, ceilingRoom, dbTotals, report, today, uuid } from "./helpers";

const disk = (bytes: number, id = uuid()) => ({ id, kind: "disk", category: "junk", bytes });

function delta(before: Record<string, number>, after: Record<string, number>) {
  return Object.fromEntries(Object.keys(after).map((k) => [k, after[k] - (before[k] ?? 0)]));
}

/** Stores `n` one-byte disk events for an install today, straight into D1 (the triggers still run). */
async function storeBacklog(install: string, n: number): Promise<void> {
  await env.DB.prepare(
    `WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?2)
     INSERT INTO events (install_id, event_id, day, app_version, kind, category, bytes)
     SELECT ?1, 'backlog-' || i, ?3, '1.4.0', 'disk', 'junk', 1 FROM seq`,
  )
    .bind(install, n, today())
    .run();
}

describe("per-network daily budget", () => {
  it("accepts only a few never-seen installs per IP per day", async () => {
    const ip = "192.0.2.60";
    for (let i = 0; i < MAX_NEW_INSTALLS_PER_IP_PER_DAY; i++) {
      expect((await report(batch(uuid(), [disk(1)]), { ip, fresh: true })).status).toBe(204);
    }
    const before = await dbTotals();
    const rejected = uuid();
    expect((await report(batch(rejected, [disk(1)]), { ip, fresh: true })).status).toBe(429);
    const stored = await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE install_id = ?1").bind(rejected).first<{ n: number }>();
    expect(stored?.n).toBe(0);
    expect(await dbTotals()).toEqual(before);

    // An install the server already knows still gets through from that IP, and other IPs are unaffected.
    expect((await report(batch(uuid(), [disk(1)]), { ip })).status).toBe(204);
    expect((await report(batch(uuid(), [disk(1)]), { ip: "192.0.2.61", fresh: true })).status).toBe(204);
  });

  it("treats one IPv6 /64 as one network", async () => {
    const sameNet = ["2001:db8:1:2::1", "2001:db8:1:2:ffff::9", "2001:0db8:0001:0002:0:0:0:abc"];
    for (let i = 0; i < MAX_NEW_INSTALLS_PER_IP_PER_DAY; i++) {
      expect((await report(batch(uuid(), [disk(1)]), { ip: sameNet[i % 2], fresh: true })).status).toBe(204);
    }
    expect((await report(batch(uuid(), [disk(1)]), { ip: sameNet[2], fresh: true })).status).toBe(429);
    expect((await report(batch(uuid(), [disk(1)]), { ip: "2001:db8:1:3::1", fresh: true })).status).toBe(204);
  });

  it("normalises IPv6 to its /64 and leaves IPv4 whole", () => {
    expect(networkKey("2001:0db8:0001:0002:0000:0000:0000:0001")).toBe("2001:db8:1:2::/64");
    expect(networkKey("2001:db8:1:2::1")).toBe("2001:db8:1:2::/64");
    expect(networkKey("2001:db8::1")).toBe("2001:db8:0:0::/64");
    expect(networkKey("::1")).toBe("0:0:0:0::/64");
    expect(networkKey("198.51.100.7")).toBe("198.51.100.7");
  });

  it("caps reports per IP per day", async () => {
    const ip = "192.0.2.62";
    expect((await report(batch(uuid(), [disk(1)]), { ip })).status).toBe(204);
    const hash = await ipHash(env.DB, ip, today());
    await env.DB.prepare("UPDATE ip_daily SET reports = ?3 WHERE ip_hash = ?1 AND day = ?2")
      .bind(hash, today(), MAX_REPORTS_PER_IP_PER_DAY - 1)
      .run();
    expect((await report(batch(uuid(), [disk(1)]), { ip })).status).toBe(204);
    expect((await report(batch(uuid(), [disk(1)]), { ip })).status).toBe(429);
  });

  it("stores only a salted hash of the IP, never the IP", async () => {
    const ip = "203.0.113.200";
    await report(batch(uuid(), [disk(1)]), { ip });
    const dump = JSON.stringify([
      (await env.DB.prepare("SELECT * FROM ip_daily").all()).results,
      (await env.DB.prepare("SELECT * FROM ip_salts").all()).results,
    ]);
    expect(dump).not.toContain(ip);
    const plain = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip))), (b) =>
      b.toString(16).padStart(2, "0"),
    ).join("");
    expect(dump).not.toContain(plain);
    expect(dump).toContain(await ipHash(env.DB, ip, today()));
    const cols = await env.DB.prepare("SELECT name FROM pragma_table_info('ip_daily')").all<{ name: string }>();
    expect(cols.results.map((r) => r.name).sort()).toEqual(["day", "ip_hash", "new_installs", "reports"]);
  });

  it("makes a new salt each day and drops earlier days' salts and counters", async () => {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO ip_salts (day, salt) VALUES ('2000-01-01', 'old')"),
      env.DB.prepare("INSERT INTO ip_daily (ip_hash, day, reports) VALUES ('oldhash', '2000-01-01', 5)"),
      env.DB.prepare("DELETE FROM ip_salts WHERE day = ?1").bind(today()), // as if today had just begun
    ]);
    expect((await report(batch(uuid(), [disk(1)]))).status).toBe(204);
    const days = await env.DB.prepare("SELECT day FROM ip_salts").all<{ day: string }>();
    expect(days.results.map((r) => r.day)).toEqual([today()]);
    const old = await env.DB.prepare("SELECT COUNT(*) AS n FROM ip_daily WHERE day < ?1").bind(today()).first<{ n: number }>();
    expect(old?.n).toBe(0);
  });
});

describe("maturity", () => {
  it("counts an install only once it reports on a second day, then adds its backlog", async () => {
    const install = uuid();
    const before = await dbTotals();
    await report(batch(install, [disk(1000), { ...disk(10), items: 3 }]), { fresh: true });
    await report(batch(install, [disk(500)]), { fresh: true }); // same day: still nothing
    expect(delta(before, await dbTotals())).toMatchObject({ disk: 0, items: 0, installs: 0 });

    await ageInstall(install); // the next report is on a later day
    await report(batch(install, [disk(7)]), { fresh: true });
    expect(delta(before, await dbTotals())).toMatchObject({ disk: 1517, items: 3, installs: 1 });

    // Already mature: further reports count right away and don't add another install.
    await report(batch(install, [disk(3)]), { fresh: true });
    expect(delta(before, await dbTotals())).toMatchObject({ disk: 1520, installs: 1 });
  });

  it("leaves out events undone before maturity, and takes back backlog events undone after", async () => {
    const install = uuid();
    const kept = disk(400);
    const undoneEarly = disk(300);
    const before = await dbTotals();
    await report(batch(install, [kept, undoneEarly, { id: uuid(), kind: "reversal", reverses: undoneEarly.id }]), { fresh: true });
    await ageInstall(install);
    await report(batch(install, [disk(1)]), { fresh: true });
    expect(delta(before, await dbTotals()).disk).toBe(401);

    const undo = { id: uuid(), kind: "reversal", reverses: kept.id };
    await report(batch(install, [undo, undo]), { fresh: true });
    await report(batch(install, [undo]), { fresh: true });
    expect(delta(before, await dbTotals()).disk).toBe(1);
  });

  it("caps how many events an install stores before it matures", async () => {
    const install = uuid();
    await storeBacklog(install, MAX_EVENTS_BEFORE_MATURITY - 5);
    const before = await dbTotals();
    expect((await report(batch(install, Array.from({ length: 6 }, () => disk(1))), { fresh: true })).status).toBe(429);
    expect((await report(batch(install, Array.from({ length: 5 }, () => disk(1))), { fresh: true })).status).toBe(204);
    // On a later day the report goes through and matures the install with its whole backlog.
    await ageInstall(install);
    expect((await report(batch(install, Array.from({ length: 10 }, () => disk(1))), { fresh: true })).status).toBe(204);
    expect(delta(before, await dbTotals())).toMatchObject({ disk: MAX_EVENTS_BEFORE_MATURITY + 10, installs: 1 });
  });

  it("matures a large backlog in one linear pass", async () => {
    // Far past the cap: maturity's cost must stay linear in the backlog whatever got stored.
    const install = uuid();
    await storeBacklog(install, 5000);
    await ageInstall(install);
    const before = await dbTotals();
    const started = Date.now();
    // Straight into D1: the Worker would refuse a report from an install this far past the cap.
    await env.DB.prepare(
      `INSERT INTO events (install_id, event_id, day, app_version, kind, category, bytes) VALUES (?1, ?2, ?3, '1.4.0', 'disk', 'junk', 1)`,
    )
      .bind(install, uuid(), today())
      .run();
    expect(Date.now() - started).toBeLessThan(1000); // the quadratic version took several seconds
    expect(delta(before, await dbTotals())).toMatchObject({ disk: 5001, installs: 1 });
  });

  it("doesn't mature on a reversal alone", async () => {
    const install = uuid();
    const original = disk(50);
    const before = await dbTotals();
    await report(batch(install, [original]), { fresh: true });
    await ageInstall(install);
    await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: uuid() }]), { fresh: true });
    expect(delta(before, await dbTotals())).toMatchObject({ disk: 0, installs: 0 });
  });
});

describe("global daily growth ceiling", () => {
  it("clips events to what's left today, and a reversal takes back only what went in", async () => {
    const restore = await ceilingRoom("disk", 1000);
    try {
      const install = uuid();
      const a = disk(800);
      const b = disk(800); // only 200 fits
      const c = disk(800); // nothing fits
      const before = await dbTotals();
      await report(batch(install, [a, b, c]));
      expect(delta(before, await dbTotals()).disk).toBe(1000);

      await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: c.id }]));
      expect(delta(before, await dbTotals()).disk).toBe(1000); // c added nothing, so takes nothing back
      await report(batch(install, [{ id: uuid(), kind: "reversal", reverses: b.id }]));
      expect(delta(before, await dbTotals()).disk).toBe(800);

      // The freed room isn't given back: today's ceiling stays used up.
      await report(batch(uuid(), [disk(5)]));
      expect(delta(before, await dbTotals()).disk).toBe(800);
    } finally {
      await restore();
    }
  });

  it("drops a maturing install's backlog when it doesn't fit, but still counts later events", async () => {
    const install = uuid();
    await report(batch(install, [disk(5000)]), { fresh: true });
    const restore = await ceilingRoom("disk", 4000);
    try {
      const before = await dbTotals();
      await ageInstall(install);
      await report(batch(install, [disk(100)]), { fresh: true });
      expect(delta(before, await dbTotals())).toMatchObject({ disk: 100, installs: 1 });
    } finally {
      await restore();
    }
  });

  it("caps how many installs join the count per day", async () => {
    const restore = await ceilingRoom("installs", 1);
    try {
      const before = await dbTotals();
      const installs = [uuid(), uuid(), uuid()];
      for (const install of installs) await report(batch(install, [disk(1)]));
      // Only the first fits; the others stay unmatured, adding nothing yet.
      expect(delta(before, await dbTotals())).toMatchObject({ installs: 1, disk: 1 });
      await restore();
      // With room again, their next report matures them and brings in their backlog, once.
      for (const install of installs.slice(1)) await report(batch(install, [disk(1)]));
      expect(delta(before, await dbTotals())).toMatchObject({ installs: 3, disk: 5 });
    } finally {
      await restore();
    }
  });

  it("keeps an install unmatured (not lost) while the install ceiling is full", async () => {
    const install = uuid();
    await report(batch(install, [disk(100)]), { fresh: true });
    await ageInstall(install);
    const restore = await ceilingRoom("installs", 0);
    const before = await dbTotals();
    try {
      await report(batch(install, [disk(10)]), { fresh: true });
      expect(delta(before, await dbTotals())).toMatchObject({ installs: 0, disk: 0 });
      const row = await env.DB.prepare("SELECT matured FROM installs WHERE install_id = ?1").bind(install).first<{ matured: number }>();
      expect(row?.matured).toBe(0);
    } finally {
      await restore();
    }
    await report(batch(install, [disk(1)]), { fresh: true });
    expect(delta(before, await dbTotals())).toMatchObject({ installs: 1, disk: 111 });
    // Already counted: nothing is added twice.
    await report(batch(install, [disk(1)]), { fresh: true });
    expect(delta(before, await dbTotals())).toMatchObject({ installs: 1, disk: 112 });
  });

  it("never locks out an unmatured install that went past the event cap", async () => {
    const install = uuid();
    await storeBacklog(install, MAX_EVENTS_BEFORE_MATURITY - 10);
    await ageInstall(install);
    const before = await dbTotals();
    const restore = await ceilingRoom("installs", 0); // can't mature today
    try {
      // One batch may go past the cap; while the install ceiling stays full, the next is refused.
      const big = Array.from({ length: 40 }, () => disk(1));
      expect((await report(batch(install, big), { fresh: true })).status).toBe(204);
      expect((await report(batch(install, [disk(1)]), { fresh: true })).status).toBe(429);
    } finally {
      await restore();
    }
    // A later day (or the same day once there's room): the report goes through and matures the install.
    await ageInstall(install);
    expect((await report(batch(install, [disk(1)]), { fresh: true })).status).toBe(204);
    expect(delta(before, await dbTotals())).toMatchObject({ installs: 1, disk: MAX_EVENTS_BEFORE_MATURITY - 10 + 40 + 1 });
    const row = await env.DB.prepare("SELECT matured FROM installs WHERE install_id = ?1").bind(install).first<{ matured: number }>();
    expect(row?.matured).toBe(1);
  });

  it("refuses an over-cap install a batch that can't mature it, even with room", async () => {
    const install = uuid();
    const stored = disk(1);
    await report(batch(install, [stored]), { fresh: true });
    await storeBacklog(install, MAX_EVENTS_BEFORE_MATURITY + 100);
    await ageInstall(install);
    const count = async () =>
      (await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE install_id = ?1").bind(install).first<{ n: number }>())!.n;
    const n = await count();
    const reversals = () => Array.from({ length: 39 }, () => ({ id: uuid(), kind: "reversal", reverses: uuid() }));
    // Reversals only: they never fire maturity, so they'd just grow the backlog.
    expect((await report(batch(install, reversals()), { fresh: true })).status).toBe(429);
    // A retried (already stored) event plus reversals: the retry is ignored, so it can't mature either.
    expect((await report(batch(install, [stored, ...reversals()]), { fresh: true })).status).toBe(429);
    expect(await count()).toBe(n);
    // A new counted event gets through and matures the install.
    expect((await report(batch(install, [...reversals(), disk(1)]), { fresh: true })).status).toBe(204);
    const row = await env.DB.prepare("SELECT matured FROM installs WHERE install_id = ?1").bind(install).first<{ matured: number }>();
    expect(row?.matured).toBe(1);
  });

  it("keeps the ceilings in the migrations and src/limits.ts in sync", async () => {
    // The test setup lifts the live ceilings, so compare against the migration's own INSERT.
    const { DAILY_PUBLIC_CEILING } = await import("../src/limits");
    const sql = env.TEST_MIGRATIONS.find((m) => m.name.startsWith("0003"))!.queries.join("\n");
    const insert = sql.slice(sql.indexOf("INSERT INTO public_ceilings"));
    const seeded = Object.fromEntries(
      [...insert.slice(0, insert.indexOf(";")).matchAll(/\('(\w+)',\s*(\d+)\)/g)].map((m) => [m[1], Number(m[2])]),
    );
    // Later migrations may change a ceiling with `UPDATE public_ceilings SET value = N WHERE metric = 'x'`.
    for (const m of env.TEST_MIGRATIONS.filter((m) => m.name > "0003")) {
      for (const u of m.queries.join("\n").matchAll(/UPDATE public_ceilings SET value = (\d+) WHERE metric = '(\w+)'/g)) {
        seeded[u[2]] = Number(u[1]);
      }
    }
    expect(seeded).toEqual(DAILY_PUBLIC_CEILING);
    const { results } = await env.DB.prepare("SELECT metric FROM public_ceilings ORDER BY metric").all<{ metric: string }>();
    expect(results.map((r) => r.metric)).toEqual(Object.keys(DAILY_PUBLIC_CEILING).sort());
  });
});

describe("GET /v1/totals on workers.dev", () => {
  it("is not served there (no edge cache, so every hit would read D1)", async () => {
    const res = await exports.default.fetch("https://sweepmac-stats.someone.workers.dev/v1/totals");
    expect(res.status).toBe(404);
    expect((await exports.default.fetch("https://stats.example/v1/totals")).status).toBe(200);
  });
});
