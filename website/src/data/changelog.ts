/*
 * /changelog entries, newest first (ChangelogPage board).
 * Each release has a title, a one-sentence lead and only the groups that have items,
 * always in the order New, Improved, Fixed. The page id of an entry is its version (/changelog#1.0.0, matching the app's release tag without the "v").
 */

export const V1_0_DATE = "19 November 2026";

export type ChangeItem = {
  /** Bold lead-in naming the feature, without the trailing full stop. Optional. */
  lead?: string;
  text: string;
};

export type Release = {
  version: string;
  date: string;
  title: string;
  lead: string;
  /** Shown in the Download row of the latest release only. */
  meta?: string;
  new?: ChangeItem[];
  improved?: ChangeItem[];
  fixed?: ChangeItem[];
  /** Optional note under the groups, e.g. a known issue. Rendered by the page. */
  knownIssue?: boolean;
};

export const releases: Release[] = [
  {
    version: "1.0.0",
    date: V1_0_DATE,
    title: "First release",
    lead: "Furl finds the caches, merged worktrees, forgotten downloads and leftover dev servers you don't need, tells you why, and uses the Trash by default so you can undo.",
    meta: "macOS 14 or later · Apple silicon and Intel · 10 MB",
    new: [
      { lead: "Overview", text: "One scan of projects, caches, apps and your home folder, then one number: how much you can get back, with a Clean button and Undo." },
      { lead: "Smart Review", text: "Finds installers for apps you already have, archives you already unzipped and recordings you never opened again, with a reason for each. Checked by Apple's on-device model." },
      { lead: "Caches & Junk", text: "node_modules, DerivedData, Docker build cache, Homebrew, package manager caches and local AI models, each rated Safe, Moderate or Review." },
      { lead: "Git Worktrees", text: "Finds merged and squash-merged worktrees and removes them with their local branches." },
      { lead: "Processes & Sessions", text: "Stops dev servers, watchers and simulators left running by closed Claude Code, Codex, Cursor, Gemini CLI and Copilot sessions, and ends idle ones." },
      { lead: "Compress and Shrink", text: "Lossless compression for PDFs, images, audio, Office files and folders; Shrink for smaller formats. Every file is checked before the original is replaced." },
      { lead: "Duplicates, Large Files, Apps & Leftovers, Space Map", text: "The rest of the toolkit for finding what takes up space." },
      { lead: "History, Snapshots, Find and the cleanup tray", text: "Undo past cleanups, see what grew over time, find any file, and clean items from every screen in one go." },
      { lead: "Menu bar, Auto-Sweep and low-disk alerts", text: "See free space at a glance, clean safe items on a schedule, and get warned before the disk fills up." },
      { lead: "Five themes", text: "Mint, Rosewood, Harbour, Sailcloth and Indigo Night, each in light and dark." },
    ],
    knownIssue: true,
  },
];
