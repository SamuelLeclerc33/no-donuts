#!/usr/bin/env bash
# No Donuts — assemble and sign a runnable .app bundle from the SPM build.
#
# CLT-friendly: needs only Command Line Tools + `codesign` (no full Xcode,
# no .xcodeproj). Signs with the stable self-signed "No Donuts Dev" identity if
# present (create it once with scripts/make-dev-cert.sh), else ad-hoc (`--sign -`).
# Either is enough to get the camera permission prompt and LSUIElement behavior
# for LOCAL runs; the dev identity additionally stops Keychain/TCC re-prompts on
# every rebuild. Developer-ID signing + notarization for distribution is a
# separate step (ND-050, ADR-0008).
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
# Drop the compiled FaceNet model (.mlmodelc) into Contents/Resources/ so Bundle.main
# resolves it at runtime and CoreMLFaceEmbedder loads it. The blobs are git-ignored
# (reproduce via Resources/Models/convert_facenet.py + coremltools; see
# Resources/Models/README.md). Precedence (all BEST-EFFORT — the build always succeeds):
#   a. A PRE-COMPILED Resources/Models/*.mlmodelc  -> copy it. This is the PRIMARY,
#      Xcode-free path (produced by coremltools.models.utils.compile_model).
#   b. Else a .mlpackage AND full-Xcode coremlcompiler -> compile it (fallback).
#   c. Else -> honest warning; the app falls back to the Vision embedder.
MODEL_PKG="Resources/Models/FaceNetVGGFace2.mlpackage"
MODEL_SRC_MLMODELC="Resources/Models/FaceNetVGGFace2.mlmodelc"
MODEL_MLMODELC="${APP_DIR}/Contents/Resources/FaceNetVGGFace2.mlmodelc"
if [ -d "${MODEL_SRC_MLMODELC}" ]; then
    # (a) Pre-compiled model — the normal, Xcode-free path. Just copy it in.
    echo "==> copying pre-compiled Core ML model ${MODEL_SRC_MLMODELC} -> $(basename "${MODEL_MLMODELC}")"
    cp -R "${MODEL_SRC_MLMODELC}" "${MODEL_MLMODELC}"
    if [ -d "${MODEL_MLMODELC}" ]; then
        echo "    bundled (pre-compiled, no Xcode): ${MODEL_MLMODELC}"
    else
        echo "warning: copy of ${MODEL_SRC_MLMODELC} did not land at ${MODEL_MLMODELC};" >&2
        echo "         the app will fall back to the Vision embedder." >&2
    fi
elif [ -d "${MODEL_PKG}" ]; then
    # (b) Fallback for full-Xcode machines: compile the .mlpackage on the fly.
    # coremlcompiler ships with FULL Xcode, NOT Command Line Tools. Probe it so a
    # CLT-only machine gets an honest warning instead of an opaque failure.
    if xcrun --find coremlcompiler >/dev/null 2>&1; then
        echo "==> compiling Core ML model ${MODEL_PKG} -> $(basename "${MODEL_MLMODELC}")"
        # coremlcompiler writes <dest_dir>/<pkgbasename>.mlmodelc; point it at Resources/.
        xcrun coremlcompiler compile "${MODEL_PKG}" "${APP_DIR}/Contents/Resources"
        if [ -d "${MODEL_MLMODELC}" ]; then
            echo "    bundled (compiled via coremlcompiler): ${MODEL_MLMODELC}"
        else
            echo "warning: coremlcompiler ran but ${MODEL_MLMODELC} was not produced;" >&2
            echo "         the app will fall back to the Vision embedder." >&2
        fi
    else
        echo "warning: only a .mlpackage is present and 'xcrun coremlcompiler' is not found" >&2
        echo "         (it ships with full Xcode, not Command Line Tools). Pre-compile it with" >&2
        echo "         coremltools (no Xcode) into ${MODEL_SRC_MLMODELC} — see" >&2
        echo "         Resources/Models/README.md. Skipping Core ML bundling; the app will" >&2
        echo "         fall back to the Vision embedder. (ND-021 Phase 2)" >&2
    fi
else
    echo "warning: neither ${MODEL_SRC_MLMODELC} nor ${MODEL_PKG} found — Core ML model not" >&2
    echo "         bundled; the app will fall back to the Vision embedder. To reproduce the" >&2
    echo "         model, see Resources/Models/README.md (convert_facenet.py). (ND-021 Phase 2)" >&2
fi

# --- bundled LaunchAgent (ND-082 / ND-083) -----------------------------------
# The app's single launcher: Settings › "Start at login" registers this plist via
# SMAppService.agent(plistName:) (LoginItem.swift). It MUST sit at
# Contents/Library/LaunchAgents/ and be copied BEFORE codesign so it is sealed by
# the bundle signature. Unlike the model, this is REQUIRED: fail the build if absent.
AGENT_PLIST_NAME="com.nodonuts.app.agent.plist"
AGENT_PLIST_SRC="Resources/LaunchAgents/${AGENT_PLIST_NAME}"
if [ ! -f "${AGENT_PLIST_SRC}" ]; then
    echo "error: ${AGENT_PLIST_SRC} not found (the bundled launch agent)" >&2
    exit 1
fi
plutil -lint -s "${AGENT_PLIST_SRC}"
echo "==> bundling launch agent ${AGENT_PLIST_NAME} -> Contents/Library/LaunchAgents/"
mkdir -p "${APP_DIR}/Contents/Library/LaunchAgents"
cp "${AGENT_PLIST_SRC}" "${APP_DIR}/Contents/Library/LaunchAgents/${AGENT_PLIST_NAME}"

# --- codesign (local dev) ---------------------------------------------------
# Prefer the stable self-signed "No Donuts Dev" identity (scripts/make-dev-cert.sh):
# its designated requirement survives rebuilds, so the login-keychain ACL and the
# TCC camera grant keep matching and macOS stops re-prompting after every build.
# Otherwise fall back to ad-hoc ("-"), whose DR is the cdhash (changes every build).
# Either way the camera entitlement is embedded so the TCC prompt fires correctly.
# Hardened runtime is intentionally NOT enabled here (that's ND-050 distribution).
DEV_IDENTITY_NAME="No Donuts Dev"
# Sign by SHA-1 hash (not name) so a duplicate cert can't make codesign ambiguous.
DEV_IDENTITY_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v name="\"${DEV_IDENTITY_NAME}\"" 'index($0, name) && $2 ~ /^[0-9A-F]{40}$/ { print $2; exit }' \
    || true)"

if [ -n "${DEV_IDENTITY_HASH}" ]; then
    echo "==> codesign with stable dev identity \"${DEV_IDENTITY_NAME}\" (${DEV_IDENTITY_HASH})"
    SIGN_IDENTITY="${DEV_IDENTITY_HASH}"
else
    echo "==> ad-hoc codesign (no \"${DEV_IDENTITY_NAME}\" identity found)"
    echo "    hint: run scripts/make-dev-cert.sh once so rebuilds stop re-prompting for"
    echo "          Keychain access and the camera permission."
    SIGN_IDENTITY="-"
fi
codesign --force --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    --timestamp=none \
    "${APP_DIR}"

# --- done -------------------------------------------------------------------
echo ""
echo "Built: ${APP_DIR}"
echo "  Run:           open ${APP_DIR}"
echo "  Reset camera:  tccutil reset Camera com.nodonuts.app   # re-test the permission prompt"
