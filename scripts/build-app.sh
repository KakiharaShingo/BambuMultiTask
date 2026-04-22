#!/usr/bin/env bash
# Build BambuMultiTask as a macOS .app bundle from the SPM executable.
# Usage: ./scripts/build-app.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="BambuMultiTask"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
BIN_NAME="BambuMultiTask"

cd "$ROOT_DIR"
echo "==> Building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_PATH="$ROOT_DIR/.build/apple/Products/Release/$BIN_NAME"
else
    swift build
    BIN_PATH="$ROOT_DIR/.build/debug/$BIN_NAME"
fi

echo "==> Assembling .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "Done. $APP_DIR"
echo "Run: open \"$APP_DIR\""
