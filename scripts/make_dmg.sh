#!/bin/bash
# Builds build/Furl.dmg with the designed install window:
# 660×400 window, 128 pt icons, Furl at (170,196), Applications at (490,196),
# background from Resources/dmg (1x + 2x combined into one HiDPI TIFF).
#
# Usage: ./scripts/make_dmg.sh            (builds the app first if build/Furl.app is missing)
# Needs Finder automation permission the first time (macOS will ask) to lay out the window.
#
# Also writes build/Furl.dmg.sha256 and, when the update signing key exists (see
# scripts/sign_update.swift), build/Furl.dmg.sig. Upload all three to the GitHub release: the app's
# Install and Relaunch needs the .sha256 and .sig assets, and falls back to Download without them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# FURL_APP / FURL_DMG / FURL_DMG_VOLNAME point elsewhere (used by the update end-to-end test in docs/releasing.md).
APP="${FURL_APP:-$ROOT/build/Furl.app}"
DMG="${FURL_DMG:-$ROOT/build/Furl.dmg}"
VOL="${FURL_DMG_VOLNAME:-Furl}"
BG_1X="$ROOT/Resources/dmg/dmg-background.png"
BG_2X="$ROOT/Resources/dmg/dmg-background@2x.png"

[[ -d "$APP" ]] || "$ROOT/scripts/build_app.sh"

WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Stage the volume contents.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$STAGE/.background/background.tiff" >/dev/null

# Writable image to lay out, then compress.
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"

# Finder can lag behind the mount; styling fails with -1728 until it sees the disk.
for _ in $(seq 1 20); do
  osascript -e "tell application \"Finder\" to exists disk \"$VOL\"" 2>/dev/null | grep -q true && break
  sleep 0.5
done

osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 400 pt of content plus the 28 pt title bar.
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Furl.app" of container window to {170, 196}
    set position of item "Applications" of container window to {490, 196}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

SetFile -a C "/Volumes/$VOL" 2>/dev/null || true
sync
hdiutil detach "/Volumes/$VOL" -quiet

rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"

# Checksum and signature assets for Install and Relaunch.
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Wrote: $DMG.sha256"
rm -f "$DMG.sig"
KEY="${FURL_UPDATE_KEY:-$HOME/.furl/update-signing-key}"
if [[ -f "$KEY" ]]; then
  swift "$ROOT/scripts/sign_update.swift" sign "$DMG" > "$DMG.sig"
  echo "Wrote: $DMG.sig"
else
  echo "Warning: no update signing key at $KEY, so no Furl.dmg.sig." >&2
  echo "         Without it, apps can't install this release by themselves (they show Download instead)." >&2
fi
