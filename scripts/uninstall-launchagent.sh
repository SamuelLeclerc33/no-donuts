#!/usr/bin/env bash
# No Donuts — unload and remove the login LaunchAgent.
#
# CLT-friendly: stops the agent and deletes its plist from ~/Library/LaunchAgents.
# This does NOT remove /Applications/NoDonuts.app or any enrolled app data —
# full data removal is tracked as ND-052. Counterpart to install-launchagent.sh.
#
# See ADR-0001, ND-016, ND-052.

set -euo pipefail

# Run from the repo root so relative paths resolve regardless of cwd.
cd "$(git rev-parse --show-toplevel)"

PLIST_DEST="${HOME}/Library/LaunchAgents/com.nodonuts.agent.plist"

echo "==> unloading LaunchAgent"
launchctl bootout "gui/$(id -u)" "${PLIST_DEST}" 2>/dev/null || true

echo "==> removing ${PLIST_DEST}"
rm -f "${PLIST_DEST}"

# bootout only stops the launchd-managed instance. A copy launched by hand
# (e.g. `open -a NoDonuts`) keeps running — and keeps locking — after the user
# thinks they've turned it off. Kill any remaining instance too.
echo "==> stopping any running NoDonuts instance"
killall NoDonuts 2>/dev/null || true

echo ""
echo "No Donuts stopped — it will no longer start at login."
echo "Note: /Applications/NoDonuts.app and app data are left in place."
echo "Full removal (uninstall + enrolled data) is tracked as ND-052."
