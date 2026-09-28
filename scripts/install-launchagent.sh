#!/usr/bin/env bash
# DEPRECATED (ND-082 / ND-083): No Donuts no longer installs a LaunchAgent into
# ~/Library/LaunchAgents. The launcher is now bundled inside the app and turned on
# from Settings › "Start at login". This wrapper just forwards to install-app.sh,
# which also removes the old ~/Library/LaunchAgents/com.nodonuts.agent.plist.

set -euo pipefail

echo "note: install-launchagent.sh is deprecated; running scripts/install-app.sh." >&2
echo "      Start at login is now set in the app: Settings › \"Start at login\"." >&2
exec "$(git rev-parse --show-toplevel)/scripts/install-app.sh" "$@"
