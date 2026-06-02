#!/bin/zsh
set -euo pipefail
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Input Method Agent.app"
PKG_PATH="$DIST_DIR/Input Method Agent Installer.pkg"
ZIP_PATH="$DIST_DIR/Input Method Agent.app.zip"
IDENTIFIER="local.input-method-agent"
VERSION="0.1.0"
STAGING_DIR="$(mktemp -d /private/tmp/input-method-agent-package.XXXXXX)"
STAGED_APP="$STAGING_DIR/Input Method Agent.app"
PKG_ROOT="$STAGING_DIR/pkgroot"
PKG_APP="$PKG_ROOT/Applications/Input Method Agent.app"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$PROJECT_DIR/scripts/build-app.sh"

rm -f "$PKG_PATH" "$ZIP_PATH"
ditto --noextattr --norsrc "$APP_DIR" "$STAGED_APP"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGED_APP" 2>/dev/null || true
fi

if command -v dot_clean >/dev/null 2>&1; then
  dot_clean "$STAGED_APP" 2>/dev/null || true
fi

rm -rf "$STAGED_APP/Contents/_CodeSignature"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGED_APP" 2>/dev/null || true
fi

if command -v dot_clean >/dev/null 2>&1; then
  dot_clean -m "$STAGED_APP" 2>/dev/null || true
fi

find "$STAGED_APP" -name '._*' -delete

mkdir -p "$PKG_ROOT/Applications"
ditto --noextattr --norsrc "$STAGED_APP" "$PKG_APP"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$PKG_ROOT" 2>/dev/null || true
fi

if command -v dot_clean >/dev/null 2>&1; then
  dot_clean -m "$PKG_ROOT" 2>/dev/null || true
fi

find "$PKG_ROOT" -name '._*' -delete

pkgbuild \
  --root "$PKG_ROOT" \
  --filter '^\._.*' \
  --filter '.*/\._.*' \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  "$PKG_PATH"

ditto -c -k --keepParent --noextattr --norsrc "$STAGED_APP" "$ZIP_PATH"

echo "Created: $PKG_PATH"
echo "Created: $ZIP_PATH"
