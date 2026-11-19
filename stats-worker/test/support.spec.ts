import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { validCheckoutUrl } from "../src/index";

describe("GET /v1/support", () => {
  it("serves the configured DODO_CHECKOUT_URL (null when unset), cacheable and CORS-readable", async () => {
    const res = await exports.default.fetch("https://stats.example/v1/support");
    expect(res.status).toBe(200);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(res.headers.get("Cache-Control")).toContain("max-age=300");
    expect(await res.json()).toEqual({ checkoutUrl: validCheckoutUrl(env.DODO_CHECKOUT_URL ?? "") });
  });

  it("rejects other methods", async () => {
    const res = await exports.default.fetch("https://stats.example/v1/support", { method: "POST" });
    expect(res.status).toBe(405);
  });

  it("serves only https Dodo checkout links", () => {
    expect(validCheckoutUrl("https://checkout.dodopayments.com/buy/pdt_abc123")).toBe("https://checkout.dodopayments.com/buy/pdt_abc123");
    expect(validCheckoutUrl(" https://test.checkout.dodopayments.com/buy/pdt_X9 ")).toBe("https://test.checkout.dodopayments.com/buy/pdt_X9");
    for (const bad of [
      "",
      undefined,
      "http://checkout.dodopayments.com/buy/pdt_abc",
      "https://evil.example/buy/pdt_abc",
      "https://checkout.dodopayments.com.evil.example/buy/pdt_abc",
      "https://user@checkout.dodopayments.com/buy/pdt_abc",
      "https://checkout.dodopayments.com:8443/buy/pdt_abc",
      "https://checkout.dodopayments.com/account",
      "not a url",
    ]) {
      expect(validCheckoutUrl(bad)).toBeNull();
    }
  });
});
