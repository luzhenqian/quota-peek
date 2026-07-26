#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/QuotaPeek.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

swift build -c release --package-path "$PROJECT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/QuotaPeek" "$MACOS_DIR/QuotaPeek"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp -R "$PROJECT_DIR/.build/release/QuotaPeek_QuotaPeek.bundle" "$CONTENTS_DIR/Resources/"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
