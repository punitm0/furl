---
title: "Remove merged git worktrees safely"
description: "Agents and parallel branches leave worktrees behind, each with its own build output and dependencies. How to find the merged ones and remove them without losing work."
metaDescription: "Agents and parallel branches leave git worktrees behind, each with its own build output and dependencies. How to find the merged ones and remove them safely."
cover: /guides/worktrees.svg
order: 11
audience: developers
readingMinutes: 4
tldr:
  - "`git worktree list` shows them, and `git branch --merged main` shows which branches are fully merged."
  - "Squash and rebase merges don't show up there. An empty `git diff main...<branch>` confirms nothing is missing."
  - "`git worktree remove` refuses when there are uncommitted changes, which makes it the safe way to delete one."
updated: 2026-11-18
---

A git worktree is safe to remove once its branch is merged and it has no uncommitted changes. Check with `git branch --merged main`, or an empty `git diff main...<branch>` for squash merges, then delete it with `git worktree remove`.

Git worktrees let you check out several branches at once, each in its own folder. Coding agents use them heavily. Each worktree is a full checkout, and once you've built in it, it often has its own `node_modules` or build folder too, so a handful of old ones can easily reach several gigabytes.

## List them

From inside the repository:

```sh
git worktree list
```

## Find the ones whose branch is merged

```sh
git branch --merged main
```

Any worktree whose branch shows up here has had all of its commits merged. One catch: **squash and rebase merges don't show up**, because the commits on `main` are new ones. For those, check whether the branch's pull request was merged, or compare the content:

```sh
git diff main...<branch> --stat
```

An empty diff means nothing on that branch is missing from `main`.

## Remove one

```sh
git worktree remove <path>
```

Git refuses if the worktree has uncommitted changes, which is exactly the safety net you want. Only add `--force` once you've looked at what would be lost.

If you already deleted a worktree folder by hand, clean up git's records with:

```sh
git worktree prune
```

## How Furl handles it

Furl finds worktrees across your projects and marks each one as merged, squash-merged or still active. It works this out from your local git history only: squash and rebase merges are detected by comparing content, the same idea as the `git diff` check above, so nothing is looked up online.

Ones with uncommitted changes are never selected. Removing one runs `git worktree remove`, so the folder is deleted for good rather than moved to the Trash. Its commits stay in the repository unless you also delete the branch, and only worktrees with nothing uncommitted are offered. The menu bar's **Clean safe items** includes these merged worktrees alongside caches rated Safe. The caches go to the Trash, and the run is listed in History.
