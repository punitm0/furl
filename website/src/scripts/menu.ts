/* ---------- Mobile menu ---------- */
const menuButton = document.querySelector(".menu-button");
const nav = document.getElementById("site-nav");
if (menuButton && nav) {
  const setOpen = (open: boolean) => {
    nav.classList.toggle("is-open", open);
    menuButton.setAttribute("aria-expanded", String(open));
    menuButton.setAttribute("aria-label", open ? "Close menu" : "Menu");
  };
  menuButton.addEventListener("click", () => setOpen(!nav.classList.contains("is-open")));
  nav.addEventListener("click", (e) => {
    if ((e.target as Element).closest("a")) setOpen(false);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && nav.classList.contains("is-open")) {
      setOpen(false);
      (menuButton as HTMLElement).focus();
    }
  });
}
