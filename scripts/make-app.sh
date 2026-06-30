#!/usr/bin/env bash
# No Donuts — assemble and ad-hoc-sign a runnable .app bundle from the SPM build.
#
# CLT-friendly: needs only Command Line Tools + `codesign` (no full Xcode,
# no .xcodeproj). Ad-hoc signing (`--sign -`) is enough to get the camera
# permission prompt and LSUIElement behavior for LOCAL runs. Developer-ID
# signing + notarization for distribution is a separate step (ND-050, ADR-0008).
#
# Usage:
#   scripts/make-app.sh            # release build (default)
#   scripts/make-app.sh --debug    # debug build (faster compile)
#
# See ADR-0008 and .claude/skills/build-run/SKILL.md.

set -euo pipefail

# Run from the repo root so the relative paths below resolve regardless of cwd.
cd "$(git rev-parse --show-toplevel)"

# --- config -----------------------------------------------------------------
CONFIG="release"
if [ "${1:-}" = "--debug" ]; then
    CONFIG="debug"
fi

APP_NAME="NoDonuts"        # CFBundleExecutable / SPM product name
APP_DIR="build/${APP_NAME}.app"
INFO_PLIST="Resources/Info.plist"
ENTITLEMENTS="Resources/NoDonuts.entitlements"

# --- build ------------------------------------------------------------------
echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

# --- assemble bundle (idempotent: wipe any prior build) ---------------------
echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${INFO_PLIST}" "${APP_DIR}/Contents/Info.plist"

# --- ad-hoc codesign (local dev) --------------------------------------------
# Ad-hoc identity "-" works without a Developer ID for local runs. The camera
# entitlement is embedded so the TCC prompt fires correctly.
echo "==> ad-hoc codesign"
codesign --force --sign - \
    --entitlements "${ENTITLEMENTS}" \
    --timestamp=none \
    "${APP_DIR}"

# --- done -------------------------------------------------------------------
echo ""
echo "Built: ${APP_DIR}"
echo "  Run:           open ${APP_DIR}"
echo "  Reset camera:  tccutil reset Camera com.nodonuts.app   # re-test the permission prompt"
