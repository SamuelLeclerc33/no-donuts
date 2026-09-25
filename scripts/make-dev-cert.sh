#!/usr/bin/env bash
# No Donuts — create (or remove) a stable, self-signed LOCAL code-signing identity.
#
# Why: scripts/make-app.sh ad-hoc signs by default (`codesign --sign -`). An ad-hoc
# signature's designated requirement is its cdhash, which changes on EVERY rebuild,
# so the login-keychain ACL ("NoDonuts wants to use your confidential information")
# and the TCC camera grant stop matching and macOS re-prompts after each build.
# Signing with a stable certificate makes the designated requirement
# `identifier "com.nodonuts.app" and certificate root = H"<cert hash>"`, which
# survives rebuilds.
#
# What it does:
#   1. Generates a self-signed cert "No Donuts Dev" (codeSigning EKU, ~10 years).
#      No Apple account, no network.
#   2. Imports cert + private key into your LOGIN keychain, pre-authorizing
#      /usr/bin/codesign to use the key.
#   3. Marks the cert as trusted for code signing in your USER trust settings
#      (macOS will ask for your login password / Touch ID once for this).
#   Temporary key material is written to a private temp dir and deleted on exit;
#   afterwards the private key lives only in the keychain.
#
# This identity is for LOCAL DEV ONLY. It is not a Developer ID; bundles signed
# with it are not Gatekeeper-distributable (distribution = ND-050).
#
# Usage:
#   scripts/make-dev-cert.sh            # create (idempotent; no-op if it already exists)
#   scripts/make-dev-cert.sh --remove   # delete the identity (cert + key) from the keychain

set -euo pipefail

IDENTITY_NAME="No Donuts Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
VALID_DAYS=3650

# Prefer Apple's /usr/bin/openssl (LibreSSL): its PKCS#12 output is always readable
# by `security import`. Homebrew OpenSSL 3 also works with the explicit legacy PBE
# flags used below.
if [ -x /usr/bin/openssl ]; then
    OPENSSL=/usr/bin/openssl
else
    OPENSSL="$(command -v openssl || true)"
fi

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# SHA-1 hashes of every "No Donuts Dev" code-signing identity (valid or not) in the keychain.
identity_hashes() {
    security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null \
        | awk -v name="\"${IDENTITY_NAME}\"" 'index($0, name) && $2 ~ /^[0-9A-F]{40}$/ { print $2 }' \
        | sort -u
}

# --- --remove ---------------------------------------------------------------
if [ "${1:-}" = "--remove" ]; then
    hashes="$(identity_hashes)"
    if [ -z "${hashes}" ]; then
        # There may still be a lone certificate (e.g. key already deleted).
        if security find-certificate -c "${IDENTITY_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
            hashes="$(security find-certificate -a -Z -c "${IDENTITY_NAME}" "${KEYCHAIN}" \
                | awk '/^SHA-1 hash:/ { print $3 }' | sort -u)"
        fi
    fi
    if [ -z "${hashes}" ]; then
        say "Nothing to remove: no \"${IDENTITY_NAME}\" identity in ${KEYCHAIN}."
        exit 0
    fi
    # Drop the user trust setting for EVERY matching cert first (may prompt for
    # your password; ignored if it was never set). `find-certificate -a -p` exports
    # all matches; split them so each gets its own remove-trusted-cert (a single
    # `-p` without `-a` would only ever export the first match).
    pem_dir="$(mktemp -d "${TMPDIR:-/tmp}/nodonuts-devcert.XXXXXX")"
    security find-certificate -a -c "${IDENTITY_NAME}" -p "${KEYCHAIN}" 2>/dev/null \
        | awk -v dir="${pem_dir}" '/BEGIN CERTIFICATE/ { n++ } n { print > (dir "/cert" n ".pem") }' || true
    for pem in "${pem_dir}"/cert*.pem; do
        [ -s "${pem}" ] && security remove-trusted-cert "${pem}" >/dev/null 2>&1 || true
    done
    rm -rf "${pem_dir}"
    for h in ${hashes}; do
        say "==> removing \"${IDENTITY_NAME}\" (${h})"
        # delete-identity removes cert + private key; fall back to cert-only.
        security delete-identity -Z "${h}" "${KEYCHAIN}" >/dev/null 2>&1 \
            || security delete-certificate -Z "${h}" "${KEYCHAIN}" >/dev/null 2>&1 \
            || say "    warning: could not delete ${h} (remove it manually in Keychain Access)"
    done
    say ""
    say "Removed. scripts/make-app.sh will fall back to ad-hoc signing."
    say "Note: bundles signed with the old identity keep their old keychain/TCC grants"
    say "      until you rebuild; expect one re-prompt after the next build."
    exit 0
fi

if [ -n "${1:-}" ]; then
    die "unknown argument '$1' (usage: $0 [--remove])"
fi

# --- idempotency ------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
    say "\"${IDENTITY_NAME}\" already exists and is valid for code signing — nothing to do."
    security find-identity -v -p codesigning | grep "\"${IDENTITY_NAME}\"" | sed 's/^/    /'
    say ""
    say "Rebuild with: scripts/make-app.sh"
    exit 0
fi
if [ -n "$(identity_hashes)" ]; then
    # Present but not trusted (e.g. the trust step was cancelled last time).
    say "\"${IDENTITY_NAME}\" exists in the keychain but is not trusted for code signing."
    say "Fix: run '$0 --remove' and then '$0' again."
    exit 1
fi

[ -n "${OPENSSL}" ] || die "openssl not found (expected /usr/bin/openssl on macOS)"
[ -f "${KEYCHAIN}" ] || die "login keychain not found at ${KEYCHAIN}"

# --- temp workspace (private, always cleaned up) ----------------------------
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nodonuts-devcert.XXXXXX")"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT INT TERM

# Random one-time passphrase for the transient .p12 (empty passwords are flaky
# with `security import`). Never printed, never persisted.
# (Not `tr </dev/urandom | head`: under `set -o pipefail` tr's SIGPIPE (141) kills the script.)
P12_PASS="$(/usr/bin/openssl rand -hex 16)"

cat >"${WORK}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = ${IDENTITY_NAME}
O  = No Donuts (local development)

[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

say "==> generating self-signed code-signing certificate \"${IDENTITY_NAME}\" (${VALID_DAYS} days)"
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -sha256 \
    -days "${VALID_DAYS}" \
    -config "${WORK}/cert.cnf" \
    -keyout "${WORK}/key.pem" \
    -out "${WORK}/cert.pem" >/dev/null 2>&1 \
    || die "openssl failed to generate the certificate"

"${OPENSSL}" pkcs12 -export \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -name "${IDENTITY_NAME}" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:${P12_PASS}" \
    -out "${WORK}/identity.p12" >/dev/null 2>&1 \
    || die "openssl failed to build the PKCS#12 bundle"

# Key material on disk is no longer needed; remove it before touching the keychain.
rm -f "${WORK}/key.pem"

say "==> importing into your login keychain (codesign pre-authorized to use the key)"
security import "${WORK}/identity.p12" \
    -k "${KEYCHAIN}" \
    -f pkcs12 \
    -P "${P12_PASS}" \
    -T /usr/bin/codesign >/dev/null \
    || die "security import failed (is the login keychain unlocked?)"

say "==> trusting \"${IDENTITY_NAME}\" for code signing (user trust settings)"
say "    macOS will now ask for your login password (or Touch ID) — this is expected."
if ! security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"; then
    say ""
    say "warning: trust step was cancelled or failed. The key is imported but not trusted,"
    say "         so codesign won't list it as valid. Run '$0 --remove' then '$0' again."
    exit 1
fi

# --- verify -----------------------------------------------------------------
say ""
if security find-identity -v -p codesigning | grep -q "\"${IDENTITY_NAME}\""; then
    say "Done. Code-signing identity available:"
    security find-identity -v -p codesigning | grep "\"${IDENTITY_NAME}\"" | sed 's/^/    /'
    say ""
    say "Next:"
    say "  scripts/make-app.sh      # now signs with \"${IDENTITY_NAME}\" instead of ad-hoc"
    say ""
    say "Expect ONE final round of prompts on the first launch after switching identity:"
    say "  - Keychain: \"NoDonuts wants to use your confidential information\" -> Always Allow"
    say "  - Camera (TCC): allow again"
    say "After that, rebuilds keep the same designated requirement and should not re-prompt."
else
    die "identity imported but not reported as valid by 'security find-identity -v -p codesigning'"
fi
