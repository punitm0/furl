import { site } from "../site.config";

/* ---------- Windows waitlist ---------- */
const waitlistForm = document.getElementById("waitlist-form");
if (waitlistForm) {
  const emailInput = document.getElementById("waitlist-email") as HTMLInputElement;
  const status = document.getElementById("waitlist-status") as HTMLElement;
  const submit = waitlistForm.querySelector("button[type=submit]") as HTMLButtonElement;
  waitlistForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = emailInput.value.trim();
    if (!emailInput.checkValidity() || !email) {
      status.textContent = "Enter a valid email address.";
      emailInput.focus();
      return;
    }
    if (!site.waitlistUrl) {
      status.textContent = "The waitlist isn't open yet. Check back soon.";
      return;
    }
    submit.disabled = true;
    status.textContent = "Adding you…";
    try {
      const body = new FormData();
      body.append("email", email);
      const res = await fetch(site.waitlistUrl, { method: "POST", body, headers: { Accept: "application/json" } });
      if (!res.ok) throw new Error(String(res.status));
      (waitlistForm as HTMLFormElement).reset();
      status.textContent = "You're on the list. We'll email you once, when it ships.";
    } catch (_) {
      status.textContent = "Couldn't add you just now. Please try again.";
    } finally {
      submit.disabled = false;
    }
  });
}
