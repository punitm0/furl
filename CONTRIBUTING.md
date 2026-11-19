# Contributing

Thanks for helping. Furl is maintained by one person, so small, focused pull requests are the easiest to review.

## Build

- Xcode 16 or later, macOS 14 or later.
- `swift build` to compile, `swift run Furl` to run, `./scripts/build_app.sh` for an app bundle.
- Scan-engine changes: run `swift run -c release ScanBench new` before and after (see `docs/scan-benchmarks.md`).
- `stats-worker/`: `npm ci && npm run typecheck && npm test`.
- `website/`: `npm ci && npm run build && npm run check`.

## Guidelines

- Anything that deletes, moves or rewrites files must default to the Trash and must never touch paths the user
  didn't choose. Say in the PR how you checked that.
- Nothing may leave the Mac without being listed on the privacy page (`website/src/pages/privacy.astro`).
- For bigger changes or new features, open an issue first so we can agree on the approach.
- Code comments sometimes mention a "board": that's the name of a screen in the app's design file.

## Issues and pull requests

- Bugs: use **Help → Report a Problem** in Furl, which fills in the bug template with safe diagnostics.
- Ideas: open a feature request. Issues labelled `good first issue` are a good place to start.
- Pull requests: fill in the template. CI builds the app and runs the Worker tests and website build.
- Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Furl is licensed under GPL-3.0-or-later. By contributing, you agree your contribution is licensed under the same
terms.
