#!/usr/bin/env bash
# No Donuts — remove the legacy script-installed LaunchAgent (ND-083 migration).
#
# The app's one launcher is now the agent bundled inside NoDonuts.app
# (label com.nodonuts.app.agent), turned on/off from Settings › "Start at login"
# (ND-082). Older installs may still have the ND-016 agent that
# scripts/install-launchagent.sh put in ~/Library/LaunchAgents
# (label com.nodonuts.agent). With both loaded, two copies start at login. The
# single-instance guard stops the second one, but you should keep only one launcher.
#
# What this does (idempotent, no sudo):
#   1. launchctl bootout gui/$UID/com.nodonuts.agent (stops the legacy job; if it
#      launched the running No Donuts, that copy quits)
#   2. rm ~/Library/LaunchAgents/com.nodonuts.agent.plist
# It does NOT touch the bundled agent, the app, or any enrolled data. The app itself
# migrates the older SMAppService.mainApp login item on its own (LoginItem.swift).
#
# Afterwards: open No Donuts → Settings → turn on "Start at login".

set -euo pipefail

LEGACY_LABEL="com.nodonuts.agent"
LEGACY_PLIST="${HOME}/Library/LaunchAgents/${LEGACY_LABEL}.plist"
DOMAIN="gui/$(id -u)"

if launchctl print "${DOMAIN}/${LEGACY_LABEL}" >/dev/null 2>&1; then
    echo "==> stopping legacy LaunchAgent ${DOMAIN}/${LEGACY_LABEL}"
    launchctl bootout "${DOMAIN}/${LEGACY_LABEL}" 2>/dev/null || true
else
    echo "==> legacy LaunchAgent ${LEGACY_LABEL} not loaded"
fi

if [ -e "${LEGACY_PLIST}" ]; then
    echo "==> removing ${LEGACY_PLIST}"
    rm -f "${LEGACY_PLIST}"
else
    echo "==> ${LEGACY_PLIST} not present"
fi

echo ""
echo "Legacy launcher removed."
echo "To start No Donuts at login: open the app → Settings → turn on \"Start at login\"."
echo "(If macOS asks, approve No Donuts in System Settings › General › Login Items.)"
