#!/usr/bin/env bash
# No Donuts — stop No Donuts and stop it starting at login, keeping the app and data.
#
# Kept for compatibility (README, older notes, muscle memory). It is now a thin alias:
#     scripts/uninstall.sh --keep-app [--dry-run]
# which boots out the bundled agent com.nodonuts.app.agent (ADR-0018), stops any
# running copy, runs `NoDonuts --unregister` (removes the SMAppService registration +
# pending notifications, so the dead-man alert doesn't fire) and removes the legacy
# ND-016 agent. /Applications/NoDonuts.app and enrolled data are left in place.
#
# Full removal: scripts/uninstall.sh (app) or scripts/uninstall.sh --purge (app + data).
# See ND-052.

set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uninstall.sh" --keep-app "$@"
