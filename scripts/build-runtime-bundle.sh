#!/usr/bin/env bash
# Builds the OpenLark runtime bundle — a self-contained, relocatable Python
# tree pre-populated with parakeet-mlx + mlx + numpy wheels.
#
# Output: build/openlark-runtime-arm64-darwin.tar.gz
#
# The Swift installer downloads this tarball at first launch and extracts it
# to ~/Library/Application Support/OpenLark/runtime/. One HTTPS GET + tar
# extract replaces the previous "download Python, create venv, pip install"
# sequence.
#
# Run this when:
#   - bumping the Parakeet model dependency
#   - bumping python-build-standalone version
#   - the wheel set otherwise changes
#
# After running, upload build/openlark-runtime-arm64-darwin.tar.gz to the
# runtime-v<N> release on GitHub (gh release create runtime-vN ...).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build"
WORK_DIR="$OUT_DIR/runtime-build"
BUNDLE_NAME="openlark-runtime-arm64-darwin"

# python-build-standalone arm64 macOS install_only tarball. Pin the date so
# the bundle is reproducible.
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260510/cpython-3.13.13+20260510-aarch64-apple-darwin-install_only.tar.gz"

mkdir -p "$OUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "› downloading python-build-standalone…"
curl -fL "$PYTHON_URL" -o "$WORK_DIR/python.tar.gz"

echo "› extracting…"
tar -xzf "$WORK_DIR/python.tar.gz" -C "$WORK_DIR"
rm "$WORK_DIR/python.tar.gz"
# Tarball extracts to $WORK_DIR/python/ — that's our runtime root.

PYTHON="$WORK_DIR/python/bin/python3.13"
if [ ! -x "$PYTHON" ]; then
    echo "✗ python-build-standalone layout changed — $PYTHON missing"
    exit 1
fi

echo "› upgrading pip + wheel…"
"$PYTHON" -m pip install --upgrade --quiet pip wheel

echo "› installing parakeet-mlx + mlx + numpy into site-packages…"
"$PYTHON" -m pip install --quiet --prefer-binary \
    "parakeet-mlx>=0.3.5,<0.4" \
    "numpy>=2.0" \
    "mlx>=0.18"

# Strip pip's caches and .dist-info bloat to keep the tarball lean.
echo "› cleaning…"
find "$WORK_DIR/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$WORK_DIR/python" -name '*.pyc' -delete 2>/dev/null || true
rm -rf "$WORK_DIR/python/lib/python3.13/site-packages/pip/_vendor/cachecontrol/caches" 2>/dev/null || true
rm -rf "$WORK_DIR/python/share/man" 2>/dev/null || true

echo "› tarballing…"
cd "$WORK_DIR"
tar -czf "$OUT_DIR/$BUNDLE_NAME.tar.gz" python/
SIZE=$(du -sh "$OUT_DIR/$BUNDLE_NAME.tar.gz" | cut -f1)
SHA=$(shasum -a 256 "$OUT_DIR/$BUNDLE_NAME.tar.gz" | cut -d' ' -f1)

echo ""
echo "✓ built $OUT_DIR/$BUNDLE_NAME.tar.gz ($SIZE)"
echo "  sha256: $SHA"
echo ""
echo "Next: upload to a GitHub release"
echo "  gh release create runtime-v1 $OUT_DIR/$BUNDLE_NAME.tar.gz --title 'OpenLark runtime bundle v1' --notes 'Python 3.13 + parakeet-mlx + mlx + numpy, prebuilt for arm64 macOS.'"

rm -rf "$WORK_DIR"
