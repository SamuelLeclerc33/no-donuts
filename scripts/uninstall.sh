#!/usr/bin/env bash
# No Donuts — uninstall (ND-052).
#
# Self-contained: does not need the git checkout, so IT can hand this one file to a
# colleague or run it from an MDM script. Per-user: run it as the logged-in user,
# NOT with sudo (the launcher, preferences and Keychain item all live in the user's
# session; as root they would silently target root's instead).
#
# Usage:
#   scripts/uninstall.sh                     # remove the app + launchers, keep data
#   scripts/uninstall.sh --purge             # ...and delete ALL local No Donuts data
#   scripts/uninstall.sh --purge --yes       # same, without the typed confirmation
#   scripts/uninstall.sh --keep-app          # only stop it + stop start-at-login
#   scripts/uninstall.sh [...] --dry-run     # print the plan, change nothing
#
# Default steps, in this order:
#   1. Stop the app: `launchctl bootout` the bundled KeepAlive agent
#      com.nodonuts.app.agent (ADR-0018) FIRST, so launchd doesn't relaunch what we
#      kill, then stop any other copy (e.g. one started with `open`).
#   2. `NoDonuts --unregister`: removes the SMAppService agent registration and the
#      legacy mainApp login item, and clears pending/delivered notifications, so the
#      "No Donuts isn't running" dead-man alert (ND-082) doesn't fire ~10 min later.
#      Must run while the binary still exists (a script can't call SMAppService).
#   3. Remove the legacy ND-016 agent (~/Library/LaunchAgents/com.nodonuts.agent.plist).
#   4. Remove /Applications/NoDonuts.app (skipped with --keep-app). The bundle id is
#      checked first; a symlink or a different app at that path is refused.
#
# --purge additionally deletes, after step 2 and before step 4:
#   - the Keychain enrollment item (service "com.nodonuts.app", account "enrollment";
#     AppIdentity.keychainService, fixed forever per ND-065): the face signature
#   - the preferences domain com.nodonuts.app (`defaults delete`): settings, trusted
#     Wi-Fi networks, threshold overrides
#   - the app's TCC decisions: `tccutil reset All com.nodonuts.app` (Camera, and any
#     other TCC service, for THIS bundle id only). Runs before the app is removed,
#     because tccutil resolves the bundle id through LaunchServices.
#   - ~/Library/Application Support/NoDonuts (instance.lock, ND-083)
#   - ~/Library/Caches/com.nodonuts.app (Core ML compiled-model cache)
#   - ~/Library/HTTPStorages/com.nodonuts.app, ~/Library/Saved Application State/
#     com.nodonuts.app.savedState (system-created; usually absent)
# Only those fixed paths/identifiers are touched. No globbing, no wildcards.
#
# NOT removable by a script (printed at the end): the Location and Local Network
# decisions (not in TCC; macOS drops them once the app is gone), the entry in System
# Settings › Notifications, crash reports in ~/Library/Logs/DiagnosticReports
# (system-owned; they contain no images or embeddings) and the unified log.
#
# Exit status: 0 on success, 1 if any step failed unexpectedly (each step is still
# attempted), 2 on bad usage / refused confirmation.
#
# scripts/uninstall-launchagent.sh is kept as an alias for `uninstall.sh --keep-app`.

set -uo pipefail

BUNDLE_ID="com.nodonuts.app"            # CFBundleIdentifier (AppIdentity.bundleID)
: "${HOME:?HOME must be set and non-empty}"   # never build purge paths from an empty HOME
KEYCHAIN_SERVICE="com.nodonuts.app"     # AppIdentity.keychainService (fixed, ND-065)
KEYCHAIN_ACCOUNT="enrollment"           # EnrollmentStore default account
DEFAULTS_DOMAIN="com.nodonuts.app"      # AppIdentity.defaultsDomain
AGENT_LABEL="com.nodonuts.app.agent"    # bundled SMAppService agent (ADR-0018)
LEGACY_LABEL="com.nodonuts.agent"       # ND-016 script-installed agent
APP_NAME="NoDonuts"
APP_PATH="/Applications/${APP_NAME}.app"
APP_BIN="${APP_PATH}/Contents/MacOS/${APP_NAME}"
LEGACY_PLIST="${HOME}/Library/LaunchAgents/${LEGACY_LABEL}.plist"
SUPPORT_DIR="${HOME}/Library/Application Support/NoDonuts"
PURGE_DIRS=(
    "${SUPPORT_DIR}"
    "${HOME}/Library/Caches/${BUNDLE_ID}"
    "${HOME}/Library/HTTPStorages/${BUNDLE_ID}"
    "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
)
DOMAIN="gui/$(id -u)"

PURGE=0
YES=0
DRY_RUN=0
KEEP_APP=0
FAILURES=0

usage() {
    sed -n '9,14p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "${arg}" in
        --purge)    PURGE=1 ;;
        --yes|-y)   YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --keep-app) KEEP_APP=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "uninstall.sh: unknown option: ${arg}" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "${PURGE}" = "1" ] && [ "${KEEP_APP}" = "1" ]; then
    echo "uninstall.sh: --purge and --keep-app together would delete your data but leave" >&2
    echo "the app installed (it would come back 'not enrolled'). Pick one." >&2
    exit 2
fi

if [ "$(id -u)" = "0" ]; then
    echo "uninstall.sh: don't run this with sudo. No Donuts' launcher, settings and" >&2
    echo "Keychain item belong to the logged-in user; as root this would miss them." >&2
    exit 2
fi

step()  { echo "==> $*"; }
info()  { echo "    $*"; }
fail()  { echo "    FAILED: $*" >&2; FAILURES=$((FAILURES + 1)); }

# ---- read-only probes (safe in --dry-run) --------------------------------------

agent_loaded()   { launchctl print "${DOMAIN}/${AGENT_LABEL}" >/dev/null 2>&1; }
legacy_loaded()  { launchctl print "${DOMAIN}/${LEGACY_LABEL}" >/dev/null 2>&1; }
app_running()    { pgrep -x "${APP_NAME}" >/dev/null 2>&1; }
# Attributes only (no -g / -w): never reads the secret, never prompts.
keychain_item_present() {
    security find-generic-password -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1
}
defaults_present() { defaults read "${DEFAULTS_DOMAIN}" >/dev/null 2>&1; }
app_bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP_PATH}/Contents/Info.plist" 2>/dev/null
}
state() { if "$@"; then echo "present"; else echo "not present"; fi; }

# ---- plan ------------------------------------------------------------------------

print_plan() {
    local verb="Will"
    [ "${DRY_RUN}" = "1" ] && verb="Would"
    echo "No Donuts uninstall plan$([ "${DRY_RUN}" = "1" ] && echo " (dry run: nothing will change)"):"
    echo ""
    echo "${verb} stop / unregister:"
    echo "  - bundled launch agent ${DOMAIN}/${AGENT_LABEL}: $(agent_loaded && echo "loaded" || echo "not loaded")"
    echo "  - running ${APP_NAME} process(es): $(app_running && echo "running (pid $(pgrep -x "${APP_NAME}" | tr '\n' ' ' | sed 's/ $//'))" || echo "none")"
    echo "  - start-at-login registration + pending notifications, via ${APP_BIN} --unregister: $([ -x "${APP_BIN}" ] && echo "binary present" || echo "binary NOT found, can't unregister")"
    echo "  - legacy agent ${DOMAIN}/${LEGACY_LABEL}: $(legacy_loaded && echo "loaded" || echo "not loaded"); plist ${LEGACY_PLIST}: $(state test -e "${LEGACY_PLIST}")"
    if [ "${KEEP_APP}" = "1" ]; then
        echo "  - ${APP_PATH}: kept (--keep-app)"
    else
        echo "  - ${APP_PATH}: $(state test -e "${APP_PATH}")"
    fi
    if [ "${PURGE}" = "1" ]; then
        echo ""
        echo "${verb} PERMANENTLY DELETE (--purge):"
        echo "  - Keychain item service=\"${KEYCHAIN_SERVICE}\" account=\"${KEYCHAIN_ACCOUNT}\" (your enrolled face signature): $(state keychain_item_present)"
        echo "  - preferences domain ${DEFAULTS_DOMAIN} (settings, trusted Wi-Fi, overrides): $(state defaults_present)"
        echo "  - privacy (TCC) decisions for ${BUNDLE_ID} only: tccutil reset All ${BUNDLE_ID} (Camera, ...)"
        local d
        for d in "${PURGE_DIRS[@]}"; do
            echo "  - ${d}: $(state test -e "${d}")"
        done
    else
        echo ""
        echo "Data is KEPT (enrollment in Keychain, settings, camera permission). Add --purge to delete it."
    fi
    echo ""
}

print_plan

if [ "${DRY_RUN}" = "1" ]; then
    echo "Dry run: nothing was changed."
    exit 0
fi

if [ "${PURGE}" = "1" ] && [ "${YES}" != "1" ]; then
    if [ ! -t 0 ]; then
        echo "uninstall.sh: --purge needs a typed confirmation; stdin isn't a terminal. Re-run with --yes." >&2
        exit 2
    fi
    printf 'Type "yes" to delete everything listed above: '
    read -r answer
    if [ "${answer}" != "yes" ]; then
        echo "Not confirmed. Nothing was changed."
        exit 2
    fi
fi

# ---- 1. stop -----------------------------------------------------------------------

# Bootout FIRST: the agent is KeepAlive (SuccessfulExit=false), so a killed copy would
# be relaunched within ~10 s while the agent is still loaded.
if agent_loaded; then
    step "stopping bundled launch agent ${AGENT_LABEL} for this session"
    launchctl bootout "${DOMAIN}/${AGENT_LABEL}" 2>/dev/null || true
    if agent_loaded; then fail "launchctl bootout ${DOMAIN}/${AGENT_LABEL}"; fi
fi
if legacy_loaded; then
    step "stopping legacy LaunchAgent ${LEGACY_LABEL}"
    launchctl bootout "${DOMAIN}/${LEGACY_LABEL}" 2>/dev/null || true
    if legacy_loaded; then fail "launchctl bootout ${DOMAIN}/${LEGACY_LABEL}"; fi
fi

if app_running; then
    step "stopping running ${APP_NAME}"
    killall "${APP_NAME}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        app_running || break
        sleep 0.5
    done
    if app_running; then
        info "still running after 5 s; sending SIGKILL"
        killall -KILL "${APP_NAME}" 2>/dev/null || true
        sleep 1
    fi
    # A live copy would keep locking and could rewrite the preferences we delete.
    if app_running; then fail "${APP_NAME} is still running (pid $(pgrep -x "${APP_NAME}" | tr '\n' ' '))"; fi
fi

# ---- 2. unregister ------------------------------------------------------------------

UNREGISTERED=0
# Only execute the bundle's binary if the bundle is really ours (not a symlink, right
# bundle id) — the same check step 4 applies before deleting it.
if [ -x "${APP_BIN}" ] && [ ! -L "${APP_PATH}" ] && [ "$(app_bundle_id)" = "${BUNDLE_ID}" ]; then
    step "removing the start-at-login registration + pending notifications"
    # CLI mode: no UI, no camera, runs before the single-instance guard. It always
    # exits 0 (errors are logged, never fatal), so read its report.
    OUT="$("${APP_BIN}" --unregister 2>&1)"
    RC=$?
    if [ -n "${OUT}" ]; then
        while IFS= read -r line; do info "${line}"; done <<<"${OUT}"
    fi
    if [ "${RC}" = "0" ] && ! echo "${OUT}" | grep -q "unregister failed"; then
        UNREGISTERED=1
    else
        fail "${APP_BIN} --unregister (exit ${RC})"
    fi
else
    info "${APP_BIN} not found; can't remove the start-at-login registration or pending notifications"
fi

# ---- 3. legacy agent plist ----------------------------------------------------------

if [ -e "${LEGACY_PLIST}" ]; then
    step "removing ${LEGACY_PLIST}"
    rm -f "${LEGACY_PLIST}" || fail "rm ${LEGACY_PLIST}"
fi

# ---- purge (before the app is removed: tccutil needs the bundle registered) --------

if [ "${PURGE}" = "1" ]; then
    step "deleting the Keychain enrollment item"
    # Loop in case the item exists in more than one keychain in the search list.
    # Exit 44 = errSecItemNotFound: nothing (more) to delete.
    deleted=0
    for _ in 1 2 3 4 5; do
        security delete-generic-password -s "${KEYCHAIN_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" >/dev/null 2>&1
        rc=$?
        if [ "${rc}" = "0" ]; then deleted=$((deleted + 1)); continue; fi
        [ "${rc}" = "44" ] || fail "security delete-generic-password (exit ${rc})"
        break
    done
    info "deleted ${deleted} item(s)"
    if keychain_item_present; then fail "Keychain item ${KEYCHAIN_SERVICE}/${KEYCHAIN_ACCOUNT} still present"; fi

    step "deleting preferences domain ${DEFAULTS_DOMAIN}"
    if defaults_present; then
        defaults delete "${DEFAULTS_DOMAIN}" || fail "defaults delete ${DEFAULTS_DOMAIN}"
    else
        info "not present"
    fi

    step "resetting privacy (TCC) decisions for ${BUNDLE_ID}"
    if TCC_OUT="$(tccutil reset All "${BUNDLE_ID}" 2>&1)"; then
        info "${TCC_OUT:-done}"
    else
        # Typically "No such bundle identifier" when the app was already deleted
        # (LaunchServices no longer knows it). Nothing we can fix from here.
        info "${TCC_OUT}"
        fail "tccutil reset All ${BUNDLE_ID} (reset Camera in System Settings › Privacy & Security › Camera if No Donuts is still listed)"
    fi

    for d in "${PURGE_DIRS[@]}"; do
        if [ -L "${d}" ]; then
            fail "refusing to delete symlink ${d}"
        elif [ -e "${d}" ]; then
            step "removing ${d}"
            rm -rf -- "${d}" || fail "rm -rf ${d}"
        fi
    done
fi

# ---- 4. app bundle ------------------------------------------------------------------

if [ "${KEEP_APP}" != "1" ] && [ -e "${APP_PATH}" ]; then
    step "removing ${APP_PATH}"
    BID="$(app_bundle_id)"
    if [ -L "${APP_PATH}" ]; then
        fail "refusing to delete ${APP_PATH}: it is a symlink"
    elif [ "${BID}" != "${BUNDLE_ID}" ]; then
        fail "refusing to delete ${APP_PATH}: bundle id is '${BID}', expected ${BUNDLE_ID}"
    elif ! rm -rf -- "${APP_PATH}"; then
        fail "rm -rf ${APP_PATH} (installed by MDM/root? remove it with: sudo rm -rf ${APP_PATH})"
    fi
fi

# ---- report -------------------------------------------------------------------------

echo ""
LEFT=()
agent_loaded && LEFT+=("agent ${AGENT_LABEL} still loaded")
app_running && LEFT+=("${APP_NAME} still running")
[ -e "${LEGACY_PLIST}" ] && LEFT+=("${LEGACY_PLIST}")
if [ "${KEEP_APP}" != "1" ] && [ -e "${APP_PATH}" ]; then LEFT+=("${APP_PATH}"); fi
if [ "${UNREGISTERED}" != "1" ]; then
    LEFT+=("possibly the start-at-login registration (check System Settings › General › Login Items)")
fi
if [ "${PURGE}" = "1" ]; then
    keychain_item_present && LEFT+=("Keychain item ${KEYCHAIN_SERVICE}/${KEYCHAIN_ACCOUNT}")
    defaults_present && LEFT+=("preferences ${DEFAULTS_DOMAIN}")
    for d in "${PURGE_DIRS[@]}"; do [ -e "${d}" ] && LEFT+=("${d}"); done
fi

if [ "${KEEP_APP}" = "1" ]; then
    echo "No Donuts stopped and will not start at login. ${APP_PATH} is kept; open it to turn protection back on."
elif [ "${PURGE}" = "1" ]; then
    echo "No Donuts uninstalled and its local data purged."
else
    echo "No Donuts uninstalled. Your data is kept (enrollment in Keychain, settings);"
    echo "reinstalling picks it up again. To delete it: scripts/uninstall.sh --purge"
fi

if [ "${#LEFT[@]}" = "0" ]; then
    echo "What's left: nothing this script manages."
else
    echo "What's left:"
    for l in "${LEFT[@]}"; do echo "  - ${l}"; done
fi
if [ "${PURGE}" = "1" ]; then
    echo "Not removable by script (harmless, no face data): the Location / Local Network"
    echo "decisions and the System Settings › Notifications entry (macOS drops them once the"
    echo "app is gone), crash reports in ~/Library/Logs/DiagnosticReports, the unified log."
fi

if [ "${FAILURES}" != "0" ]; then
    echo ""
    echo "${FAILURES} step(s) failed; see FAILED lines above." >&2
    exit 1
fi
exit 0
