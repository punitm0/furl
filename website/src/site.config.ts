/*
 * Everything you need to edit before launch lives here.
 * Links and the stats band are applied at build time; the rest is read by the
 * small client scripts (pricing, share, waitlist).
 */

export const site = {
  // Payments: Dodo Payments (merchant of record). With checkoutUrl empty the pricing card is a free download.
  /** Direct link to the .dmg (ad-hoc signed, not notarised: first launch needs Open Anyway). Used for $0, and for any amount while checkoutUrl is empty. */
  downloadUrl: "https://github.com/punitm0/furl/releases/latest/download/Furl.dmg",
  /**
   * Dodo Payments static payment link for the one-time, Pay What You Want "Furl" product:
   *   live: "https://checkout.dodopayments.com/buy/pdt_…"
   *   test: "https://test.checkout.dodopayments.com/buy/pdt_…" (test-mode products only exist here)
   * Copy the pdt_… id from Dodo dashboard → Products. No API key is needed (and none may go here).
   * buildCheckoutUrl in src/scripts/pricing.ts adds "paymentAmount" (whole dollars, major units) and
   * "redirect_url" (this site's /?paid=1). Set the product's Minimum Price to $1 or less: Dodo ignores
   * a paymentAmount below the minimum.
   */
  checkoutUrl: "", // Dodo product pdt_0NsELiRCJ3tL7BN41EZgN; fill in once its live checkout opens
  /**
   * The public repository.
   * Drives every GitHub link: header, footer, Report a problem, /privacy "Read the source", and the
   * /changelog "Watch releases" and "Release on GitHub" links (githubPath("/releases")).
   */
  githubUrl: "https://github.com/punitm0/furl",
  /** Canonical page address, shared by the mobile "Send it to your Mac" button. Falls back to the current URL. */
  siteUrl: "https://getfurl.app",
  /**
   * Form endpoint for the Windows waitlist (Formspree, Buttondown, your own API...).
   * Receives a POST with one field, "email". Until it is set the form says it isn't open yet.
   */
  waitlistUrl: "",
  /**
   * Community totals band ("X TB freed by Furl users"). Fed by the stats Worker in stats-worker/
   * (GET /v1/totals), both at build time and in the browser. Empty URL = no band at all.
   * Anonymous totals sent by every Furl install (no files, names or paths).
   */
  communityStats: {
    /** e.g. "https://stats.getfurl.app/v1/totals" (see stats-worker/README.md). */
    totalsUrl: "https://stats.getfurl.app/v1/totals",
    /** Nothing shows until both thresholds are met, so small numbers never appear. */
    minDiskFreedTB: 10,
    minInstalls: 500,
  },
};

const githubBase = site.githubUrl.replace(/\/+$/, "");
const githubIsRepo = /^https:\/\/github\.com\/[^/]+\/[^/]+/.test(githubBase);

/** A path inside the repo (e.g. "/releases"), or the plain GitHub URL until a repo is set. */
export function githubPath(path: string): string {
  return githubIsRepo ? githubBase + path : site.githubUrl;
}
