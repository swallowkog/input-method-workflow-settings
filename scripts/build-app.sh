#!/bin/zsh
set -euo pipefail
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Input Method Agent.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_PATH="$PROJECT_DIR/assets/AppIcon.icns"

cd "$PROJECT_DIR"
swift build -c release
swift "$PROJECT_DIR/scripts/generate-app-icon.swift" "$ICON_PATH"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PROJECT_DIR/.build/release/input-method-agent" "$MACOS_DIR/input-method-agent"
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>input-method-agent</string>
  <key>CFBundleIdentifier</key>
  <string>local.input-method-agent</string>
  <key>CFBundleName</key>
  <string>Input Method Agent</string>
  <key>CFBundleDisplayName</key>
  <string>Input Method Agent</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/input-method-agent"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_DIR" 2>/dev/null || true
fi

if command -v dot_clean >/dev/null 2>&1; then
  dot_clean "$APP_DIR" 2>/dev/null || true
fi

if command -v codesign >/dev/null 2>&1; then
  if ! codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
    echo "Warning: ad-hoc codesign skipped; extended attributes could not be fully removed from $APP_DIR" >&2
  fi
fi

echo "Created: $APP_DIR"
