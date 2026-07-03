#!/usr/bin/env bash
# Full install: sidecar venv + launchd agent + .app bundle into ~/Applications.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR_DIR="$ROOT_DIR/sidecar"
SCRIPTS_DIR="$ROOT_DIR/scripts"
APP_BUNDLE="$ROOT_DIR/build/OpenLark.app"

LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PATH="$LAUNCH_AGENT_DIR/app.openlark.sidecar.plist"
LOG_DIR="$HOME/Library/Logs/OpenLark"
APPLICATIONS_DIR="$HOME/Applications"

if ! command -v uv >/dev/null 2>&1; then
    echo "✗ 'uv' is not installed. Install with:"
    echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

echo "› ensuring sidecar venv..."
# Gate on the actual dependency, not just the directory. An interrupted first
# run leaves a .venv with no packages; keying off directory existence would then
# skip the install forever and leave a crash-looping daemon. Verify the import
# and rebuild from scratch if it's missing or broken.
cd "$SIDECAR_DIR"
PYTHON_BIN="$SIDECAR_DIR/.venv/bin/python"
if [ ! -x "$PYTHON_BIN" ] || ! "$PYTHON_BIN" -c 'import parakeet_mlx, numpy' >/dev/null 2>&1; then
    echo "  (building sidecar venv - missing or incomplete)"
    rm -rf "$SIDECAR_DIR/.venv"
    uv venv --python 3.13
    uv pip install parakeet-mlx numpy
fi

if [ ! -x "$PYTHON_BIN" ] || ! "$PYTHON_BIN" -c 'import parakeet_mlx, numpy' >/dev/null 2>&1; then
    echo "✗ sidecar venv build failed - parakeet_mlx/numpy not importable at $PYTHON_BIN"
    exit 1
fi

echo "› installing launchd plist for sidecar..."
mkdir -p "$LAUNCH_AGENT_DIR" "$LOG_DIR"

launchctl unload "$LAUNCH_AGENT_PATH" 2>/dev/null || true

sed \
    -e "s|__SIDECAR_PYTHON__|$PYTHON_BIN|g" \
    -e "s|__SIDECAR_DIR__|$SIDECAR_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$SCRIPTS_DIR/app.openlark.sidecar.plist" > "$LAUNCH_AGENT_PATH"

launchctl load "$LAUNCH_AGENT_PATH"

echo "› building app bundle..."
"$SCRIPTS_DIR/build.sh"

echo "› installing OpenLark.app to $APPLICATIONS_DIR..."
mkdir -p "$APPLICATIONS_DIR"
rm -rf "$APPLICATIONS_DIR/OpenLark.app"
cp -R "$APP_BUNDLE" "$APPLICATIONS_DIR/OpenLark.app"

cat <<EOF

✓ Installation complete.

Next steps:
  1. Open ~/Applications/OpenLark.app
  2. Grant Microphone permission when prompted
  3. Grant Accessibility + Input Monitoring in System Settings → Privacy & Security
     (required for global Esc capture and pasting into other apps)
  4. Press ⌘+↑ to start recording, ⌘+↑ again to transcribe, Esc to cancel

Useful:
  launchctl list | grep openlark
  tail -f $LOG_DIR/sidecar.log
  tail -f $LOG_DIR/app.log
EOF
