#!/usr/bin/env bash
# No Donuts — build the app and install it to /Applications/NoDonuts.app.
#
# CLT-friendly: builds a local signed .app via make-app.sh (no full Xcode), stops
# any running copy, replaces /Applications/NoDonuts.app, removes the legacy
# ND-016 LaunchAgent if present (scripts/migrate-launcher.sh), and opens the app.
# Idempotent, no sudo.
#
# Start-at-login is NOT set up by this script any more (ND-082 / ND-083). The one
# launcher is the LaunchAgent bundled inside the app (label com.nodonuts.app.agent),
# switched on from the app: Settings › "Start at login". That agent starts the app
# at login and relaunches it after a crash/kill; menu Quit stays quit. If it is on,
# the copy this script opens hands over to the agent (ND-082) and the script checks.
#
# See ADR-0008, ND-082, ND-083 and .claude/skills/build-run/SKILL.md.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

APP_NAME="NoDonuts"
SRC_APP="build/${APP_NAME}.app"
DEST_APP="/Applications/${APP_NAME}.app"
AGENT_LABEL="com.nodonuts.app.agent"
DOMAIN="gui/$(id -u)"

echo "==> building the app (release)"
scripts/make-app.sh

echo "==> removing the legacy launcher (if any)"
scripts/migrate-launcher.sh >/dev/null

# Stop the running app BEFORE replacing the bundle. If the bundled agent is loaded,
# a plain kill would be relaunched by KeepAlive mid-copy, so boot it out first.
# That only unloads it for THIS login session: the registration stays, and launchd
# loads it again at next login.
AGENT_WAS_LOADED=0
if launchctl print "${DOMAIN}/${AGENT_LABEL}" >/dev/null 2>&1; then
    AGENT_WAS_LOADED=1
    echo "==> stopping bundled launch agent ${AGENT_LABEL} for this session"
    launchctl bootout "${DOMAIN}/${AGENT_LABEL}" 2>/dev/null || true
fi
echo "==> stopping any running ${APP_NAME} instance"
killall "${APP_NAME}" 2>/dev/null || true

echo "==> installing ${SRC_APP} -> ${DEST_APP}"
rm -rf "${DEST_APP}"
cp -R "${SRC_APP}" "${DEST_APP}"

echo "==> launching ${DEST_APP}"
open "${DEST_APP}"

# ND-082 handover: a copy started with `open` has no KeepAlive. If "Start at login"
# is on, the app reloads its bundled agent (booted out above), hands over to the
# launchd-managed copy and exits. Give it a few seconds, then report honestly.
MANAGED=0
if [ "${AGENT_WAS_LOADED}" = "1" ]; then
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if launchctl print "${DOMAIN}/${AGENT_LABEL}" 2>/dev/null | grep -Eq '^[[:space:]]*pid = [0-9]+'; then
            MANAGED=1
            break
        fi
    done
fi

echo ""
echo "Installed: ${DEST_APP}"
if [ "${MANAGED}" = "1" ]; then
    echo "Start at login is on, and No Donuts is running under its launch agent"
    echo "(relaunched automatically after a crash or kill)."
elif [ "${AGENT_WAS_LOADED}" = "1" ]; then
    echo "Start at login is on, but this session's copy could not hand over to the launch"
    echo "agent (it may need approval again after a rebuild: System Settings › General ›"
    echo "Login Items). It is running without crash/kill relaunch until next login, or"
    echo "until you toggle Settings › \"Start at login\" off and on."
else
    echo "To start at login (with crash/kill relaunch): Settings › \"Start at login\"."
fi
echo "On first launch, grant Camera (and Location, if you use trusted Wi-Fi) when prompted."
echo "To stop auto-starting: scripts/uninstall.sh --keep-app  (full removal: scripts/uninstall.sh [--purge])"
