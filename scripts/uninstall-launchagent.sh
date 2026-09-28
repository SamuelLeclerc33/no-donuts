#!/usr/bin/env bash
# No Donuts — stop No Donuts and stop it starting at login.
#
# Handles both launchers (ND-083):
#   - the bundled agent com.nodonuts.app.agent (registered by Settings › "Start at
#     login" via SMAppService): booted out for this session, then its REGISTRATION
#     is removed by the app itself (`NoDonuts --unregister`; a script can't call
#     SMAppService). That also removes a legacy SMAppService.mainApp login item.
#   - the legacy ND-016 agent com.nodonuts.agent: booted out and its plist deleted
#     (scripts/migrate-launcher.sh).
# Kills any remaining copy (e.g. one started with `open`), then `--unregister` also
# clears No Donuts' pending/delivered notifications, so the "No Donuts isn't
# running" dead-man alert (ND-082) doesn't fire ~10 min after uninstalling.
#
# Does NOT remove /Applications/NoDonuts.app or enrolled data (ND-052).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

AGENT_LABEL="com.nodonuts.app.agent"
DOMAIN="gui/$(id -u)"

if launchctl print "${DOMAIN}/${AGENT_LABEL}" >/dev/null 2>&1; then
    echo "==> stopping bundled launch agent ${AGENT_LABEL} for this session"
    launchctl bootout "${DOMAIN}/${AGENT_LABEL}" 2>/dev/null || true
fi

echo "==> removing the legacy launcher (if any)"
scripts/migrate-launcher.sh >/dev/null

# bootout only stops a launchd-managed instance; a copy launched by hand keeps
# running (and keeps locking) after the user thinks it's off.
echo "==> stopping any running NoDonuts instance"
killall NoDonuts 2>/dev/null || true

APP_BIN="/Applications/NoDonuts.app/Contents/MacOS/NoDonuts"
UNREGISTERED=0
if [ -x "${APP_BIN}" ]; then
    echo "==> removing the start-at-login registration + pending notifications"
    # CLI mode: no UI, no camera; handled before the single-instance guard.
    # It always exits 0 (errors are logged, never fatal), so read its report.
    if OUT="$("${APP_BIN}" --unregister 2>&1)"; then
        echo "${OUT}" | sed 's/^/    /'
        if ! echo "${OUT}" | grep -q "unregister failed"; then
            UNREGISTERED=1
        fi
    else
        echo "${OUT}" | sed 's/^/    /'
    fi
fi

echo ""
echo "No Donuts stopped."
if [ "${UNREGISTERED}" = "1" ]; then
    echo "Start at login is off (registration removed)."
else
    echo "IMPORTANT: couldn't run ${APP_BIN} --unregister. If \"Start at login\" was on, it"
    echo "is still registered and will start No Donuts at next login. Turn it off in the"
    echo "app (Settings → \"Start at login\") or in System Settings › General › Login Items."
fi
echo "Note: /Applications/NoDonuts.app and app data are left in place (full removal: ND-052)."
