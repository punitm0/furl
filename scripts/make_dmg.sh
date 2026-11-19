#!/bin/bash
# Builds build/Furl.dmg with the designed install window:
# 660×400 window, 128 pt icons, Furl at (170,196), Applications at (490,196),
# background from Resources/dmg (1x + 2x combined into one HiDPI TIFF).
#
# Usage: ./scripts/make_dmg.sh            (builds the app first if build/Furl.app is missing)
# Needs Finder automation permission the first time (macOS will ask) to lay out the window.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Furl.app"
DMG="$ROOT/build/Furl.dmg"
VOL="Furl"
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
