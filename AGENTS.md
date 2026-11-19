# AGENTS.md

Guidance for coding agents (and humans) working in this repo. `CLAUDE.md` and `GEMINI.md` are symlinks to this
file; Codex, Copilot, Cursor and most other agents read `AGENTS.md` directly.

## What this is

Furl is a native SwiftUI macOS app that frees disk space: caches and junk, merged git worktrees, app leftovers,
duplicates, large files, compression and lossy shrink, leftover dev processes. The repo also holds:

- `Sources/Furl/`: the app. `Services/` does the work (scanners, deletion, compression, shell calls),
  `State/` holds the observable stores (`AppState` and friends), `Views/` is SwiftUI, `Models/` is plain data.
- `Sources/Furl/Services/ScanEngine/`: the shared file-system walker and index (see `docs/scan-engine.md`).
- `Sources/ScanBench/`: a CLI benchmark. `Linked/` is relative symlinks into `Sources/Furl`, so it compiles
  the same scanner code.
- `stats-worker/`: Cloudflare Worker + D1 behind the public community counter.
- `website/`: getfurl.app (Astro, deployed to Cloudflare).

## Commands

```bash
swift build                          # debug build of everything
swift test                           # FurlTests (XCTest, @testable import Furl)
swift run Furl                       # run unbundled (notifications are off outside an app bundle)
./scripts/build_app.sh               # release app bundle in build/Furl.app (ad-hoc signed)
./scripts/make_dmg.sh                # DMG from build/Furl.app (needs Finder automation permission)
swift run -c release ScanBench new   # scan-engine benchmark; run before and after scan changes

cd stats-worker && npm ci && npm run typecheck && npm test
cd website && npm ci && npm run build && npm run check
```

Swift 6.0 tools, macOS 14 minimum, no third-party Swift packages. App tests live in `Tests/FurlTests`; the
worker has vitest tests. Build with zero new warnings.

## Rules that matter

- **Never delete the wrong thing.** Anything that deletes, moves or rewrites files defaults to the Trash,
  respects `DeletionService.isProtected`, re-checks state right before acting (size/mtime stamps, worktree still
  clean, HEAD unchanged), and never follows symlinks. When unsure whether something is safe, don't offer it.
- **Treat on-disk data as untrusted.** Repos, manifests and archives Furl finds may be crafted. Run external
  programs via `ShellRunner` with argument arrays (no shell). Every git call goes through `ShellRunner.git`,
  which disables fsmonitor and hooks; use `ShellRunner.gitStatusPorcelain` instead of raw `git status`.
  Validate any path built from file contents stays inside its intended folder.
- **Privacy.** File names, paths and contents never leave the Mac. The only network calls are listed on
  `website/src/pages/privacy.astro`; adding or changing one means updating that table in the same change.
  `CommunityStatsReporter.swift` is the only code that sends stats.
- **Design is the source of truth for UI.** Screens follow the design file; code comments that mention a
  "board" refer to a screen there. Don't invent new UI or change colours, theme tokens or the logo without a
  design for it.
- **Legacy names.** The app was once called SweepMac. Identifiers that saved data or the deployed Worker depend
  on (`X-SweepMac-*` headers, `com.sweepmac.*` markers, `SWEEPMAC_*` notification ids, the `sweepmac-stats`
  Worker/D1 names, data-migration constants in `AppIdentity.swift`/`PrivateStorage.swift`) stay as they are.
  Use "Furl" everywhere else.
- **Stats Worker.** The app's HMAC key is public; it is not authentication. Keep inputs strictly validated with
  zod, queries as prepared statements, and caps in `src/limits.ts` and the migrations in sync.

## Style

- Swift: match the surrounding code. Short doc comments that say why, not what.
- User-facing copy: plain, short sentences, no jargon.
- Keep changes focused; don't reformat unrelated code.

## License

GPL-3.0-or-later. Contributions are licensed under the same terms.
