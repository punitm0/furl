# Releasing Furl

Furl updates itself from GitHub Releases. The app downloads `Furl.dmg` only when the release also has
`Furl.dmg.sha256` and `Furl.dmg.sig`, and installs it only if all of these hold:

- the checksum matches;
- the Ed25519 signature verifies against `UpdateConfig.signingPublicKey` (`Sources/Furl/Services/UpdateInstaller.swift`);
- the app inside has the bundle id `app.getfurl.furl`;
- the app's version equals the release tag and is newer than the installed one;
- its code signature verifies.

If any of these files is missing, people see a Download button instead, which also happens when the copy can't
replace itself. A release without the `.sig` still works, but nobody gets it automatically.

## The signing key

- The private key lives at `~/.furl/update-signing-key` (mode 600), or at `$FURL_UPDATE_KEY`. It is never committed.
- **Back it up** (a password manager is fine). If it's lost, no copy already out there can install updates by
  itself again: their users would have to download the next version by hand, and the new key would only work
  from then on. Anyone who has the key can sign an update every Furl will install, so keep it private.
- First time only: `swift scripts/sign_update.swift generate`, then paste the printed public key into
  `UpdateConfig.signingPublicKey`. `swift scripts/sign_update.swift public` prints it again.

## Checklist for each release

1. Set the version in `scripts/build_app.sh` (`CFBundleShortVersionString`, and bump `CFBundleVersion`).
   The git tag must be the same version with a `v` prefix (`v1.2.0` for `1.2.0`): the app refuses a DMG whose
   version doesn't match the tag.
2. Add the release to `website/src/data/changelog.ts`.
3. `swift build` (zero warnings) and `swift test`.
4. `./scripts/build_app.sh`, then `./scripts/make_dmg.sh`. Check that it printed:
   - `Wrote: …/build/Furl.dmg.sha256`
   - `Wrote: …/build/Furl.dmg.sig` (no "no update signing key" warning)
5. Optional sanity check: `swift scripts/sign_update.swift sign build/Furl.dmg` signs again and checks the new
   signature against the key. CryptoKit's signatures include randomness, so it won't equal `build/Furl.dmg.sig`
   byte for byte; both are valid.
6. Create the GitHub release for tag `vX.Y.Z` (not a draft, not a pre-release, because the app reads
   `releases/latest`) and attach exactly these names:
   - `Furl.dmg`
   - `Furl.dmg.sha256`
   - `Furl.dmg.sig`
7. Put the SHA-256 in the release notes too. The install page tells people to compare it.
8. After publishing: in an older installed Furl, choose **Furl › Check for Updates…**. About should offer
   **Install and Relaunch**.

The first release that contains the updater still has to be installed by hand. Only versions after it update
themselves.

## Testing the update flow locally (no release needed)

Debug builds have an update-test mode, which release builds don't contain. It turns on for a copy whose bundle id
ends in `.updatetest`. That copy:

- reads the release JSON from `FurlUpdateTestFeed` (plain http on 127.0.0.1 only);
- accepts asset links on that host;
- keeps its data in `Furl-UpdateTest` folders;
- sends no community stats.

With `FurlUpdateTestAutoInstall` set, it installs whatever the check finds and logs each step to
`~/Library/Application Support/Furl-UpdateTest/update-test.log`.

1. `./scripts/build_app.sh` and `swift build` (debug).
2. For an "installed" version (e.g. 1.1.9) and a "release" version (e.g. 1.2.0), copy `build/Furl.app` to a
   scratch folder. Replace `Contents/MacOS/Furl` with `.build/debug/Furl`. Use PlistBuddy to set
   `CFBundleIdentifier` to `app.getfurl.furl.updatetest` and `CFBundleShortVersionString` to the version. Then
   run `codesign --force --sign - --identifier app.getfurl.furl.updatetest <app>`.
3. Package the release version:
   `FURL_APP=<release app> FURL_DMG=<feed>/Furl.dmg FURL_DMG_VOLNAME=FurlUpdateTest ./scripts/make_dmg.sh`
   (a different volume name, so it never detaches a mounted Furl disk image).
4. Write `<feed>/release.json`:
   `{"tag_name":"v1.2.0","html_url":"http://127.0.0.1:8765/","assets":[{"name":"Furl.dmg","browser_download_url":"http://127.0.0.1:8765/Furl.dmg"}, …]}`
   with the same entry shape for `.sha256` and `.sig`. Serve it with `python3 -m http.server 8765 --bind 127.0.0.1 -d <feed>`.
5. Set the test copy's defaults:
   `defaults write app.getfurl.furl.updatetest FurlUpdateTestFeed http://127.0.0.1:8765/release.json`,
   `… FurlUpdateTestAutoInstall -bool true`, `… scanOnLaunch -bool false`, `… importedFromSweepMac -bool true`.
6. Put the installed version in a scratch "Applications" folder and `open` it. Expected:
   - within a few seconds it quits;
   - the same path reopens as 1.2.0;
   - the old copy is in the Trash;
   - `update-test.log` shows the check result, where the old copy went and "relaunching".
7. Negative runs:
   - Tamper with the DMG (append a byte and recompute the `.sha256`, so only the signature catches it).
     Expect `install failed: The download isn't signed by Furl.` in the log.
   - `chmod 555` the scratch folder. Expect `can't install: You don't have permission…` in the log.

   In both cases nothing changes on disk.
8. Clean up: quit the test copy (`osascript -e 'tell application id "app.getfurl.furl.updatetest" to quit'`), `defaults delete app.getfurl.furl.updatetest`, and remove the
   `~/Library/Application Support/Furl-UpdateTest` and `~/Library/Caches/Furl-UpdateTest` folders.

Never point this at `/Applications/Furl.app` or a running real Furl.
