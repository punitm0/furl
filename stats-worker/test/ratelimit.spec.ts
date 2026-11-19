import { describe, expect, it } from "vitest";
import { batch, report, uuid } from "./helpers";

const event = () => ({ id: uuid(), kind: "disk", category: "junk", bytes: 1 });

describe("rate limiting", () => {
  it("limits one install to 6 reports a minute, whatever IP it comes from", async () => {
    const install = uuid();
    const statuses: number[] = [];
    for (let i = 0; i < 8; i++) statuses.push((await report(batch(install, [event()]))).status);
    expect(statuses.slice(0, 6)).toEqual([204, 204, 204, 204, 204, 204]);
    expect(statuses.slice(6)).toEqual([429, 429]);
    // A different install is unaffected.
    expect((await report(batch(uuid(), [event()]))).status).toBe(204);
  });

  it("limits one IP to 60 reports a minute across installs", async () => {
    const ip = "192.0.2.10";
    const statuses: number[] = [];
    for (let i = 0; i < 62; i++) statuses.push((await report(batch(uuid(), [event()]), { ip })).status);
    expect(statuses.filter((s) => s === 204).length).toBe(60);
    expect(statuses.slice(60)).toEqual([429, 429]);
  });
});
