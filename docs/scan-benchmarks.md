# Scan benchmarks

Measured 2026-11-18 on the development Mac: Apple M2 Pro (12 cores), APFS internal SSD, macOS 27,
home folder ≈ 5.0 M files / 557 k folders / 217 GB allocated. Release build of the `ScanBench` target:

```bash
swift build -c release --product ScanBench
.build/release/ScanBench help
```

**Caveats — read before quoting numbers.**

- **No true cold-cache runs.** `sudo purge` needs a password, so every run is warm-ish (the first pass of
  each scanner after other scans had already touched most metadata). `ScanBench … --purge` tries
  `sudo -n purge` and says whether it worked; re-run on a machine where you can purge for cold numbers.
  Pass 1 vs pass 2 below is the closest proxy we have.
- **The machine was busy.** Several other builds and editors were running in parallel (load average
  12–19), so absolute times are noisy (±15 %). Old and new were measured under the same conditions.
- Each old scanner was timed alone, as `AppState` calls it; in the app, Scan All runs five of them at once,
  contending for the same disk and metadata cache.

## Before: existing scanners (alone, as AppState calls them)

Project roots = `~/Documents/projects` (the app default on this Mac).

| Scanner | Pass 1 | Pass 2 | Result | Throughput |
|---|---:|---:|---|---|
| `JunkScanner.scan` | 164.9 s | 176.0 s | 9–12 items, 2.3–2.9 GB | — |
| `LargeFilesScanner.scan(100 MB)` | 6.3 s | 6.6 s | 0 files* | — |
| `DuplicateScanner.scan(1 MB)` | 0.21 s | 0.22 s | 7 groups | ~50 k entries/s |
| `SmartReviewScanner.scan` | 8.5 s | 9.4 s | 190 k files considered | ~21 k files/s |
| `SpaceAnalyzer.scan(home)` | 176.3 s | 197.1 s | 217 GB, 4.97 M files | ~30 k entries/s |
| `WorktreeScanner.scan` | 330.6 s | 341.0 s | 78 worktrees | dominated by `git` + `directorySize` |
| `AppUninstallerService.scan` | 42.7 s | 37.7 s | 20 apps, 54 orphan groups | — |
| **Sum of the walking scanners** (Junk + Large + Dup + Smart Review + Space Map) | **356 s** | **390 s** | | |

\* Large Files skips hidden folders, `~/Library` and dev folders; this Mac has no ≥ 100 MB files left
outside them. The engine finds 69 such files in the whole home (most in `~/Library` / hidden folders).

Junk is slow because it walks the whole project root (millions of files inside `node_modules`/worktrees)
and then re-walks every match with `directorySize`; Worktrees runs ~10 `git` processes per worktree
(`git status` stats every file of 78 worktrees) plus `directorySize` of each.

## After: one ScanEngine walk of home

`ScanBench new` (width 8). One walk produces the index every feature queries.

| | Pass 1 | Pass 2 |
|---|---:|---:|
| `ScanEngine.buildIndex(~)` | **56.8 s** | **50.3 s** |
| Files / folders seen | 4 990 499 / 556 630 | 4 990 648 / 556 678 |
| Throughput | 87.9 k files/s | 99.2 k files/s |
| Unreadable folders (TCC-protected) | 507 | 507 |
| Allocated / reclaimable | 217.35 GB / 99.06 GB | 217.35 GB / 99.07 GB |
| Kept records | 102 923 files, 98 218 folders | |
| Index size (memory = disk) | 27.7 MB | |
| `IndexStore.save` / `load` | 0.01–0.02 s / 0.01 s | |

Feature queries on the finished index (all ≤ 0.01 s): large files ≥ 100 MB (69), duplicate size buckets
≥ 1 MB (731 buckets / 2 359 candidates), `node_modules`/`.venv`/`.next`/`.turbo`/`__pycache__` folders
(3 443 folders, 4.23 GB), `.DS_Store` files (43).

### Speed-up summary

| Comparison | Old | New | Speed-up |
|---|---:|---:|---:|
| Space Map of home (SpaceAnalyzer vs engine walk) | 176–197 s | 50–57 s | **3.5×** |
| All walking features (sum of old scanners vs one walk + queries) | 356–390 s | 50–57 s | **~7×** |
| Repeat scan of home after changes (FSEvents patch, ~340–380 folders) | 125–149 s full walk (busy machine) | 13–20 s | **7–10×** |
| Repeat scan of `~/Documents` (3.3 M files) after changes | 27.1 s (full) | 0.08–0.26 s | **100–340×** |

### `FileSizeHelper.directorySize` vs engine, same folders (`ScanBench compare`)

Second run of each (both warm). The engine walk here sizes everything (no size-only pruning) exactly like
`directorySize`.

| Folder | Files | Old | New | Speed-up | Old bytes | New bytes | Match |
|---|---:|---:|---:|---:|---:|---:|---|
| ~/code/project-a/node_modules | 42 291 | 0.88 s | 0.37 s | 2.4× | 489 160 704 | 489 160 704 | exact |
| ~/code/project-b/node_modules | 34 877 | 0.72 s | 0.28 s | 2.6× | 674 799 616 | 674 799 616 | exact |
| ~/Library/Developer (DerivedData etc.) | 18 115 | 0.76 s | 0.24 s | 3.1× | 1 258 225 664 | 1 258 225 664 | exact |
| ~/.npm | 1 316 | 0.09 s | 0.02 s | 3.8× | 312 827 904 | 312 827 904 | exact |
| ~/Library/Caches | 80 628 | 7.26 s | 1.34 s | 5.4× | 5 201 334 272 | 5 201 334 272 | exact |
| mac-storage-utility/.build | 4 164 | 0.11 s | 0.04 s | 3.0× | 509 280 256 | 509 280 256 | exact |
| ~/Downloads | 4 989 | 0.11 s | 0.02 s | 4.9× | 4 063 232 | 4 063 232 | exact |

### Clone / hard-link accuracy (`ScanBench clones`)

Temp folder: 8 MB original, three `cp -c` clones (one with 1 MB rewritten → private blocks), a 2 MB file
with two extra hard links, 50 small files, a symlink, and a fake `Fake.app` package.

| Path | `directorySize` | Engine reclaimable | Engine Finder-style (allocated) | Match |
|---|---:|---:|---:|---|
| (root) | 1 556 480 | 1 556 480 | 40 353 792 | exact |
| /sub | 1 253 376 | 1 253 376 | 21 176 320 | exact |
| /sub/deeper | 1 048 576 | 1 048 576 | 10 485 760 | exact |
| /Fake.app (size-only package) | 303 104 | 303 104 | 303 104 | exact |

Every kept file's `privateSize` from `getattrlistbulk` also equals `FileSizeHelper.privateSize` (per-file
`getattrlist`). Allocated vs reclaimable shows why clone-awareness matters: 40 MB "on disk" vs 1.5 MB freed.

### Incremental (FSEvents) — `ScanBench incremental`

`~/Documents` (3.3 M files, busy: other builds were writing into it):

| Step | Kind | Time |
|---|---|---:|
| First scan, no saved index | full | 27.12 s |
| Rescan, nothing of ours changed | incremental (1 folder) | 0.096 s |
| After creating 2 files, 3 folders, a `node_modules` | incremental (2 shallow, 1 deep) | 0.078 s |
| After deleting a sub-folder | incremental (4 shallow, 3 deep) | 0.259 s |

The changed subtree in the patched index equals a fresh full walk byte-for-byte (3 756 032 B, then
3 055 616 B after the delete), and the deleted folder is gone from the index. Whole-root totals differ by a
few files only because other processes changed files between the two walks.

Whole home (`ScanBench incremental` / `phase2`, machine very busy — load 16–19, several parallel builds):

| Step | Kind | Time |
|---|---|---:|
| First scan, no saved index | full | 125–149 s |
| Rescan minutes later | incremental (332–365 shallow, 8–15 deep, ~1 300–1 450 events) | 13.2–20.2 s |
| After our test changes | incremental (29 shallow, 5 deep) | 20.1 s |
| After deleting a sub-folder | incremental (114 shallow, 12 deep) | 16.5 s |

The playground subtree again matched a fresh walk exactly. FSEvents replay itself takes ~0.5 s; the rest
is deep re-sizing of size-only folders that other processes were writing into — `.git` of five busy repos,
a worktree's `.build`, `~/Library/Caches/org.swift.swiftpm`, the Photos library. A size-only folder has
no sub-folder records, so any change inside it re-sizes the whole folder. See "Known gaps" in
scan-engine.md for the fix (keep 2 levels of sub-folder records inside size-only folders).

### Worker width (`ScanBench widths`, home, warm)

| Width | 2 | 4 | 8 | 12 | 16 | 24 |
|---|---:|---:|---:|---:|---:|---:|
| Time | 101.4 s | 57.6 s | 61.4 s | 54.8 s | 58.3 s | 61.0 s |

Flat from 4 to 24 (within noise on a loaded machine): the walk is **kernel-bound** — 14 s user vs 1 601 s
system CPU over the seven walks. Default **8**: at the plateau with headroom, and leaves cores free for the
UI and other work.

### Where the kernel time goes: APFS private size

`ScanBench widths ~/Library --no-private` (benchmark-only switch):

| ~/Library, 1.13 M files, width 8 | Wall | System CPU (whole sweep) |
|---|---:|---:|
| With `ATTR_CMNEXT_PRIVATESIZE` | 24–32 s | 345–365 s |
| Without | 13 s | 170 s |

Private size roughly doubles the cost (APFS must inspect extents per file), but it is what makes sizes
clone-aware, so it stays on. We tried requesting the cheap `ATTR_CMNEXT_EXT_FLAGS` and looking up private
size only for files flagged "may share blocks" (`ScanBench extflags`): rejected — 72 % of files are flagged
anyway, and 141 unflagged files (90 MB) still had private ≠ allocated, so the shortcut would be inexact.

### Spotlight fast path (`ScanBench spotlight`)

| Query | Time | Hits |
|---|---:|---:|
| Files ≥ 100 MB in home (packages excluded) | 0.7–1.3 s | 45 |
| Files ≥ 10 MB in home | 1.0 s | 286 |

Approximate by design (logical sizes, Spotlight-excluded and unindexed folders missing — the walk found 69
files ≥ 100 MB), but available ~50× sooner than the full walk.

## Phase 2: migrated scanners (`ScanBench phase2`, `ScanBench verify`)

As `AppState` now runs them: one shared home index (`ScanIndexCache`), then each scanner answers from it
inside `ScanIndexContext.$index.withValue(index)`. Same busy machine (load 16–19).

| Scanner | Before (alone, own walk) | After, on fresh full index | After, on incremental index |
|---|---:|---:|---:|
| Shared index (`ScanEngine.index(home)`) | — | 125.5 s (full walk) | 13.2 s (FSEvents patch) |
| `JunkScanner.scan` (incl. Docker/simulator tool items) | 165–176 s† | 10.8 s | 5.4 s |
| `JunkScanner.scan` without tool items (`verify`) | 244.1 s | 0.21 s | — |
| `LargeFilesScanner.scan(100 MB)` | 6.3–6.6 s | 0.01 s | 0.01 s |
| `DuplicateScanner.scan(1 MB)` (incl. hashing) | 0.21–0.22 s | 0.14 s | 0.13 s |
| `SpaceAnalyzer.scan(home)` | 176–197 s | 0.04 s | 0.04 s |
| `WorktreeScanner.scan` (83 worktrees, no `gh`) | 331–341 s | 5.0 s | 6.6 s |
| **Scan All + Space Map, total** | **~880 s of scanner time** (sum; Scan All runs them concurrently) | **~141 s** | **~25 s** |

† measured before master added the AI-model/Docker/simulator Junk categories; the 244 s row is the same
code path without tool items, measured after the merge.

Junk's remaining 5–11 s is the Docker/`simctl` tool items and local-AI-model folders it still sizes
itself; Worktrees' 5–7 s is `git` (now run in parallel, ~12 at a time).

**Correctness (`verify`, index vs the old walk, same machine state, minutes apart):**

| Scanner | Index | Old walk | Agreement |
|---|---|---|---|
| Junk (no tool items) | 14 items, 3.72 GB | 13 items, 3.76 GB | same items and sizes except Chrome cache and `go-build` (grew between the two runs) and one `.DS_Store` in another worktree that changed in between |
| Large files ≥ 50 MB | 2 | 2 | identical set |
| Duplicates ≥ 1 MB | 7 groups / 20 files | 7 / 20 | identical files |
| Space Map of ~/Documents | 107 251 859 456 B / 3 327 462 files | 107 253 760 000 B / 3 327 575 files | 0.002 % apart (live writes); top-level children identical |
