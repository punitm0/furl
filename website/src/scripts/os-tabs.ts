/* ---------- Install help: macOS version tabs ----------
 * The tab bar ships hidden, so without JS the page shows both step lists, the Sonoma one under
 * its own label. With JS: Sequoia shows its four steps; Sonoma shows its two steps in their place.
 * The cards below stay for both.
 */
const wrap = document.querySelector<HTMLElement>("[data-os-tabs]");
if (wrap) {
  const tabs = Array.from(wrap.querySelectorAll<HTMLButtonElement>('[role="tab"]'));
  wrap.hidden = false;
  document.querySelectorAll<HTMLElement>("[data-nojs-label]").forEach((label) => (label.hidden = true));
  for (const tab of tabs) {
    document.getElementById(tab.getAttribute("aria-controls") ?? "")?.setAttribute("role", "tabpanel");
  }

  const select = (index: number, focus: boolean) => {
    tabs.forEach((tab, i) => {
      const on = i === index;
      tab.setAttribute("aria-selected", String(on));
      tab.tabIndex = on ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute("aria-controls") ?? "");
      if (panel) panel.hidden = !on;
    });
    if (focus) tabs[index]?.focus();
  };
  select(0, false);

  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => select(i, false));
    tab.addEventListener("keydown", (e) => {
      const last = tabs.length - 1;
      const next =
        e.key === "ArrowRight" ? (i === last ? 0 : i + 1)
        : e.key === "ArrowLeft" ? (i === 0 ? last : i - 1)
        : e.key === "Home" ? 0
        : e.key === "End" ? last
        : -1;
      if (next < 0) return;
      e.preventDefault();
      select(next, true);
    });
  });
}
