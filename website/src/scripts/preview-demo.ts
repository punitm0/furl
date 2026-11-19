// HeroPreviewInteractive board: a pretend Clean on the landing preview.
// Cards toggle in and out of the total, Clean runs a short countdown,
// and Undo puts everything back. Nothing leaves the page.

const BASE_DISK = 17.0; // other safe items, always included

const root = document.querySelector<HTMLElement>("[data-demo]");
if (root) {
  const value = root.querySelector<HTMLElement>("[data-demo-value]")!;
  const label = root.querySelector<HTMLElement>("[data-demo-label]")!;
  const sub = root.querySelector<HTMLElement>("[data-demo-sub]")!;
  const cta = root.querySelector<HTMLButtonElement>("[data-demo-cta]")!;
  const status = root.querySelector<HTMLElement>("[data-demo-status]");
  const say = (text: string) => { if (status) status.textContent = text; };
  const hint = document.querySelector<HTMLElement>("[data-demo-hint]");
  const tiles = Array.from(root.querySelectorAll<HTMLButtonElement>(".tile"));
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const hintIdle = hint?.textContent ?? "";

  type Phase = "ready" | "busy" | "done";
  let phase: Phase = "ready";
  let shown = 48.2;
  let anim = 0;

  const on = (t: HTMLButtonElement) => t.getAttribute("aria-pressed") === "true";
  const fmt = (n: number) => `${Math.max(0, n).toFixed(1)} GB`;
  // Other safe items only count while at least one card is in.
  const disk = () =>
    tiles.some(on)
      ? tiles.reduce((s, t) => s + (on(t) ? Number(t.dataset.disk ?? 0) : 0), BASE_DISK)
      : 0;
  const ram = () =>
    tiles.reduce((s, t) => s + (on(t) ? Number(t.dataset.ram ?? 0) : 0), 0);

  function countTo(target: number, ms: number, onTick?: (p: number) => void) {
    cancelAnimationFrame(anim);
    const from = shown;
    if (reduce.matches || ms === 0) {
      shown = target;
      value.textContent = fmt(target);
      onTick?.(1);
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      const start = performance.now();
      const step = (now: number) => {
        const p = Math.min(1, (now - start) / ms);
        const e = 1 - Math.pow(1 - p, 3);
        shown = from + (target - from) * e;
        value.textContent = fmt(shown);
        onTick?.(p);
        if (p < 1) anim = requestAnimationFrame(step);
        else resolve();
      };
      anim = requestAnimationFrame(step);
    });
  }

  function renderReady() {
    const d = disk();
    const r = ram();
    label.textContent = "You can get back";
    sub.textContent = r > 0 ? `of disk, and ${r.toFixed(1)} GB of memory` : "of disk, and no memory";
    const anyOn = tiles.some(on);
    cta.disabled = !anyOn;
    cta.textContent = anyOn ? `Clean ${fmt(d)}` : "Nothing selected";
    say(anyOn ? `You can get back ${fmt(d)}` : "Nothing selected");
    countTo(d, 400);
  }

  tiles.forEach((t) =>
    t.addEventListener("click", () => {
      if (phase !== "ready") return;
      t.setAttribute("aria-pressed", on(t) ? "false" : "true");
      renderReady();
    }),
  );

  cta.addEventListener("click", async () => {
    if (phase === "done") {
      phase = "ready";
      root.dataset.phase = phase;
      tiles.forEach((t) => {
        t.disabled = false;
        t.style.removeProperty("--fill");
      });
      if (hint) hint.textContent = hintIdle;
      cta.classList.remove("is-undo");
      shown = 0;
      renderReady();
      return;
    }
    if (phase !== "ready") return;
    const freed = disk();
    const chosen = tiles.filter(on);
    phase = "busy";
    root.dataset.phase = phase;
    tiles.forEach((t) => (t.disabled = true));
    cta.setAttribute("aria-disabled", "true");
    cta.textContent = "Moving to the Trash…";
    say("Moving to the Trash");
    label.textContent = "Moving to the Trash";
    sub.textContent = "left to go";
    await countTo(0, 1600, (p) => {
      chosen.forEach((t, i) => {
        const slice = 1 / chosen.length;
        const f = Math.min(1, Math.max(0, (p - i * slice) / slice));
        t.style.setProperty("--fill", `${Math.round(f * 100)}%`);
      });
    });
    phase = "done";
    root.dataset.phase = phase;
    shown = freed;
    value.textContent = fmt(freed);
    label.textContent = "You got back";
    sub.textContent = "All of it is in the Trash, so you can undo.";
    cta.removeAttribute("aria-disabled");
    cta.classList.add("is-undo");
    cta.textContent = "Undo";
    say(`You got back ${fmt(freed)}. Undo is available.`);
    if (hint) hint.textContent = "This is a demo. Nothing on your Mac is touched.";
  });
}
