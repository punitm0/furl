/* ---------- "On this page": highlight the section being read ---------- */
const toc = document.querySelector<HTMLElement>("[data-toc]");
if (toc && "IntersectionObserver" in window) {
  const links = Array.from(toc.querySelectorAll<HTMLAnchorElement>('a[href^="#"]:not([data-toc-skip])'));
  const sections = links
    .map((a) => document.getElementById(a.hash.slice(1)))
    .filter((s): s is HTMLElement => s !== null);

  const setCurrent = (id: string) => {
    links.forEach((a) => {
      if (a.hash === "#" + id) a.setAttribute("aria-current", "true");
      else a.removeAttribute("aria-current");
    });
  };

  const visible = new Set<string>();
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) visible.add(e.target.id);
        else visible.delete(e.target.id);
      });
      // The first section (in page order) that is on screen is the current one.
      const first = sections.find((s) => visible.has(s.id));
      if (first) setCurrent(first.id);
    },
    { rootMargin: "-10% 0px -55% 0px" },
  );
  sections.forEach((s) => observer.observe(s));
}
