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

# --- Core ML face model (ND-021 Phase 2 / ADR-0014) -------------------------
# If the FaceNet model package is present, compile it to a .mlmodelc and drop it in
# Contents/Resources/ so Bundle.main resolves it at runtime and CoreMLFaceEmbedder
# loads it. The blob is git-ignored (reproduce via Resources/Models/convert_facenet.py;
# see Resources/Models/README.md). Everything here is BEST-EFFORT: if the package is
# absent OR coremlcompiler isn't available, warn and continue — the build must still
# succeed and the app falls back to the Vision embedder.
MODEL_PKG="Resources/Models/FaceNetVGGFace2.mlpackage"
MODEL_MLMODELC="${APP_DIR}/Contents/Resources/FaceNetVGGFace2.mlmodelc"
if [ -d "${MODEL_PKG}" ]; then
    # coremlcompiler ships with FULL Xcode, NOT Command Line Tools. Probe it so a
    # CLT-only machine gets an honest warning instead of an opaque failure.
    if xcrun --find coremlcompiler >/dev/null 2>&1; then
        echo "==> compiling Core ML model ${MODEL_PKG} -> $(basename "${MODEL_MLMODELC}")"
        # coremlcompiler writes <dest_dir>/<pkgbasename>.mlmodelc; point it at Resources/.
        xcrun coremlcompiler compile "${MODEL_PKG}" "${APP_DIR}/Contents/Resources"
        if [ -d "${MODEL_MLMODELC}" ]; then
            echo "    bundled: ${MODEL_MLMODELC}"
        else
            echo "warning: coremlcompiler ran but ${MODEL_MLMODELC} was not produced;" >&2
            echo "         the app will fall back to the Vision embedder." >&2
        fi
    else
        echo "warning: 'xcrun coremlcompiler' not found — it ships with full Xcode, not" >&2
        echo "         Command Line Tools (ADR-0008). Skipping Core ML model bundling;" >&2
        echo "         the app will fall back to the Vision embedder. Install Xcode and" >&2
        echo "         re-run to bundle the FaceNet model (ND-021 Phase 2)." >&2
    fi
else
    echo "warning: ${MODEL_PKG} not found — Core ML model not bundled; the app will fall" >&2
    echo "         back to the Vision embedder. To reproduce the model, see" >&2
    echo "         Resources/Models/README.md (convert_facenet.py). (ND-021 Phase 2)" >&2
fi

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
