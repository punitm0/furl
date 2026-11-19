### What and why
<!-- What does this change, and what problem does it solve? Link the issue if there is one (Fixes #123). -->

### How I tested it
<!-- macOS version, what you ran, what you checked. Screenshots for UI changes. -->

### Checklist
- [ ] `swift build` passes with no new warnings, and `swift test` passes
- [ ] Anything that deletes, moves or rewrites files defaults to the Trash and only touches paths the user chose
- [ ] Any new network call is listed on the privacy page (`website/src/pages/privacy.astro`)
- [ ] UI changes follow the design (see AGENTS.md)
- [ ] `stats-worker/` or `website/` changes: `npm test` / `npm run build` pass
