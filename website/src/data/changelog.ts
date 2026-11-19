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
    version: "1.2.0",
    date: "19 November 2026",
    title: "Automatic updates",
    lead: "Furl now keeps itself up to date, and you can pay what you like for it.",
    meta: "macOS 14 or later · Apple silicon and Intel · 10 MB",
    new: [
      { lead: "Automatic updates", text: "Furl checks for a new version once a day and can install it and relaunch. Each update is checked against Furl's signature before anything is replaced. You can turn the check off in Settings." },
      { lead: "Pay what you like", text: "Support Furl with any amount you choose. Furl stays free, with every feature." },
    ],
  },
  {
    version: "1.0.1",
    date: "19 November 2026",
    title: "Fixes",
    lead: "The cleanup tray fits any window, and fixes for the sidebar, Smart Review and stopped scans.",
    improved: [
      { lead: "Cleanup tray", text: "Sits beside the page as a card, and on a small window takes over the page until you close it or pick another screen." },
      { lead: "Auto-Sweep", text: "With Auto-Sweep off, its rules fade out and the card says to turn it on, so it's clear nothing runs." },
    ],
    fixed: [
      { lead: "Sidebar", text: "Its top rows no longer scroll out of sight after you jump to a screen from the Overview." },
      { lead: "Review items first", text: "Opens the cleanup tray with exactly what the Overview total counts, instead of Smart Review. Only items rated Safe are ticked." },
      { lead: "Smart Review", text: "Opens on All when nothing is rated Likely useless, and stays on a tab you pick." },
      { lead: "Stopped scans", text: "A stopped scan no longer says nothing was found, and Stop now works while your home folder is being read." },
      { lead: "Cleanup tray", text: "Screens keep their layout with the tray open, instead of going blank or running off the edge." },
      { lead: "Overview", text: "The In use, Can free and Free line no longer jumps between one line and three while scanning." },
      { lead: "Settings", text: "Automation rules no longer wrap their names one letter per line." },
    ],
  },
  {
    version: "1.0.0",
    date: V1_0_DATE,
    title: "First release",
    lead: "Furl finds the caches, merged worktrees, forgotten downloads and leftover dev servers you don't need, tells you why, and uses the Trash by default so you can undo.",
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
