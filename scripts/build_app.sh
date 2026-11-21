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

# Shortcuts actions (Sources/Furl/Intents). The Shortcuts app only lists them when the bundle has
# Resources/Metadata.appintents, which Xcode normally makes and SwiftPM doesn't. The Swift build
# already writes the constant-value files the extractor needs (*.swiftconstvalues), so run Apple's
# extractor on them here. Metadata is the same for both architectures; arm64's is used.
OBJ_DIR="$(dirname "$(dirname "$(dirname "$BIN_PATH")")")/Intermediates.noindex/$APP_NAME.build/Release/$APP_NAME-p.build/Objects-normal/arm64"
CONST_VALUES=("$OBJ_DIR"/*.swiftconstvalues)
if [[ ! -e "${CONST_VALUES[0]}" ]]; then
  echo "Error: no .swiftconstvalues in $OBJ_DIR; Shortcuts actions would be missing." >&2
  exit 1
fi
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  echo "Error: appintentsmetadataprocessor not found. Install Xcode and run xcode-select -s." >&2
  exit 1
fi
INTENTS_TMP="$(mktemp -d)"
trap 'rm -rf "$INTENTS_TMP"' EXIT
if [[ -f "$OBJ_DIR/$APP_NAME.SwiftFileList" ]]; then
  cp "$OBJ_DIR/$APP_NAME.SwiftFileList" "$INTENTS_TMP/sources.list"
else
  find "$ROOT_DIR/Sources/$APP_NAME" -name '*.swift' > "$INTENTS_TMP/sources.list"
fi
printf '%s\n' "${CONST_VALUES[@]}" > "$INTENTS_TMP/constvalues.list"
SWIFTC_PATH="$(xcrun --find swiftc)"
xcrun appintentsmetadataprocessor \
  --output "$RESOURCES_DIR" \
  --toolchain-dir "${SWIFTC_PATH%/usr/bin/swiftc}" \
  --module-name "$APP_NAME" \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple arm64-apple-macos14.0 \
  --source-file-list "$INTENTS_TMP/sources.list" \
  --swift-const-vals-list "$INTENTS_TMP/constvalues.list" \
  --quiet-warnings 2>&1 | grep -v -e "Starting appintentsmetadataprocessor" -e "Writing Metadata.appintents" -e "Metadata root:" || true
if [[ ! -f "$RESOURCES_DIR/Metadata.appintents/extract.actionsdata" ]]; then
  echo "Error: Metadata.appintents was not generated; Shortcuts actions would be missing." >&2
  exit 1
fi

ICON_PATH="$ROOT_DIR/Resources/AppIcon.icns"
if [[ ! -f "$ICON_PATH" ]]; then
  echo "Generating app icon..."
  swift "$ROOT_DIR/scripts/make_icon.swift" "$ICON_PATH"
fi
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
# MIT: the licence travels with the binary.
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
    <string>1.4.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Punit Makwana. MIT License.</string>
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
