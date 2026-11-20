---
title: "What's safe to delete in Xcode"
description: "DerivedData, simulators, device support files and archives: which ones rebuild themselves, which ones you should keep, and the commands to clean them."
cover: /guides/xcode.svg
order: 7
audience: developers
readingMinutes: 6
tldr:
  - "DerivedData, old device support files and Xcode's caches rebuild themselves, so they're safe to delete."
  - "Remove unavailable simulators and old runtimes with `xcrun simctl`. It's permanent, but runtimes can be downloaded again."
  - "Keep archives for versions people still run: their dSYM files decode crash reports."
updated: 2026-11-18
---

In Xcode, DerivedData, old device support files and caches are safe to delete because they rebuild themselves. Unavailable simulators and old runtimes can go too. Keep archives for app versions people still run.

Xcode is often the single biggest thing on a developer's Mac. The app itself is around 12 GB, and everything it creates around it can add another 20 to 50 GB. Most of that rebuilds itself.

## Safe to delete: DerivedData

`~/Library/Developer/Xcode/DerivedData` holds build products and indexes. Xcode recreates them the next time you build. The only cost is a slower first build.

```sh
rm -rf ~/Library/Developer/Xcode/DerivedData/*
```

Quit Xcode first, so it isn't writing there while you delete.

## Safe to delete: device support files

`~/Library/Developer/Xcode/iOS DeviceSupport` (and the watchOS and tvOS versions) contains debug symbols for every OS version of every device you've plugged in. Old versions are dead weight. Xcode copies them again when you connect a device running that version.

## Safe to delete: unavailable simulators

Simulators for runtimes you no longer have installed can be removed in one go:

```sh
xcrun simctl delete unavailable
```

Whole simulator runtimes are bigger, often 5 to 8 GB each. List them, then delete the ones you don't test on anymore:

```sh
xcrun simctl runtime list
xcrun simctl runtime delete <runtime-id>
```

## Keep, or think first: archives

`~/Library/Developer/Xcode/Archives` contains every build you archived for TestFlight or the App Store, including its **dSYM** files. You need those to read crash reports from that version. Delete archives for versions nobody runs anymore, but keep the ones that are still live.

## Caches you can clear

- `~/Library/Caches/com.apple.dt.Xcode`: Xcode's own cache.
- `~/Library/Developer/CoreSimulator/Caches`: rebuilt by the simulator.
- `~/Library/Caches/org.swift.swiftpm`: Swift Package Manager downloads, fetched again when needed.

Both commands are **permanent**: simulators and runtimes don't go to the Trash. A deleted runtime can be downloaded again from **Xcode → Settings → Components**. For more on simulators, and on Docker, see [Free up Docker and iOS Simulator disk space](/guides/docker-and-simulator-disk-space/).

## How Furl handles it

On the **Caches & Junk** screen, DerivedData and CoreSimulator caches are rated Safe and selected for you. Device support files are rated Moderate, and Archives are rated Review, so they're never pre-selected. These go to the Trash, so a mistake is one Undo away.

Simulators are handled differently. Unavailable devices and every runtime except the newest per platform are listed in the **iOS Simulators** group, each runtime with its version and when it was last used. They're removed with `xcrun simctl`, the same commands as above, so they can't go to the Trash. Each one carries a red **Permanent** badge, none is selected for you, and the confirmation tells you how many selected items will be removed permanently.
