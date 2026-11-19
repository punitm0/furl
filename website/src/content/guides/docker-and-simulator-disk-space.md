---
title: "Free up Docker and iOS Simulator disk space"
description: "Docker images, volumes and build cache, plus old Xcode simulators and runtimes, can take 50 GB or more. The commands to see and clear them, and what can't be undone."
cover: /guides/docker-sim.svg
order: 8
audience: developers
readingMinutes: 5
tldr:
  - "`docker system df` shows what Docker holds. Build cache, dangling images and stopped containers are the low-risk clean-up."
  - "Never prune volumes without checking first: that's where local databases keep their data."
  - "Deleting unavailable simulators and old runtimes frees gigabytes. All of it is permanent."
updated: 2026-11-18
---

Two of the biggest space users on a developer's Mac don't show up as normal folders. Docker keeps everything inside one large virtual disk, and Xcode keeps simulators and their runtimes in places Finder doesn't show. Both are cleaned with their own tools, and both are **permanent**: nothing goes to the Trash.

## Docker

### See what it uses

On a Mac, Docker runs Linux in a small virtual machine, and all images, containers, volumes and build cache live inside that VM's disk image. Ask Docker itself what's inside:

```sh
docker system df
```

You get four lines (Images, Containers, Local Volumes, Build Cache), each with a **Reclaimable** column. Add `-v` for a per-image and per-volume list.

### Clear it, least risky first

```sh
docker builder prune      # unused build cache
docker image prune        # dangling images (untagged leftovers from rebuilds)
docker container prune    # stopped containers
```

- **Build cache** only costs you a slower next build.
- **Dangling images** are layers no tag points to any more.
- **Stopped containers** lose whatever was written inside them that isn't in a volume.

These go further, so read before you run them. **Volumes are the dangerous part:** a local Postgres or MySQL container keeps its data in a volume. If the container is stopped, its volume counts as unused, and pruning volumes deletes that data for good. Check `docker volume ls` first.

```sh
docker image prune -a     # every image not used by a container, including ones you pulled on purpose
```

```sh
docker volume ls          # look first: which volumes hold data you care about?
docker volume prune       # DELETES DATA: unused volumes, including stopped databases
```

Docker Desktop shrinks its disk image in the background after a prune, so Finder can take a few minutes to show the space. Check that `docker context show` points at the engine you expect before you prune, because the CLI talks to whichever engine is active.

## Xcode simulators

### Devices you can't boot any more

When you remove an iOS version, the simulators made for it stay on disk and become "unavailable". List them, then remove them:

```sh
xcrun simctl list devices unavailable
xcrun simctl delete unavailable
```

This only deletes simulators that can't run anyway. Their apps and data are gone after that.

### Old runtimes

Each simulator runtime (iOS 17, iOS 18, watchOS 11…) takes several gigabytes. List them with sizes:

```sh
xcrun simctl runtime list
```

Delete one you no longer test against by its identifier:

```sh
xcrun simctl runtime delete <identifier>
```

You can download it again in **Xcode → Settings → Components**, so this is safe as long as you don't need that version offline. `~/Library/Developer/CoreSimulator/Caches` is safe to clear too; it's rebuilt. For DerivedData, archives and device support files, see [What's safe to delete in Xcode](/guides/whats-safe-to-delete-in-xcode/).

## What's permanent

None of these can be undone, but most of them don't need to be:

- **Build cache and dangling images:** rebuilt or pulled again when needed.
- **Stopped containers:** anything written inside them that isn't in a volume is lost.
- **Volumes:** database data is lost.
- **Unavailable simulators:** they couldn't run anyway.
- **Old simulator runtimes:** you can download them again from Xcode.

## How Furl handles it

Furl lists these in the **Docker** and **iOS Simulators** groups on the Caches & Junk screen:

- **Docker:** dangling images, stopped containers and unused build cache, with their size from `docker system df`. Cleaning runs Docker's own prune commands (`docker image prune -f`, `docker container prune -f`, `docker builder prune -f`). Furl never removes volumes or tagged images. If the Docker CLI isn't installed or the engine isn't running, nothing is listed.
- **Only your local Docker engine, never a remote one.** Docker items are listed only when the CLI talks to an engine on this Mac (a `unix://` socket). If `DOCKER_HOST` or your Docker context points at a `tcp://` or `ssh://` engine, Furl shows nothing, and it checks again right before pruning in case you switched contexts in between.
- **Simulators:** unavailable devices (`xcrun simctl delete unavailable`), and every runtime except the newest of each platform, with when it was last used (`xcrun simctl runtime delete`).
- **Marked permanent.** Because these run a tool instead of moving files to the Trash, each one has a red Permanent badge, none is ever selected for you, and the confirmation says how many selected items can't go to the Trash.
- **Main window only.** Docker and simulator items are never part of the menu bar or Auto-Sweep. They only run when you choose them.
