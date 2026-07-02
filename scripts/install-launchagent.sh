#!/usr/bin/env bash
# No Donuts — install the app to /Applications and load the login LaunchAgent.
#
# CLT-friendly: builds a local ad-hoc-signed .app via make-app.sh (no full Xcode),
# copies it to /Applications/NoDonuts.app, installs the LaunchAgent so the app
# starts at login (RunAtLoad), and (re)loads it now. Idempotent — safe to re-run.
#
# No sudo: writing to /Applications works for the user's own account on most
# setups. Undo with scripts/uninstall-launchagent.sh.
#
# See ADR-0001, ADR-0008, ND-016, and .claude/skills/build-run/SKILL.md.

set -euo pipefail

# Run from the repo root so relative paths resolve regardless of cwd.
cd "$(git rev-parse --show-toplevel)"

APP_NAME="NoDonuts"
SRC_APP="build/${APP_NAME}.app"
DEST_APP="/Applications/${APP_NAME}.app"
PLIST_SRC="scripts/com.nodonuts.agent.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.nodonuts.agent.plist"

echo "==> building the app (release)"
scripts/make-app.sh

# Stop any currently-running agent BEFORE touching the app bundle, so we don't
# mutate /Applications/NoDonuts.app out from under a live process on a re-run.
# bootout is tolerated (|| true): it fails if nothing is loaded, which is fine.
echo "==> stopping running LaunchAgent (if any)"
launchctl bootout "gui/$(id -u)" "${PLIST_DEST}" 2>/dev/null || true

echo "==> installing ${SRC_APP} -> ${DEST_APP}"
rm -rf "${DEST_APP}"
cp -R "${SRC_APP}" "${DEST_APP}"

echo "==> installing LaunchAgent -> ${PLIST_DEST}"
mkdir -p "${HOME}/Library/LaunchAgents"
cp "${PLIST_SRC}" "${PLIST_DEST}"

# bootstrap can fail non-zero if the service is still registered (bootout is
# async and may not have fully torn down). Under `set -euo pipefail` that would
# abort the script after the app was already copied — breaking idempotency.
# So tolerate a failed bootstrap and fall back to kickstart to (re)launch.
echo "==> loading LaunchAgent"
if ! launchctl bootstrap "gui/$(id -u)" "${PLIST_DEST}" 2>/dev/null; then
  echo "  (agent already registered — reloading)"
  launchctl kickstart -k "gui/$(id -u)/com.nodonuts.agent"
fi

echo ""
echo "Installed: ${DEST_APP}"
echo "LaunchAgent loaded — No Donuts will start automatically at login."
echo "On first launch, grant Camera (and Location, if you use trusted Wi-Fi) when prompted."
echo "To undo: scripts/uninstall-launchagent.sh"
