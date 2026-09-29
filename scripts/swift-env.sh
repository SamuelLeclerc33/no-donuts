#!/usr/bin/env bash
# No Donuts — pick a macOS SDK the active Swift toolchain can actually build with (ND-120).
#
# Why: Command Line Tools 27.0 made MacOSX27.0.sdk the default. In that SDK, SwiftUI's
# @State (and friends) are macros whose implementation lives in the SwiftUIMacros
# compiler plugin, which CLT does NOT ship (full Xcode does). `swift build` then fails:
#   "plugin for module 'SwiftUIMacros' not found".
# Building against the newest installed MacOSX26*.sdk works, and keeps ADR-0008
# (CLT-only local builds) intact.
#
# Rules:
#   - SDKROOT already set          -> respected, nothing changes.
#   - toolchain has SwiftUIMacros  -> no-op (full Xcode, CI's macos-latest).
#   - plugin missing AND default SDK major >= 27
#                                  -> export SDKROOT=<newest MacOSX26*.sdk>, one warning.
#   - no suitable fallback SDK     -> warning, SDKROOT left unset (the build then fails
#                                     with the real compiler error).
#
# Usage:
#   . scripts/swift-env.sh                    # source it (bash or zsh); exports SDKROOT
#   scripts/swift-env.sh swift build          # or wrap a command
#   scripts/swift-env.sh swift run EngineCheck
#
# Safe to source from a `set -euo pipefail` script: it never exits the caller, never
# changes shell options, and cleans up its helper function.

_nd_swift_env() {
    if [ -n "${SDKROOT:-}" ]; then
        return 0
    fi

    # Locate the active toolchain (honors DEVELOPER_DIR / xcode-select).
    local swift_bin toolchain_usr dev_dir
    swift_bin="$(xcrun --find swift 2>/dev/null)" || swift_bin=""
    if [ -z "${swift_bin}" ]; then
        return 0   # no toolchain at all; let the caller hit the real error
    fi
    toolchain_usr="$(cd "$(dirname "${swift_bin}")/.." 2>/dev/null && pwd -P)" || toolchain_usr=""
    dev_dir="$(xcode-select -p 2>/dev/null)" || dev_dir=""

    # Does the toolchain ship the SwiftUIMacros plugin? (Full Xcode: yes. CLT 27.0: no.)
    local d f
    for d in \
        "${toolchain_usr}/lib/swift/host/plugins" \
        "${toolchain_usr}/local/lib/swift/host/plugins" \
        "${dev_dir}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
        "${dev_dir}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"; do
        [ -d "${d}" ] || continue
        f="$(find "${d}" -maxdepth 2 -iname '*SwiftUIMacros*' -print 2>/dev/null | head -n 1)" || f=""
        if [ -n "${f}" ]; then
            return 0
        fi
    done

    # Plugin missing. Only intervene when the default SDK is 27+ (where @State is a macro).
    local sdk_version sdk_major sdk_path sdk_dir
    sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || sdk_version=""
    sdk_major="${sdk_version%%.*}"
    case "${sdk_major}" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "${sdk_major}" -lt 27 ]; then
        return 0
    fi
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || sdk_path=""
    sdk_dir="$(dirname "${sdk_path}")"

    # Newest MacOSX26*.sdk, numeric sort (26.5 beats 26; symlinks resolve to the same dir).
    local best
    best="$(find "${sdk_dir}" -maxdepth 1 -name 'MacOSX26*.sdk' -print 2>/dev/null \
        | sed -E 's|.*/MacOSX([0-9.]*)\.sdk$|\1 &|' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -n 1 | cut -d' ' -f2-)" || best=""

    if [ -n "${best}" ] && [ -d "${best}" ]; then
        best="$(cd "${best}" && pwd -P)"
        export SDKROOT="${best}"
        echo "warning: ND-120: toolchain lacks the SwiftUIMacros plugin and the default SDK is macOS ${sdk_version}; building against $(basename "${best}") (SDKROOT=${best}). Set SDKROOT to override." >&2
    else
        echo "warning: ND-120: toolchain lacks the SwiftUIMacros plugin and the default SDK is macOS ${sdk_version}, but no MacOSX26*.sdk was found in ${sdk_dir}. SwiftUI @State will fail to compile; install full Xcode or an older Command Line Tools SDK, or set SDKROOT." >&2
    fi
    return 0
}

_nd_swift_env
unset -f _nd_swift_env

# Sourced vs executed: when executed with arguments, run them in this environment.
_nd_sourced=0
if [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
    case "${ZSH_EVAL_CONTEXT}" in *:file*) _nd_sourced=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
    # shellcheck disable=SC2128  # BASH_SOURCE without index is BASH_SOURCE[0]
    if [ "${BASH_SOURCE}" != "$0" ]; then _nd_sourced=1; fi
fi

if [ "${_nd_sourced}" = 1 ]; then
    unset _nd_sourced
else
    unset _nd_sourced
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
fi
