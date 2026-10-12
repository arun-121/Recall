#!/usr/bin/env bash
#
# Builds Recall and assembles a double-clickable Recall.app bundle.
#
# This project targets a Command Line Tools (no full Xcode) toolchain, so the
# app is built with Swift Package Manager and the .app bundle is assembled by
# hand. The result is an unsigned, local-use bundle for the machine that built
# it.
#
# Usage:
#   Scripts/build_app.sh            # debug build
#   Scripts/build_app.sh release    # optimized build
#

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Recall"
BUNDLE_ID="com.recall.app"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> Building ($CONFIG)..."
cd "$ROOT" || exit 1
swift build -c "$CONFIG"
if [ $? -ne 0 ]; then
    echo "error: swift build failed" >&2
    exit 1
fi

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | grep '^/' | tail -1)"
EXECUTABLE="$BIN_PATH/$APP_NAME"

if [ ! -x "$EXECUTABLE" ]; then
    echo "error: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "==> Done."
echo "    App bundle: $APP_DIR"
echo "    Run with:   open \"$APP_DIR\""
echo
echo "Note: the bundle is unsigned. On first launch macOS Gatekeeper may require"
echo "right-click > Open, or clear quarantine with:"
echo "    xattr -dr com.apple.quarantine \"$APP_DIR\""
