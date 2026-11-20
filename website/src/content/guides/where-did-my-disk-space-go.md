---
title: "Where did my Mac's disk space go?"
description: "What the coloured bar in System Settings means, why “System Data” gets so big, and how to find what is really filling your disk."
cover: /guides/disk-space.svg
order: 1
audience: everyone
featured: true
readingMinutes: 5
tldr:
  - "The grey System Data slice is the catch-all: caches, logs, local snapshots, swap, Docker and AI models."
  - "`du -sh ~/* | sort -h` finds the biggest folders. Look in `~/Library/Caches`, `~/Library/Developer` and hidden folders first."
  - "Local Time Machine snapshots clear themselves when space runs low, so you can leave them."
updated: 2026-11-18
---

Most missing space hides in **System Data**: caches, logs, local snapshots, swap, Docker and AI models. In Terminal, `du -sh ~/* | sort -h` shows your biggest folders.

Open **System Settings → General → Storage** and you get a coloured bar with a few broad labels: Applications, Documents, Developer, and a very large grey slice called **System Data**. It tells you that the disk is full, but not why.

## What the slices mean

- **Applications**: the apps themselves, not the files they create.
- **Documents**: files in your home folder that macOS recognises as documents.
- **Developer**: Xcode and the files it makes, such as DerivedData, simulators and archives.
- **System Data**: everything macOS can't put in another category. That includes app caches, logs, local Time Machine snapshots, virtual memory swap files, Docker's disk image, local AI models and many hidden folders.

System Data is usually the biggest surprise, and it's also where most of the space you can safely get back is hiding.

## Find the big folders yourself

In Terminal, this lists the largest folders in your home folder, biggest last:

```sh
du -sh ~/* ~/.[!.]* 2>/dev/null | sort -h | tail -20
```

Then run the same command one level deeper in whatever looks big, for example `~/Library`:

```sh
du -sh ~/Library/* 2>/dev/null | sort -h | tail -15
```

The usual suspects are `~/Library/Caches`, `~/Library/Developer`, `~/Library/Containers` (where Docker keeps its disk image) and hidden folders such as `~/.npm`, `~/.cache` and `~/.ollama`.

## Local Time Machine snapshots

If you use Time Machine, macOS keeps local snapshots while your backup disk isn't connected. They show up as System Data and are removed on their own when space runs low. To see them:

```sh
tmutil listlocalsnapshots /
```

You rarely need to delete them by hand. macOS treats them as purgeable space.

## Faster: let Furl map it

Furl's **storage bar** splits your disk into named slices instead of one grey block: macOS & system, purgeable space, apps, caches & junk, your files, and free space. Grey is what you keep. Colour is what you could clear. Click any slice and it explains what's in it, how much you could get back, and which screen to open. [What is System Data on a Mac?](/guides/what-is-system-data-on-mac/) explains each one.

- **Find (⌘F)** searches the results of every scan at once (caches, worktrees, large files, duplicates, apps and Smart Review), so you can type a name and see where it is and how big it is.
- **The Inspector** opens beside any result. It shows the facts read from disk, why the item was flagged, whether it's safe to remove, what rebuilds it, and the largest things inside.
- **History** lists every cleanup on one timeline, with how much disk you freed each week. You can undo a cleanup from there while its files are still in the Trash.

Files go to the Trash, so you can undo. The few things that can't, like Docker data and old simulator runtimes, are marked Permanent and never selected for you.

*Coming soon: **Why is my disk full?**, which explains local snapshots and other space that disappears without a visible file.*

## Next steps

- [What's safe to delete in Xcode](/guides/whats-safe-to-delete-in-xcode/)
- [Clean node_modules, Docker and other dev caches](/guides/clean-dev-caches/)
- [What is System Data on a Mac?](/guides/what-is-system-data-on-mac/)
