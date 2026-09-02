#!/usr/bin/env bash
# Local-dev helper: pip-installs mlx-whisper + huggingface_hub into the
# already-installed runtime under ~/Library/Application Support/OpenLark/runtime,
# so you can test the multi-model wire protocol before publishing a new
# runtime-vN bundle to GitHub.
#
# In a real release, build-runtime-bundle.sh bakes these in and the user
# downloads everything as one tarball. This script is only for the gap
# between "code changes" and "new bundle published".

set -euo pipefail

RUNTIME_ROOT="$HOME/Library/Application Support/OpenLark/runtime"
PYTHON="$RUNTIME_ROOT/python/bin/python3"

if [ ! -x "$PYTHON" ]; then
    echo "✗ runtime not installed at $RUNTIME_ROOT"
    echo "  Launch OpenLark.app once so it downloads the runtime bundle, then re-run this script."
    exit 1
fi

echo "› installing mlx-whisper + huggingface_hub…"
# --no-cache-dir avoids tripping over pip's stripped-down cachecontrol module
# (build-runtime-bundle.sh deletes pip caches to slim the tarball).
"$PYTHON" -m pip install --no-cache-dir --prefer-binary \
    "mlx-whisper>=0.4.2" \
    "huggingface_hub>=0.24"

echo "› restarting the OpenLark daemon so it picks up the new server.py + deps…"
launchctl unload "$HOME/Library/LaunchAgents/app.openlark.sidecar.plist" 2>/dev/null || true
rm -f /tmp/openlark.sock

# Drop the installed-version marker so the next app launch forces a reinstall
# (writes the new plist with HF_HOME, copies the new server.py, reloads launchd).
rm -f "$HOME/Library/Application Support/OpenLark/.installed-version"

echo ""
echo "✓ deps installed. Now relaunch OpenLark.app, it'll reinstall the daemon."
