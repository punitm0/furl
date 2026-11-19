import { site } from "../site.config";

/* ---------- Mobile: send the page to your Mac ---------- */
const shareButton = document.getElementById("share-button");
const shareHint = document.getElementById("share-hint");
if (shareButton) {
  const pageUrl = site.siteUrl || window.location.href.split("#")[0];
  shareButton.addEventListener("click", async () => {
    if (navigator.share) {
      try {
        await navigator.share({ title: "Furl", text: "Download Furl on my Mac", url: pageUrl });
        return;
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return; // user closed the sheet
      }
    }
    try {
      await navigator.clipboard.writeText(pageUrl);
      if (shareHint) shareHint.textContent = "Link copied. Paste it anywhere you'll see on your Mac.";
    } catch (_) {
      window.location.href =
        "mailto:?subject=" + encodeURIComponent("Furl for my Mac") +
        "&body=" + encodeURIComponent("Download Furl on my Mac: " + pageUrl);
    }
  });
}
