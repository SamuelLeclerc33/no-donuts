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

**Correction (2026-09-25):** the stable identity fixes TCC (Camera permission survives rebuilds), but **not** the Keychain prompt. The legacy login keychain partitions items by Team ID, and a self-signed certificate has none, so the partition falls back to the binary's cdhash (`user approved XARA access for 'cdhash:…'`). Every rebuild that changes the binary therefore re-prompts once. Since ND-102 the prompt no longer blocks the app. Only a Developer ID with a Team ID removes it (ND-050).

## Amendment (2026-09-29): SDK fallback on Command Line Tools 27 (ND-120)

Command Line Tools 27.0 made `MacOSX27.0.sdk` the default. In that SDK, SwiftUI's `@State` and related property wrappers are macros implemented by the `SwiftUIMacros` compiler plugin, which ships with full Xcode but not with CLT. A CLT-only `swift build` therefore fails ("plugin for module 'SwiftUIMacros' not found"). To keep this ADR's CLT-only local build, `scripts/swift-env.sh` checks the active toolchain for the plugin. If the plugin is missing and the default SDK is 27 or newer, it exports `SDKROOT` = the newest installed `MacOSX26*.sdk` and prints one warning. It leaves a preset `SDKROOT` alone and does nothing on full Xcode, including CI. `make-app.sh` sources it, and bare SwiftPM commands can be wrapped with it (`scripts/swift-env.sh swift run EngineCheck`). If no 26.x SDK is installed, it warns and the build fails with the real error. The fallback lasts only as long as CLT keeps a 26.x SDK. The lasting fixes are a CLT release that ships the plugin, or full Xcode (already required for ND-050 distribution).
