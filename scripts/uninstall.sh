#!/usr/bin/env bash
# Fully remove OpenLark from the system.
# Leaves the project source tree alone, only touches user data.

set -euo pipefail

LAUNCH_AGENT="$HOME/Library/LaunchAgents/app.openlark.sidecar.plist"
APP_BUNDLE="$HOME/Applications/OpenLark.app"
APP_SUPPORT="$HOME/Library/Application Support/OpenLark"
LOGS="$HOME/Library/Logs/OpenLark"

KEEP_DATA=0
for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=1 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--keep-data]

Removes:
  - The launchd agent at \$HOME/Library/LaunchAgents/app.openlark.sidecar.plist
  - OpenLark.app from ~/Applications
  - User data at ~/Library/Application Support/OpenLark (vocab + history)
  - Logs at ~/Library/Logs/OpenLark

With --keep-data, leaves vocab + history in place so you can reinstall later.
EOF
            exit 0 ;;
    esac
done

echo "› unloading launchd agent..."
launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"

echo "› killing running app..."
pkill -f "OpenLark.app/Contents/MacOS/OpenLark" 2>/dev/null || true

echo "› removing app bundle..."
rm -rf "$APP_BUNDLE"

echo "› removing logs..."
rm -rf "$LOGS"

if [ "$KEEP_DATA" -eq 0 ]; then
    echo "› removing user data (vocab + history)..."
    rm -rf "$APP_SUPPORT"
else
    echo "› keeping user data at $APP_SUPPORT"
fi

# TCC entries can't be removed without sudo + SIP off; user can run this manually:
echo ""
echo "✓ Uninstalled."
echo ""
echo "To also clear macOS permission grants (Microphone, Accessibility, Input Monitoring), run:"
echo "  tccutil reset All app.openlark.OpenLark"
