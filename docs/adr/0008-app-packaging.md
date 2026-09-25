# ADR-0008 — Local app packaging: SPM build + bundling script (ad-hoc signed)

- Status: Accepted
- Date: 2026-06-30
- Owner: gordon

## Context

A bare SPM executable (`swift run NoDonuts`) cannot present the macOS camera permission prompt or honor `LSUIElement` — those need a real `.app` bundle with an `Info.plist` and a code signature carrying the camera entitlement. The conventional way to produce that is an Xcode `.app` target, but the baseline toolchain here is **Command Line Tools only** (no full Xcode — ADR-0001), so `xcodebuild` against an app target isn't available. We still need a runnable bundle locally to test camera permission, the menu-bar (no-Dock) behavior, and the presence/lock loop (ND-018 gates all P0 testing).

## Decision

Produce the local `.app` from the SPM build plus a small bundling script — `scripts/make-app.sh` — with **ad-hoc codesign**, no Xcode and no `.xcodeproj`:

- `swift build` produces the `NoDonuts` executable (product of the package).
- The script assembles `build/NoDonuts.app/Contents/{MacOS,Resources}`, copying the binary to `Contents/MacOS/NoDonuts` and `Resources/Info.plist` to `Contents/Info.plist`.
- `codesign --force --sign - --entitlements Resources/NoDonuts.entitlements` ad-hoc-signs the bundle so the camera entitlement is present and the TCC prompt fires.

This script is the **canonical local build path** for a runnable bundle.

## Consequences

- Runs locally with **Command Line Tools only** — no full Xcode required to get a permission-prompting, menu-bar-correct app for development.
- Ad-hoc signing is fine for local dev, but **does not** satisfy distribution: Developer-ID signing + notarization remain required to ship (ND-050). Ad-hoc-signed bundles are not Gatekeeper-distributable and TCC grants don't transfer to other machines.
- `Info.plist` gained the keys a real bundle needs (`CFBundleExecutable`, `CFBundlePackageType`, `CFBundleInfoDictionaryVersion`) alongside the existing identity/permission keys.
- The build-run skill, README, and CLAUDE.md now point at `scripts/make-app.sh` instead of implying full Xcode is mandatory for a local run.

## Alternatives considered

- **Xcode `.xcodeproj` app target** — the conventional packaging route, but requires full Xcode (unavailable in the CLT-only baseline) and adds a project file to keep in sync with `Package.swift`. Rejected for local dev; revisit only if a distribution pipeline (ND-050) makes an Xcode target worthwhile.
- **Bare `swift run NoDonuts`** — no bundle, so no camera prompt and no `LSUIElement` behavior. Insufficient for the testing ND-018 needs to unblock.

## Amendment (2026-09-25): optional stable dev signing identity (ND-102)

Ad-hoc signing gives every build a new cdhash, so the login-keychain ACL and the TCC camera grant no longer match, and each rebuild re-prompts ("NoDonuts wants to use your confidential information"). `scripts/make-dev-cert.sh` creates a local self-signed code-signing certificate, "No Donuts Dev" (user trust, code signing only), without an Apple account. When that identity exists, `make-app.sh` signs with it by SHA-1, giving a certificate-based designated requirement that stays stable across rebuilds. Otherwise it falls back to ad-hoc. The build still needs only CLT; hardened runtime and Developer ID stay with ND-050.
