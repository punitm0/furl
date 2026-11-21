/*
 * Shared text for /llms.txt and /llms-full.txt (the llmstxt.org format): a short, plain-Markdown map of
 * the site for AI assistants and agents. Guides come straight from the content collection, so these
 * files never drift from the site.
 */
import { getCollection } from "astro:content";
import { releases } from "../data/changelog";
import { site } from "../site.config";

const SITE = "https://getfurl.app";

export async function sortedGuides() {
  return (await getCollection("guides")).sort((a, b) => a.data.order - b.data.order);
}

const latest = releases[0];

export const header = `# Furl

> Furl is a free, open-source macOS app that frees disk space. It finds caches, merged git worktrees, app leftovers, duplicates, large files and leftover dev servers, explains why each one is safe, and uses the Trash by default so it can be undone. The few actions that delete for good are marked and never selected for you. Your files, file names and paths never leave your Mac.

- Latest version: ${latest.version} (${latest.date}). Release notes: ${SITE}/changelog/
- Runs on macOS 14 Sonoma or later, Apple silicon and Intel. Smart Review's on-device model needs macOS 26 with Apple Intelligence; without it Smart Review uses its rules only.
${site.checkoutUrl ? "- Pay what you like, including $0. Every feature is free either way.\n" : "- Every feature is free.\n"}- Open source under MIT: ${site.githubUrl}
- Download: ${site.downloadUrl}
- Builds are ad-hoc signed, not notarized: the first launch needs System Settings → Privacy & Security → Open Anyway (${SITE}/install/).
- Furl checks for updates once a day and can install them and relaunch. Each update is verified against Furl's signature first. The check can be turned off in Settings.

## Features

- Overview: disk usage, what you can get back by category, Trash size and Empty Trash, and a Move to Trash (default) vs Delete Permanently switch.
- Git Worktrees: finds merged and squash-merged worktrees in your project folders, flags dirty or locked ones, and can delete the local branch and prune.
- Caches & Junk: stale \`node_modules\`, \`.next\`, \`.venv\`, \`target\`, Xcode DerivedData, Archives and DeviceSupport, Homebrew, npm, pnpm, pip, uv and SwiftPM caches, logs and crash reports, old installers in Downloads, Docker build cache, unused iOS Simulators, and local AI models (Ollama, Hugging Face, LM Studio) to review.
- Apps & Leftovers: uninstall an app with the data it left in \`~/Library\`, and find data left behind by apps you already removed.
- Space Map: drill into your home folder, the whole disk, an external volume or any folder.
- Duplicates: identical files by content, aware of hard links and APFS clones. Furl never removes every copy.
- Smart Review: labels files that are probably useless (installers for apps you have, archives you already unzipped, unfinished downloads, old screenshots) as Likely Useless, Maybe or Keep, with a reason. Apple's on-device model double-checks the top suggestions using names, folders, sizes and dates only, never file contents.
- Large Files: files above a size you choose, grouped by type.
- Compress: lossless compression of folders you rarely open (APFS compression plus format recompressors). Every output is verified before the original goes to the Trash.
- Shrink (opt-in, lossy): re-encodes photos, videos and PDF images at lower quality, with a preview of the savings first. Skips the Photos library and cloud-synced folders.
- Processes & Sessions: finds dev servers, watchers, simulators and containers that AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, Copilot) left running, with the memory each holds, and ends idle agent sessions. Databases, tunnels and terminal multiplexers are never stopped automatically.
- Snapshots: compact daily and weekly records of your home folder's sizes, showing what grew and when.
- History and Undo: every cleanup, with Undo for anything that went to the Trash, even after a relaunch.
- Menu bar and Auto-Sweep: free space in the menu bar, low-disk alerts and optional scheduled rules. Auto-Sweep is off by default.
- Accurate sizes: counts only the bytes deleting would really free (APFS private size), so clones and hard links aren't double counted.

## Privacy

- Files, file names, paths and contents never leave your Mac.
- Every network call is listed on ${SITE}/privacy/. Only three run on their own: the anonymous community counter, the checkout-link check and the daily update check. No tracking, ads or crash reports.
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
