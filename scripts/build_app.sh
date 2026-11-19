#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Furl"
BUNDLE_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building $APP_NAME (release, Apple silicon + Intel)..."
cd "$ROOT_DIR"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build --disable-sandbox -c release "${ARCH_FLAGS[@]}" --product "$APP_NAME"

BIN_PATH="$(swift build --disable-sandbox -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

ICON_PATH="$ROOT_DIR/Resources/AppIcon.icns"
if [[ ! -f "$ICON_PATH" ]]; then
  echo "Generating app icon..."
  swift "$ROOT_DIR/scripts/make_icon.swift" "$ICON_PATH"
fi
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
# GPLv3: the licence travels with the binary.
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Furl</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.getfurl.furl</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Furl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) 2026 Furl. GPL-3.0-or-later. No warranty.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Ad-hoc sign the whole bundle so Info.plist and resources are sealed. Without a Developer ID the
# app can't be notarized, but an unsealed bundle downloaded from the web is reported as "damaged"
# with no way to open it; a sealed ad-hoc one gets the normal "Open Anyway" path instead.
codesign --force --sign - --identifier app.getfurl.furl "$BUNDLE_DIR"
codesign --verify --strict "$BUNDLE_DIR"

echo "Packaged: $BUNDLE_DIR"
