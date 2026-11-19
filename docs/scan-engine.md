# Scan engine

A shared, fast file-system index for Furl. One parallel walk of a root (normally `~`) answers Caches &
Junk, Large Files, Duplicates (size buckets), Smart Review and Space Map. The index is saved to disk and
patched from FSEvents on the next scan, so a repeat scan re-reads only the folders that changed.

Phase 1 added the engine as new files. Phase 2 (done) moved Junk, Large Files, Duplicates, Space Map and
Worktrees onto it; Smart Review and App Uninstaller still walk on their own (see "Known gaps").
Measurements: [scan-benchmarks.md](scan-benchmarks.md).

Source: `Sources/Furl/Services/ScanEngine/`

| File | What it does |
|---|---|
| `BulkDirectoryReader.swift` | `getattrlistbulk(2)` reader + `PackageDetector` |
| `WalkPolicy.swift` | `WalkPolicy` (index / size-only / skip per folder), `RetainRule` (which files to keep) |
| `ParallelWalker.swift` | Bounded-width parallel walk into an `IndexBuilder` |
| `FileIndex.swift` | Records, the immutable `FileIndex`, queries, `IndexVisitor`, `IndexBuilder` (compact/totals) |
| `IndexStore.swift` | Compact binary persistence in `~/Library/Application Support/Furl/ScanIndex/` |
| `FSEventsChanges.swift` | `ChangeSet`, `FSEventsHistory` (replay since an event ID), `FSEventsCollector` (live) |
| `ScanEngine.swift` | Facade: full build, load + incremental patch + save |
| `SpotlightFastPath.swift` | Instant, approximate "files > N MB" and last-used dates from Spotlight |
| `ScanIndexCache.swift` | Phase 2: app-wide coalesced home index (`ScanIndexCache`), `ScanIndexContext` task-local, scanner query helpers |

## How it is fast

1. **`getattrlistbulk` instead of `FileManager.enumerator` + `resourceValues` + `getattrlist`.** One syscall
   returns ~hundreds of entries with name, type, file ID, link count, data length, allocated size, **APFS
   private size** (`ATTR_CMNEXT_PRIVATESIZE` via `FSOPT_ATTR_CMN_EXTENDED`), dates, BSD flags, Finder flags
   and mount status. The old path does `readdir` + an `NSURL` + a `stat`-family call per key per file, then a
   separate `getattrlist` per file for the private size.
2. **Parallel.** A fixed pool of worker threads (default 8, benchmarked) pulls directories from a shared LIFO
   stack. Threads, not a task group: `getattrlistbulk` blocks in the kernel and would starve Swift's
   cooperative pool (one thread per core) for every other async task in the app. The public API is still
   `async` and honours `Task` cancellation.
3. **One walk for everything.** Today Scan All walks overlapping trees five times concurrently (they contend
   for the same disk/metadata cache), and Smart Review / Space Map walk home again.
4. **Compact index.** Parent-pointer tree (paths are interned; built on demand), plain-old-data records, names
   in one byte buffer. Only files ≥ 32 KB (configurable) are kept individually; every byte still counts in
   folder totals. Size-only folders (`node_modules`, `.git`, packages…) keep one record.
5. **Incremental.** The index stores the FSEvents event ID taken *before* the walk. Next time, history since
   that ID tells us which directories changed; only those are re-read.

## Accuracy (unchanged from `FileSizeHelper`)

Per file, exactly the old `FileSizeHelper.reclaimableFileSize` rule:

- link count > 1 → 0 (a hard-linked file frees nothing until every link is gone),
- else APFS private size when the volume reports it (clone-aware),
- else allocated size, else logical size (non-APFS volumes).

Symlinks are neither followed nor counted; hidden files and package contents are counted. Verified against
`FileSizeHelper.directorySize` on real folders and on a temp folder of `cp -c` clones (one partially
rewritten), hard links, small files, a symlink and a fake `.app` — totals and every per-file private size
match exactly (see benchmarks). `DirRecord.totalAllocated` is the Finder-style size Space Map shows today.

Fallbacks: volumes that don't return `ATTR_CMNEXT_PRIVATESIZE` simply omit it (allocated size is used); a
volume that rejects `FSOPT_ATTR_CMN_EXTENDED` with `EINVAL`/`ENOTSUP` is remembered and re-read without it.
Per-entry kernel errors (`ATTR_CMN_ERROR`) keep whatever attributes came back. Unreadable folders are flagged
`.unreadable`, their ancestors `.incomplete`, and `ScanProgress.addUnreadable()` is called.

## API

```swift
// Full walk (no persistence)
let index = try await ScanEngine.buildIndex(root: NSHomeDirectory(), progress: progress)

// Persistent + incremental: loads ~/Library/Application Support/Furl/ScanIndex/<hash>.sweepindex,
// replays FSEvents, re-reads changed folders, saves. Falls back to a full walk when needed.
let (index, report) = try await ScanEngine.index(root: NSHomeDirectory(), progress: progress)
// report.kind: .full(reason:) | .incremental(shallow:deep:) | .unchanged

// Live updates while the app runs
let watcher = FSEventsCollector(roots: [index.rootPath])
watcher.startLive()
// … later (e.g. when a tab appears):
let (patched, _) = try await ScanEngine.apply(watcher.drain(), to: index, newEventID: FSEventsHistory.currentEventID())
// patched == nil → changes were too broad; call ScanEngine.index/buildIndex instead.
```

`ScanProgress` works as today: `addItems` per directory read (entries), `addUnreadable`, `setPhase`
("Reading folders", "Adding up sizes", "Checking what changed", "Updating N changed folders"), and
`progress.cancel()` or cancelling the Task stops all workers promptly (`CancellationError`).

### Configuration

```swift
var config = ScanEngine.Configuration(root: home)   // WalkPolicy.forRoot adds "/" firmlink skips
config.width = 8                                     // worker threads
config.retain.minBytes = 32 * 1024                   // smallest file any feature lists individually
config.policy.sizeOnlyNames.insert("Carthage")       // sized once, contents not kept
config.policy.skippedPaths = ["/Volumes"]            // never entered
```

`WalkPolicy` modes: `.indexed` (children walked, large-enough files kept), `.sizeOnly` (walked for size
only — packages, `node_modules`, `.git`, `DerivedData`, `.venv`, `__pycache__`, `.next`, `Pods`, `.gradle`,
`.build`… — shown as one item; so `.git/objects` never reaches Large Files), `.skipped` (other volumes,
excluded paths). Packages are detected from Finder's `kHasBundle` bit, a known extension list, then
`UTType(filenameExtension:conformingTo: .directory).conforms(to: .package)` (cached per extension).
A different policy/retain fingerprint invalidates the saved index.

### Querying a `FileIndex`

```swift
index.root.totalReclaimable / .totalAllocated / .totalLogical / .totalFiles / .totalDirs / .newestModified
index.dirID(forPath:) -> Int32?                 // folder lookup
index.reclaimableSize(ofPath:) -> Int64?        // drop-in for FileSizeHelper.directorySize when covered
index.children(ofDir:) / index.files(inDir:)    // Space Map tree
index.path(ofDir:) / index.path(of: file)       // build paths on demand
index.directories(named: ["node_modules"])      // already sized, one item each
index.largeFiles(minBytes:include:)             // largest first, Finder size
index.sizeBuckets(minBytes:include:)            // duplicate candidates, hard links counted once
index.accept([visitorA, visitorB])              // IndexVisitor plug-ins: one pass over dirs then files
```

`FileRecord`: `logicalSize` (= `fileSize`), `allocatedSize` (= `totalFileAllocatedSize`), `privateSize`,
`reclaimableSize`, `displaySize`, `linkCount`, `fileID`, `bsdFlags` (UF_HIDDEN, SF_DATALESS…),
`modified/accessed/created`. `DirRecord`: own + total aggregates, `mode`, `flags` (`.package`, `.hidden`,
`.unreadable`, `.incomplete`, `.mountPoint`).

### Incremental details

- Stored with the index: last event ID, FSEvents database UUID of the volume (`FSEventsCopyUUIDForDevice`),
  policy fingerprint, build date.
- **Full walk instead of patching** when: no index; config changed; UUID changed (database reset);
  index older than `maxIndexAge` (7 days); any event with `UserDropped`/`KernelDropped` (history dropped),
  `EventIdsWrapped`, `RootChanged`, or `Mount`/`Unmount` inside the root; `MustScanSubDirs` on the root;
  more than `maxIncrementalDirectories` (20 000) folders to patch; history replay timeout.
- Otherwise each changed path maps to: an **indexed** folder → shallow re-read (files replaced, existing
  sub-folders keep their subtrees, new sub-folders are walked, vanished ones dropped); `MustScanSubDirs` →
  deep re-walk of that folder; a path **inside a size-only folder** → that folder is re-sized; a path not in
  the index → shallow re-read of the nearest known ancestor (discovers the new folder).
- Real paths from FSEvents (`/private/var/...`) are mapped back to the root's spelling.
- The new event ID saved is the one taken *before* replaying, so changes made during the patch are replayed
  again next time (re-reads are idempotent).

### Spotlight fast path

`SpotlightFastPath.largeFiles(minBytes:scopes:)` returns Spotlight's answer in well under a second —
`Hit.isApproximate == true`: logical sizes (not clone-aware), Spotlight-excluded and unindexed folders and
most of `~/Library` are missing. Use it to fill the Large Files list instantly, then replace with the
engine's results. `lastUsedDates(for:)` batches `kMDItemLastUsedDate`. It uses the synchronous `MDQuery`
C API (what `NSMetadataQuery` wraps) so it runs off the main thread without a run loop.

## Phase 2: how the scanners use it (implemented)

- `AppState.scanWorktrees/scanJunk/scanLargeFiles/scanDuplicates/scanSpace` first `await
  ScanIndexCache.shared.homeIndex(progress:)`, then run the scanner inside
  `ScanIndexContext.$index.withValue(index) { … }`. Scan All's five concurrent scans share one walk; a scan
  within 3 s reuses the result; later scans patch the saved index from FSEvents. Duplicates and Space Map
  pass their `ScanProgress`: the shared walk's counters are mirrored into it, and cancelling stops waiting
  (the shared walk keeps going for the others and is saved).
- Every scanner keeps its old walk as the fallback: no index (build failed), a root outside home, a
  threshold below the index's 32 KB keep size, or "/" / other volumes in Space Map.
- `FileSizeHelper.directorySize` answers from the task-local index when the path is covered, so every
  caller inside a scan (Junk's caches/logs/AI models/simulators, Worktrees) stops walking.
- Junk: dev-artifact folders come from `directories(named:)` under the project roots (same exclusions:
  `.git`, `Library`, `.Trash`, packages, nested inside another heavy folder; `isGenuineArtifactDir` kept);
  `.DS_Store` files from kept file records.
- Large Files / Duplicates: kept file records with the same hidden/package/skip-folder rules.
- Space Map: `SpaceNode` tree built from the index (Finder-style allocated sizes, same 1 MB / 150-children
  folding; files under 32 KB only appear inside "N smaller items", which is where the old walk put them).
- Worktrees: `gh pr list` removed — merged status is local only (`branch --merged`, `git cherry`, synthetic
  squash commit). Checkouts and repos are inspected in parallel; sizes come from the index.

### Known gaps / follow-ups

1. **Size-only folders re-size completely on any change.** On a busy machine the home incremental took
   13–20 s, almost all re-sizing `.git` folders of repos being committed to. Fix: keep sub-folder records 2
   levels deep inside size-only folders (≈ +50 % dir records) so a change in `.git/objects/ab` re-reads
   only that folder.
2. **Space Map can no longer drill into `node_modules`, `.git`, `.venv`, … in home** — they are leaf
   folders with correct sizes (packages already were). Scanning that folder directly via "Analyze
   folder…" still works (it falls back to the walk since the path isn't an indexed folder).
3. **Smart Review and App Uninstaller are not migrated** (not in this phase's scope). Smart Review can use
   `index.files` with its skip list (the 32 KB keep size was chosen for it); App Uninstaller's
   `~/Library` sizes already benefit only if it runs inside a `ScanIndexContext` — it doesn't yet.
   Auto-Sweep (`AppState+Automation`) also calls `JunkScanner.scan` without an index.
4. `WorktreeScanner` still runs `git commit-tree` for squash detection, which writes a dangling commit
   object into the user's repo on every scan; see recommendation 4 below.
5. Cold-cache numbers are still missing (needs `sudo purge`).

## Phase 2 migration plan (original; kept for reference)

Shared step: `AppState` owns one `FileIndex` for home (`ScanEngine.index(root: home)`), started by Scan All
or the first tab that needs it; every scanner below takes the index as input instead of walking. Keep the
old code path behind the existing functions until each tab is verified, then delete it. Optionally keep a
live `FSEventsCollector` while the window is open and `apply` it when a tab appears.

| Scanner | Today | With the engine |
|---|---|---|
| **JunkScanner** — dev artifacts | enumerates project roots, `directorySize` per `node_modules`/`.venv`/`target`… | `index.directories(named:)` filtered to project roots (`index.isInside`), sizes from `totalReclaimable`, age from `newestModified`/`modified`. `isGenuineArtifactDir` (Cargo.toml/pyvenv.cfg checks) stays: for `target`, check `files(inDir: parent)` names; for venv, a single `access()`. Fixed Xcode paths → `index.reclaimableSize(ofPath:)`. |
| JunkScanner — package caches, `~/Library/Caches/*`, `~/Library/Logs/*` | `directorySize` per folder | `reclaimableSize(ofPath:)` / `children(ofDir:)`. ~/Library is in the home index. The new AI-model/Docker/simulator categories from the smartreview-support branch should use the same lookup for on-disk sizes (their `docker`/`simctl` commands are unaffected). |
| JunkScanner — installers in Downloads | `contentsOfDirectory` + per-file attrs | `files(inDir: dirID("~/Downloads"))` with extension + `modified` filter. |
| JunkScanner — `.DS_Store` | full enumeration of project roots | `index.files` filtered by name (kept by `RetainRule.alwaysKeepNames`), under project roots. |
| **LargeFilesScanner** | enumerates home minus Library/.Trash/Applications | `index.largeFiles(minBytes:include:)` with `include` excluding those top-level folders and hidden entries (`.hidden` flag / dot names) to match today's `.skipsHiddenFiles`. Optionally show `SpotlightFastPath` hits first (marked approximate). |
| **DuplicateScanner** | enumerates 6 roots, buckets by size, hashes | `index.sizeBuckets(minBytes:include:)` restricted to the roots and excluding its skip names (`build`, `dist`, `target`, `Library`, `.Trash`, hidden) via an ancestor-name check; then the existing partial/full SHA-256 confirmation unchanged. `privateBytes` comes from `FileRecord.privateSize` (no extra `getattrlist`). |
| **SmartReviewScanner** | enumerates home with its skip list, `resourceValues` per file, `MDItem` per candidate | iterate `index.files` (≥ 32 KB in Downloads/Desktop, ≥ 512 KB elsewhere — matches `RetainRule.minBytes`), apply its `skipDirs`/`skipTopLevel` via ancestor names, feed `evaluate` from `FileRecord` dates. Keep per-candidate `MDItem` lookups (only for files that pass the size/rule pre-filter) or batch them with `SpotlightFastPath.lastUsedDates`. |
| **SpaceAnalyzer** | its own recursive walk (concurrentPerform at depth ≤ 2) | build `SpaceNode`s from `children(ofDir:)` + `files(inDir:)` using `totalAllocated` (Finder size, as today) and the same 1 MB / 150-children "smaller items" folding. Packages and size-only folders appear as leaf directories with `isPackage`. For "/" and other volumes use a separate index with `WalkPolicy.forRoot`. Also fixes the two existing Sendable warnings in `SpaceAnalyzer.swift` by deleting that walk. |
| **WorktreeScanner** | walks roots to depth 4 looking for `.git`; per worktree `directorySize` + many `git` calls + `gh` | repo discovery: `index.directories(named: [".git"])` under the project roots (depth ≤ 4); worktree sizes: `reclaimableSize(ofPath:)`. Git calls: see below. |
| **AppUninstallerService** | reads app bundles + Library locations | sizes of `.app` bundles in `/Applications` need a separate small index (or keep `directorySize` — apps are few); `~/Library/{Application Support,Caches,Containers,…}` entries → `reclaimableSize(ofPath:)` from the home index. Bundle-ID/plist logic unchanged. |
| **FileSizeHelper.directorySize** | used for single items everywhere | keep as the fallback for paths outside the index; add an `index`-first lookup at call sites. |

### WorktreeScanner: `git` / `gh` calls

Per repository: `git worktree list --porcelain`, `symbolic-ref` (+ up to 3 `show-ref`), `branch --merged`,
`rev-parse` base. Per worktree: `git status --porcelain` (slowest — it stats the whole working tree),
`git show -s` (date), and for unmerged branches `git cherry`, `merge-base`, `rev-parse ^{tree}`,
**`git commit-tree`** (writes a dangling commit object into the user's repo on every scan), `git cherry`
again, `rev-parse` tip, and **`gh pr list`** (network).

Recommendations:

1. ~~Make `gh pr list` opt-in~~ — **removed** in phase 2: the app makes no network calls. Branches merged
   only on GitHub with rewritten history (and not detectable by `cherry`/squash check) show as unmerged.
2. ~~Parallelise per repo and per worktree~~ (done in phase 2) with a bounded `TaskGroup`/`concurrentPerform` (width ~4–6;
   git is CPU+IO heavy). Repos are independent; within a repo, `status`/`show`/squash checks per worktree are
   independent once `baseBranch`/`mergedBranches` are known.
3. **Cheaper calls**: replace the per-worktree `git show -s` with one
   `git for-each-ref --format='%(refname:short) %(objectname) %(committerdate:unix)' refs/heads` per repo;
   use `git status --porcelain --untracked-files=no -z` first (fast), and only check untracked files if
   that's clean; skip squash detection entirely for branches already in `--merged`.
4. **Avoid writing objects**: replace `commit-tree` + `cherry` with
   `git diff --quiet <merge-base> <branch> -- . ` vs patch-id comparison (`git diff merge-base branch |
   git patch-id --stable` against `git log -p base --since=<merge-base date> | git patch-id --stable`), or
   at minimum run `commit-tree` with `GIT_OBJECT_DIRECTORY` pointed at a temp dir plus
   `GIT_ALTERNATE_OBJECT_DIRECTORIES` = the repo's objects, so nothing is written to the user's repo.
5. Cache per-repo results keyed by `HEAD`/ref mtimes (`.git/refs`, `packed-refs`, `logs/HEAD` from the
   index's `modified` dates) so an unchanged repo is skipped on rescan.

## Notes for the merge

- `Package.swift` has one developer-only target, `ScanBench` (`Sources/ScanBench`). It compiles selected
  app files through per-file symlinks in `Sources/ScanBench/Linked/Services` (the scanners, `FileSizeHelper`,
  `ShellRunner`, `DiskInfoService`, `DeletionService`, the `ScanEngine` folder) plus `Models/`. Files that
  depend on `AppState` (Auto-Sweep, notifications…) are deliberately not linked. Built with
  `-suppress-warnings` so app warnings aren't reported twice; the app target is unaffected.
- The engine depends only on Foundation, Darwin, CoreServices and UniformTypeIdentifiers (already linked)
  and on `ScanProgress` from `CleanupModels.swift`.

## Automatic project roots

`ProjectRootDiscovery` (in `ScanEngine/`) replaces the hand-picked "Project Scan Folders":

- `discover(in:excluded:)` — outermost folders in the home index that contain a `.git` folder or file
  (repos, linked worktrees, submodules), a manifest (`package.json`, `Cargo.toml`, `pyproject.toml`,
  `go.mod`, `Gemfile`, `pom.xml`, `build.gradle(.kts)`) or an `.xcodeproj`/`.xcworkspace`. Skips
  `~/Library`, the Trash, `~/Applications`, hidden top-level folders (`~/.npm`, `~/.cargo`, `~/.vscode`…),
  size-only folders (`node_modules`, packages, `.git`) and user exclusions. Nested projects are folded
  into the outermost one. Pure index query (~0.01 s for 5 M files), so it follows FSEvents updates.
- `gitRepositories(in:within:)` — outermost checkouts under given roots; `WorktreeScanner` uses it for
  indexed roots instead of walking each root to depth 4 (other roots, e.g. external drives, still walk).
- To find markers, `RetainRule.defaultKeepNames` keeps those small files in the index (compared as bytes,
  no per-file String). This changes the config fingerprint, so the first scan after updating rebuilds the
  saved index once.
- `AppState.projectRoots` is now computed: discovered roots + Settings › Scanning › "Also scan", minus
  "Exclude" (results inside excluded folders are dropped too). Before the first discovery it falls back to
  `WorktreeScanner.defaultSearchRoots()`. The old `projectRoots` default is migrated once: folders outside
  home → "Also scan", folders inside home dropped (discovery covers them).

Measured on this Mac (`ScanBench roots`, same index): old roots `~/Documents/projects` → 85 worktrees,
17 junk items (5.82 GB); discovered (297 roots) → the same 85 worktrees, 23 junk items (6.99 GB) — a
superset, adding `~/code/project-b` and `~/code/project-a` (`node_modules` and `.DS_Store` files).
Junk 0.21 → 0.39 s; Worktrees 5.9 → 8.9 s (more repos found and inspected).
