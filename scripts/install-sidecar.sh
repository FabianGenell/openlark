#!/usr/bin/env bash
# Sets up the Python inference daemon (parakeet-mlx) and registers it
# as a LaunchAgent so it boots with the user and stays resident.
#
# Run this after downloading the .app from a release. The .app itself
# doesn't bundle Python — the daemon lives in this repo.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR_DIR="$ROOT_DIR/sidecar"
SCRIPTS_DIR="$ROOT_DIR/scripts"

LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PATH="$LAUNCH_AGENT_DIR/app.openlark.sidecar.plist"
LOG_DIR="$HOME/Library/Logs/OpenLark"

for cmd in uv ffmpeg; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "✗ '$cmd' is not installed. Install with:"
        case "$cmd" in
            uv) echo "    curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
            ffmpeg) echo "    brew install ffmpeg" ;;
        esac
        exit 1
    fi
done

echo "› creating sidecar venv..."
if [ ! -d "$SIDECAR_DIR/.venv" ]; then
    cd "$SIDECAR_DIR"
    uv venv --python 3.13
    uv pip install parakeet-mlx numpy
fi

PYTHON_BIN="$SIDECAR_DIR/.venv/bin/python"
if [ ! -x "$PYTHON_BIN" ]; then
    echo "✗ python venv not found at $PYTHON_BIN"
    exit 1
fi

echo "› installing LaunchAgent..."
mkdir -p "$LAUNCH_AGENT_DIR" "$LOG_DIR"

launchctl unload "$LAUNCH_AGENT_PATH" 2>/dev/null || true

sed \
    -e "s|__SIDECAR_PYTHON__|$PYTHON_BIN|g" \
    -e "s|__SIDECAR_DIR__|$SIDECAR_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$SCRIPTS_DIR/app.openlark.sidecar.plist" > "$LAUNCH_AGENT_PATH"

launchctl load "$LAUNCH_AGENT_PATH"

cat <<EOF

✓ Sidecar installed.

First start downloads the Parakeet model (~600 MB). Tail the log:
  tail -f $LOG_DIR/sidecar.log

Once you see "listening on /tmp/openlark.sock", launch OpenLark.app and try ⌘+↑.
EOF
