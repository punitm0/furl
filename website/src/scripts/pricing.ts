import { site } from "../site.config";

/* ---------- Pay what you like ---------- */
// PayWhatYouLikeSite board: chips $0 / $5 / $12 / $25 / Other, $12 on load.
// Other turns into a field; whole dollars from $1 to $1,000 (same limits and wording as the app).
const MIN_AMOUNT = 1;
const MAX_AMOUNT = 1000;

const chips = Array.from(document.querySelectorAll<HTMLButtonElement>(".chip"));
const payButton = document.getElementById("pay-button") as HTMLAnchorElement;
const customWrap = document.getElementById("custom-amount") as HTMLElement;
const customInput = document.getElementById("custom-amount-input") as HTMLInputElement;
const customHint = document.getElementById("custom-amount-hint") as HTMLElement;
const card = document.getElementById("pricing-card") as HTMLElement | null;
const form = document.getElementById("pricing-form") as HTMLElement | null;
const done = document.getElementById("pricing-done") as HTMLElement | null;
const nudge = document.getElementById("pricing-nudge") as HTMLElement | null;
const pickFive = document.getElementById("pick-five") as HTMLAnchorElement | null;
const freeNote = document.getElementById("pricing-free-note") as HTMLElement | null;
const downloadAgain = document.getElementById("download-again") as HTMLAnchorElement | null;
if (chips.length > 0) {
let selected: HTMLButtonElement = chips.find((c) => c.getAttribute("aria-checked") === "true") || chips[0];
const otherChip = chips.find((c) => c.dataset.amount === "other");

type Choice = { kind: "amount"; amount: number } | { kind: "empty" } | { kind: "invalid" };

function currentChoice(): Choice {
  if (selected.dataset.amount !== "other") {
    return { kind: "amount", amount: Number(selected.dataset.amount) || 0 };
  }
  const raw = customInput.value.trim();
  if (raw === "") return { kind: "empty" };
  const n = Number(raw);
  if (!Number.isInteger(n) || n < MIN_AMOUNT || n > MAX_AMOUNT) return { kind: "invalid" };
  return { kind: "amount", amount: n };
}

function buildCheckoutUrl(amount: number): string {
  // Dodo Payments static link for a Pay What You Want product. `paymentAmount` fixes the price in
  // major units (12 = $12, not cents). `redirect_url` brings people back to the thank-you state;
  // Dodo appends payment_id and status to it.
  const url = new URL(site.checkoutUrl, window.location.href);
  url.searchParams.set("paymentAmount", String(amount));
  const back = new URL("/", site.siteUrl || window.location.origin);
  back.searchParams.set("paid", "1");
  url.searchParams.set("redirect_url", back.toString());
  return url.toString();
}

function setPayEnabled(enabled: boolean) {
  payButton.classList.toggle("is-disabled", !enabled);
  if (enabled) {
    payButton.removeAttribute("aria-disabled");
  } else {
    payButton.setAttribute("aria-disabled", "true");
    payButton.removeAttribute("href");
  }
}

function updatePayButton() {
  const choice = currentChoice();
  const invalid = choice.kind === "invalid";
  customHint.hidden = !invalid;
  customWrap.classList.toggle("is-invalid", invalid);
  customInput.setAttribute("aria-invalid", String(invalid));

  const isFree = choice.kind === "amount" && choice.amount === 0;
  // $0: the "Choose $0" line gives way to one honest nudge (fades in, 160 ms).
  if (freeNote) freeNote.hidden = isFree;
  if (nudge) nudge.hidden = !isFree;

  if (choice.kind !== "amount") {
    payButton.textContent = "Pick an amount";
    setPayEnabled(false);
    return;
  }
  const amount = choice.amount;
  // Without a checkout link nothing can be paid, so never say "Pay".
  payButton.textContent = amount > 0 && site.checkoutUrl ? "Pay $" + amount + " and download" : "Download free";
  setPayEnabled(true);
  if (amount > 0 && site.checkoutUrl) {
    payButton.href = buildCheckoutUrl(amount);
  } else if (site.downloadUrl) {
    payButton.href = site.downloadUrl;
  } else {
    payButton.href = "#pricing";
  }
}

/** The ring from the app's chip reaction (0 → 6 px, 270 ms). Restarted on every selection. */
function ring(el: HTMLElement) {
  el.classList.remove("is-ringing");
  void el.offsetWidth; // restart the animation
  el.classList.add("is-ringing");
}

function select(chip: HTMLButtonElement, { focus = false } = {}) {
  const changed = chip !== selected;
  selected = chip;
  const isOther = chip.dataset.amount === "other";
  chips.forEach((c) => {
    const on = c === chip;
    c.setAttribute("aria-checked", String(on));
    c.tabIndex = on ? 0 : -1;
  });
  if (otherChip) otherChip.hidden = isOther;
  customWrap.hidden = !isOther;
  if (isOther) {
    // The Other chip is hidden while its field shows; keep one chip reachable with Shift+Tab.
    const before = chips[chips.length - 2];
    if (before) before.tabIndex = 0;
    if (focus) customInput.focus();
    if (changed) ring(customWrap);
  } else {
    if (focus) chip.focus();
    if (changed) ring(chip);
  }
  updatePayButton();
}

chips.forEach((chip, i) => {
  chip.addEventListener("click", () => select(chip, { focus: chip.dataset.amount === "other" }));
  chip.addEventListener("keydown", (e) => {
    let next: HTMLButtonElement | null = null;
    if (e.key === "ArrowRight" || e.key === "ArrowDown") next = chips[(i + 1) % chips.length];
    if (e.key === "ArrowLeft" || e.key === "ArrowUp") next = chips[(i - 1 + chips.length) % chips.length];
    if (e.key === "Home") next = chips[0];
    if (e.key === "End") next = chips[chips.length - 1];
    if (next) {
      e.preventDefault();
      select(next, { focus: true });
    }
  });
});

customInput.addEventListener("input", () => {
  // Digits only, as in the app.
  const digits = customInput.value.replace(/\D+/g, "");
  if (digits !== customInput.value) customInput.value = digits;
  updatePayButton();
});
customInput.addEventListener("keydown", (e) => {
  // From the field, Left/Up at the start goes back to the chips.
  if ((e.key === "ArrowLeft" || e.key === "ArrowUp") && customInput.selectionStart === 0 && customInput.selectionEnd === 0) {
    e.preventDefault();
    select(chips[chips.length - 2], { focus: true });
  }
});
payButton.addEventListener("click", (e) => {
  if (payButton.getAttribute("aria-disabled") === "true") {
    e.preventDefault();
    return;
  }
  // "Download free": the DMG link does its work, and the card swaps in place to "Enjoy Furl".
  const choice = currentChoice();
  if (choice.kind === "amount" && choice.amount === 0) {
    if (!site.downloadUrl) e.preventDefault();
    showDone("free");
  }
});
pickFive?.addEventListener("click", (e) => {
  e.preventDefault();
  const five = chips.find((c) => c.dataset.amount === "5");
  if (five) select(five, { focus: true });
});

select(selected);
chips.forEach((c) => c.classList.remove("is-ringing")); // no ring on load

/* ---------- After the download ---------- */
// PayWhatYouLikeSite board: "Enjoy Furl" after Download free; "Thank you for supporting Furl" when
// Dodo Payments sends people back to /?paid=1. Same dark header, Curl f drawing and confetti for both.
const DONE_COPY = {
  free: {
    title: "Enjoy Furl",
    text: "Your download has started. Every feature is yours, and Furl will never ask again.",
  },
  paid: {
    title: "Thank you for supporting Furl",
    text: "Your download has started. Your support keeps Furl free and open source for everyone.",
  },
};

function showDone(kind: keyof typeof DONE_COPY, { focus = true } = {}) {
  if (!card || !form || !done) return;
  const title = document.getElementById("pricing-done-title");
  const text = document.getElementById("pricing-done-text");
  if (title) title.textContent = DONE_COPY[kind].title;
  if (text) text.textContent = DONE_COPY[kind].text;
  if (downloadAgain) {
    if (site.downloadUrl) downloadAgain.href = site.downloadUrl;
    else downloadAgain.href = "#pricing";
  }
  form.hidden = true;
  done.hidden = false;
  card.classList.add("is-done");
  // Restart the drawing. Reduce Motion is handled in CSS: the finished mark fades in.
  const mark = done.querySelector<SVGElement>(".furl-celebrate");
  if (mark) {
    mark.classList.remove("is-playing");
    void mark.getBoundingClientRect();
    mark.classList.add("is-playing");
  }
  if (focus && title) title.focus({ preventScroll: true });
}

// Dodo adds `status` to the return URL. A declined or expired checkout must not say thank you.
// (The redirect is a UI hint only; nothing is unlocked by it, Furl has nothing to unlock.)
const returnParams = new URLSearchParams(window.location.search);
const returnStatus = returnParams.get("status");
// Allow-list: only a succeeded payment (or a return with no status) says thank you.
if (returnParams.get("paid") === "1" && (returnStatus === null || returnStatus === "succeeded")) {
  showDone("paid", { focus: false });
  // The thank-you copy promises the download, so start it once.
  if (site.downloadUrl) window.location.assign(site.downloadUrl);
  document.getElementById("pricing")?.scrollIntoView({ block: "center" });
}
}
