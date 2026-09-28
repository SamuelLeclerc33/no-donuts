#!/usr/bin/env bash
# No Donuts — assemble and sign a runnable .app bundle from the SPM build.
#
# CLT-friendly: needs only Command Line Tools + `codesign` (no full Xcode,
# no .xcodeproj). Signs with the stable self-signed "No Donuts Dev" identity if
# present (create it once with scripts/make-dev-cert.sh), else ad-hoc (`--sign -`).
# Either is enough to get the camera permission prompt and LSUIElement behavior
# for LOCAL runs; the dev identity keeps the Camera (TCC) grant across rebuilds
# (the Keychain still re-prompts once per changed binary without a Team ID). Developer-ID signing + notarization for distribution is a
# separate step (ND-050, ADR-0008).
#
# Usage:
#   scripts/make-app.sh            # dev mode, optimized (-c release) build (default)
#   scripts/make-app.sh --debug    # dev mode, debug build (faster compile)
#   scripts/make-app.sh --release  # release mode (ND-104): optimized build, and the
#                                  # Core ML model MUST be present and match its recorded
#                                  # SHA-256 (ND-087), else the build fails
#
# Dev mode is best-effort about the model: absent → warning + Vision fallback; hash
# mismatch → loud warning, still bundled. Release mode turns both into hard errors so a
# shippable build can never silently lose face identity or ship different weights.
# (Release mode does not yet mean Developer-ID signing; that is ND-050.)
#
# See ADR-0008 and .claude/skills/build-run/SKILL.md.

set -euo pipefail

# Run from the repo root so the relative paths below resolve regardless of cwd.
cd "$(git rev-parse --show-toplevel)"

# --- config -----------------------------------------------------------------
CONFIG="release"   # SPM build configuration
MODE="dev"         # dev | release (ND-104)
for arg in "$@"; do
    case "${arg}" in
        --debug)   CONFIG="debug" ;;
        --release) MODE="release" ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: ${arg} (expected --debug or --release)" >&2; exit 2 ;;
    esac
done
if [ "${MODE}" = "release" ] && [ "${CONFIG}" = "debug" ]; then
    echo "error: --release and --debug can't be combined (release mode is always an optimized build)" >&2
    exit 2
fi
echo "==> mode: ${MODE} (swift build -c ${CONFIG})"

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

# --- Core ML face model (ND-021 Phase 2 / ADR-0014, ND-087, ND-104) ----------
# Drop the compiled FaceNet model (.mlmodelc) into Contents/Resources/ so Bundle.main
# resolves it at runtime and CoreMLFaceEmbedder loads it. The blobs are git-ignored
# (reproduce via Resources/Models/convert_facenet.py + the pinned
# Resources/Models/requirements.txt; see Resources/Models/README.md). What IS committed is
# the model's SHA-256 (Resources/Models/FaceNetVGGFace2.sha256, from scripts/model-hash.sh),
# so a different model can't ship under the same descriptor version.
#
# Precedence:
#   a. A PRE-COMPILED Resources/Models/*.mlmodelc -> verify its hash, then copy it. The
#      PRIMARY, Xcode-free path (produced by coremltools.models.utils.compile_model).
#   b. Else a .mlpackage AND full-Xcode coremlcompiler -> compile it (dev only; the
#      output can't be checked against the recorded hash, so release mode refuses it).
#   c. Else -> dev: honest warning, the app falls back to the Vision embedder.
#             release: hard error.
MODEL_PKG="Resources/Models/FaceNetVGGFace2.mlpackage"
MODEL_SRC_MLMODELC="Resources/Models/FaceNetVGGFace2.mlmodelc"
MODEL_SHA_FILE="Resources/Models/FaceNetVGGFace2.sha256"
MODEL_MLMODELC="${APP_DIR}/Contents/Resources/FaceNetVGGFace2.mlmodelc"

# Fail in release mode; warn loudly in dev mode.
model_problem() {
    if [ "${MODE}" = "release" ]; then
        echo "error: $1" >&2
        echo "       release mode (--release) requires the verified Core ML model (ND-104)." >&2
        echo "       See Resources/Models/README.md to reproduce it." >&2
        exit 1
    fi
    echo "" >&2
    echo "!!! WARNING: $1" >&2
    echo "!!! Dev build continues. A --release build would FAIL here (ND-104)." >&2
    echo "" >&2
}

# The recorded hash is the last non-comment, non-blank line of the .sha256 file.
EXPECTED_MODEL_SHA=""
if [ -f "${MODEL_SHA_FILE}" ]; then
    EXPECTED_MODEL_SHA="$(grep -v '^[[:space:]]*#' "${MODEL_SHA_FILE}" | grep -v '^[[:space:]]*$' | tail -n 1 | awk '{ print $1 }' || true)"  # || true: empty/comment-only file must reach the -z branch, not die under pipefail
fi

if [ -d "${MODEL_SRC_MLMODELC}" ]; then
    # (a) Pre-compiled model — the normal, Xcode-free path. Verify, then copy.
    ACTUAL_MODEL_SHA="$(scripts/model-hash.sh "${MODEL_SRC_MLMODELC}")"
    if [ -z "${EXPECTED_MODEL_SHA}" ]; then
        model_problem "no recorded model hash in ${MODEL_SHA_FILE}; can't verify ${MODEL_SRC_MLMODELC} (actual ${ACTUAL_MODEL_SHA})"
    elif [ "${ACTUAL_MODEL_SHA}" != "${EXPECTED_MODEL_SHA}" ]; then
        model_problem "Core ML model hash MISMATCH (ND-087):
         ${MODEL_SRC_MLMODELC}
         expected ${EXPECTED_MODEL_SHA}  (${MODEL_SHA_FILE})
         actual   ${ACTUAL_MODEL_SHA}
         These are different weights under the same descriptor version, so stored
         enrollments would be compared across models. If you regenerated the model on
         purpose, bump the descriptor version and re-record the hash
         (scripts/model-hash.sh > ${MODEL_SHA_FILE})."
    else
        echo "==> Core ML model hash verified: ${ACTUAL_MODEL_SHA}"
    fi
    echo "==> copying pre-compiled Core ML model ${MODEL_SRC_MLMODELC} -> $(basename "${MODEL_MLMODELC}")"
    cp -R "${MODEL_SRC_MLMODELC}" "${MODEL_MLMODELC}"
    if [ -d "${MODEL_MLMODELC}" ]; then
        # Re-hash the bundled copy so a bad copy can't slip through either.
        if [ "$(scripts/model-hash.sh "${MODEL_MLMODELC}")" != "${ACTUAL_MODEL_SHA}" ]; then
            model_problem "the bundled copy ${MODEL_MLMODELC} doesn't hash like its source"
        fi
        echo "    bundled (pre-compiled, no Xcode): ${MODEL_MLMODELC}"
    else
        model_problem "copy of ${MODEL_SRC_MLMODELC} did not land at ${MODEL_MLMODELC}; the app would fall back to the Vision embedder"
    fi
elif [ -d "${MODEL_PKG}" ]; then
    # (b) Fallback for full-Xcode machines: compile the .mlpackage on the fly.
    if [ "${MODE}" = "release" ]; then
        model_problem "only ${MODEL_PKG} is present; release mode needs the pre-compiled ${MODEL_SRC_MLMODELC} so its hash can be verified against ${MODEL_SHA_FILE}"
    fi
    # coremlcompiler ships with FULL Xcode, NOT Command Line Tools. Probe it so a
    # CLT-only machine gets an honest warning instead of an opaque failure.
    if xcrun --find coremlcompiler >/dev/null 2>&1; then
        echo "==> compiling Core ML model ${MODEL_PKG} -> $(basename "${MODEL_MLMODELC}")"
        echo "    note: a model compiled here is NOT checked against ${MODEL_SHA_FILE}"
        # coremlcompiler writes <dest_dir>/<pkgbasename>.mlmodelc; point it at Resources/.
        xcrun coremlcompiler compile "${MODEL_PKG}" "${APP_DIR}/Contents/Resources"
        if [ -d "${MODEL_MLMODELC}" ]; then
            echo "    bundled (compiled via coremlcompiler): ${MODEL_MLMODELC}"
        else
            model_problem "coremlcompiler ran but ${MODEL_MLMODELC} was not produced; the app will fall back to the Vision embedder"
        fi
    else
        model_problem "only a .mlpackage is present and 'xcrun coremlcompiler' is not found
         (it ships with full Xcode, not Command Line Tools). Pre-compile it with
         coremltools (no Xcode) into ${MODEL_SRC_MLMODELC} — see
         Resources/Models/README.md. Skipping Core ML bundling; the app will fall back
         to the Vision embedder. (ND-021 Phase 2)"
    fi
else
    model_problem "neither ${MODEL_SRC_MLMODELC} nor ${MODEL_PKG} found — Core ML model not
         bundled; the app will fall back to the Vision embedder. To reproduce the model,
         see Resources/Models/README.md (convert_facenet.py). (ND-021 Phase 2)"
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
echo "Built: ${APP_DIR}  (mode: ${MODE}, -c ${CONFIG})"
echo "  Run:           open ${APP_DIR}"
echo "  Reset camera:  tccutil reset Camera com.nodonuts.app   # re-test the permission prompt"
