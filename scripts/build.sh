#!/usr/bin/env bash
# Build OpenLark.app from the Swift package.
# Outputs to: build/OpenLark.app

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/app"
OUT_DIR="$ROOT_DIR/build"
APP_BUNDLE="$OUT_DIR/OpenLark.app"

echo "› building Swift binary…"
cd "$APP_DIR"
swift build -c release --arch arm64

BINARY="$APP_DIR/.build/release/OpenLark"
if [ ! -f "$BINARY" ]; then
    echo "✗ binary not found at $BINARY"
    exit 1
fi

echo "› assembling .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/OpenLark"
cp "$APP_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Generate icon and copy into bundle.
echo "› generating icon…"
PYTHON_BIN="$(command -v python3)"
"$PYTHON_BIN" "$ROOT_DIR/scripts/make_icon.py" > /dev/null
cp "$OUT_DIR/OpenLark.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "› codesigning…"
# Identity priority:
#   1. $SIGNING_IDENTITY env var (used by CI — "OpenLark Release")
#   2. local "OpenLark Dev" cert (created by setup-signing-identity.sh)
#   3. ad-hoc, with a warning
#
# In CI we use `find-identity -v` (no `-p codesigning` policy filter) because
# the runner-imported cert isn't marked as trusted for codesigning (that step
# would require an interactive UI prompt the runner can't satisfy). codesign
# itself happily signs with an untrusted cert.
ENTITLEMENTS="$APP_DIR/Resources/OpenLark.entitlements"
IDENTITY_NAME="${SIGNING_IDENTITY:-OpenLark Dev}"
FIND_FLAGS=("-v")
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    FIND_FLAGS=("-p" "codesigning" "-v")
fi
if security find-identity "${FIND_FLAGS[@]}" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "  using identity: $IDENTITY_NAME"
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --identifier app.openlark.OpenLark \
        --sign "$IDENTITY_NAME" "$APP_BUNDLE"
else
    echo "  (ad-hoc — for stable TCC permissions, run scripts/setup-signing-identity.sh once)"
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --identifier app.openlark.OpenLark --sign - "$APP_BUNDLE"
fi

echo "✓ built: $APP_BUNDLE"
echo ""
echo "Run with: open '$APP_BUNDLE'"
