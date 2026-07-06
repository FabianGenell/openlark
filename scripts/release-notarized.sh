#!/usr/bin/env bash
# Local notarized release.
#
# Builds OpenLark.app, signs it with the Heltra LLC Developer ID certificate,
# notarizes it with Apple, staples the ticket, verifies Gatekeeper acceptance,
# then tags and publishes the GitHub release. Because it signs and notarizes,
# the released app opens with no Gatekeeper warning and no quarantine hack.
#
# Releases are cut here rather than in CI on purpose: the Developer ID private
# key stays on this Mac and never has to live in GitHub secrets.
#
# Usage:  ./scripts/release-notarized.sh 0.4.3
#
# Requires (all already present on this Mac):
#   - "Developer ID Application: Heltra LLC (Q82GBB49WJ)" in the login keychain
#   - App Store Connect API key at ~/.config/asc/AuthKey_WUXT5BGU6R.p8
#   - gh authenticated for the repo
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>     (e.g. 0.4.3)"
    exit 1
fi
VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ version must be x.y.z, got: $VERSION"
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEVID="Developer ID Application: Heltra LLC (Q82GBB49WJ)"
ASC_KEY="$HOME/.config/asc/AuthKey_WUXT5BGU6R.p8"
ASC_KEY_ID="WUXT5BGU6R"
ASC_ISSUER="71424b8c-23d9-4cc4-a9e2-999ea5f3e10d"
PLIST="$ROOT_DIR/app/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/app/Resources/OpenLark.entitlements"
APP="$ROOT_DIR/build/OpenLark.app"
ZIP="$ROOT_DIR/build/OpenLark.app.zip"

# --- Preconditions -----------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    echo "✗ working tree has uncommitted changes. Commit or stash first."
    git status --short
    exit 1
fi
if ! security find-identity -p codesigning -v | grep -q "$DEVID"; then
    echo "✗ Developer ID certificate not found in keychain:"
    echo "    $DEVID"
    exit 1
fi
[ -f "$ASC_KEY" ] || { echo "✗ App Store Connect key missing at $ASC_KEY"; exit 1; }

# --- 1. Bump version ---------------------------------------------------------
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEXT_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"
echo "› version $VERSION (build $NEXT_BUILD)"

# --- 2. Build, signed with the Developer ID identity -------------------------
SIGNING_IDENTITY="$DEVID" "$ROOT_DIR/scripts/build.sh"

# --- 3. Re-sign with a secure timestamp (notarization requires one) ----------
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --identifier app.openlark.OpenLark \
    --sign "$DEVID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- 4. Zip + submit to the Apple notary service -----------------------------
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "› submitting to Apple notary service (this waits for the result)…"
xcrun notarytool submit "$ZIP" \
    --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
    --wait

# --- 5. Staple the ticket, then re-zip the stapled app -----------------------
xcrun stapler staple "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

# --- 6. Verify Gatekeeper acceptance -----------------------------------------
echo "› Gatekeeper assessment:"
spctl -a -vvv --type exec "$APP"
xcrun stapler validate "$APP"

# --- 7. Commit, tag, push, publish -------------------------------------------
SHA=$(cut -d' ' -f1 < "$ZIP.sha256")
git add "$PLIST"
git commit -m "release: v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" \
    --title "v$VERSION" \
    --notes "$(cat <<EOF
## Install

1. Download \`OpenLark.app.zip\` below and unzip it.
2. Drag \`OpenLark.app\` to \`~/Applications\` and open it.

The app is signed and notarized by Apple (Heltra LLC), so it opens with no Gatekeeper warning. On first launch, follow the onboarding to grant Microphone, Accessibility, and Input Monitoring, and to download the speech engine (one-time, ~144 MB). The first transcription also fetches the Parakeet model (~600 MB) from HuggingFace on demand.

## Verify

SHA-256 of \`OpenLark.app.zip\`:
\`\`\`
$SHA
\`\`\`

See the [README](https://github.com/FabianGenell/openlark#readme) for details.
EOF
)"

echo ""
echo "✓ v$VERSION signed, notarized, stapled, and published."
echo "  https://github.com/FabianGenell/openlark/releases/tag/v$VERSION"
