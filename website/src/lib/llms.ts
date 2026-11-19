/*
 * Shared text for /llms.txt and /llms-full.txt (the llmstxt.org format): a short, plain-Markdown map of
 * the site for AI assistants and agents. Guides come straight from the content collection, so these
 * files never drift from the site.
 */
import { getCollection } from "astro:content";
import { site } from "../site.config";

const SITE = "https://getfurl.app";

export async function sortedGuides() {
  return (await getCollection("guides")).sort((a, b) => a.data.order - b.data.order);
}

export const header = `# Furl

> Furl is a free, open-source macOS app that frees disk space. It finds caches, merged git worktrees, app leftovers, duplicates, large files and leftover dev servers, explains why each one is safe, and uses the Trash by default so it can be undone. The few actions that delete for good are marked and never selected for you. Your files, file names and paths never leave your Mac.

- Runs on macOS 14 or later. Smart Review's on-device model needs macOS 26 with Apple Intelligence.
${site.checkoutUrl ? "- Pay what you like, including $0.\n" : "- Every feature is free.\n"}- Builds are ad-hoc signed, not notarized: the first launch needs System Settings → Privacy & Security → Open Anyway.
`;

export const pages = `## Pages

- [Home](${SITE}/): what Furl does, screenshots and download
- [Opening Furl the first time](${SITE}/install/): the one-time Open Anyway step on macOS
- [Privacy](${SITE}/privacy/): everything Furl sends over the network, and when
- [Changelog](${SITE}/changelog/): release notes
- [Guides](${SITE}/guides/): plain-language guides to freeing space on a Mac
- [Source code](${site.githubUrl}): the app, the stats Worker and this website
`;

export const optional = `## Optional

- [Terms](${SITE}/terms/)
- [Refunds](${SITE}/refunds/)
`;

export function guideUrl(id: string) {
  return `${SITE}/guides/${id}/`;
}

export function textResponse(body: string) {
  return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
}
