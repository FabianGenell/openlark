#!/usr/bin/env bash
# One-shot release: bump version in Info.plist, commit, tag, push.
# CI takes it from there (builds + creates the GitHub release).
#
# Usage:  ./scripts/release.sh 0.3.0

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>     (e.g. 0.3.0)"
    exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ version must be x.y.z, got: $VERSION"
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT_DIR/app/Resources/Info.plist"

if [ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
    echo "✗ working tree has uncommitted changes. Commit or stash first."
    git -C "$ROOT_DIR" status --short
    exit 1
fi

# Increment the integer CFBundleVersion alongside the user-facing short version.
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEXT_BUILD=$((CURRENT_BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"

echo "› bumped Info.plist to $VERSION (build $NEXT_BUILD)"

git -C "$ROOT_DIR" add "$PLIST"
git -C "$ROOT_DIR" commit -m "release: v$VERSION"
git -C "$ROOT_DIR" tag "v$VERSION"
git -C "$ROOT_DIR" push origin main "v$VERSION"

echo ""
echo "✓ v$VERSION tagged + pushed."
echo "  CI will build and publish the release at:"
echo "    https://github.com/FabianGenell/openlark/releases/tag/v$VERSION"
