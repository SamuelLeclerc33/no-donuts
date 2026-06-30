---
name: build-run
description: Build, sign, install, and run the No Donuts macOS menu-bar app, including camera permission and the LaunchAgent. Use when asked to build, run, launch, or install the app, or to set it to start at login.
---

# Build & run — No Donuts

## Prerequisite (important)

A runnable local `.app` needs only **Command Line Tools** + `codesign` — full Xcode is **not** required for local dev (ADR-0008). Full Xcode / a Developer ID + notarization is only needed for *distribution* (ND-050).

Check what's installed:
```bash
xcode-select -p        # CommandLineTools is enough for a local ad-hoc-signed app
swift --version        # should print a Swift toolchain
```

## Build (SPM, for fast iteration on logic)

```bash
swift build            # builds the executable target
swift run NoDonuts     # runs it (camera prompt requires a proper app bundle, see below)
```
SPM is fine for compiling/logic, but the camera permission prompt and `LSUIElement` behavior need a real `.app` bundle (`Info.plist`) — see below.

## Build a runnable `.app` (local, CLT-friendly)

```bash
scripts/make-app.sh            # release; --debug for a faster compile
open build/NoDonuts.app        # launch it
```
`scripts/make-app.sh` is the **canonical local build path** (ADR-0008): it runs `swift build`, assembles `build/NoDonuts.app`, and **ad-hoc-signs** it (`codesign --sign -`) with the camera entitlement so the TCC prompt fires. No Xcode, no `.xcodeproj`.

## App bundle, signing, entitlements

- `Resources/Info.plist` must include `NSCameraUsageDescription` and `LSUIElement = true` (plus `CFBundleExecutable = NoDonuts`).
- `Resources/NoDonuts.entitlements` carries the camera entitlement; `make-app.sh` embeds it at sign time.
- Ad-hoc signing (`--sign -`) is fine for local runs. **Distribution** needs Developer-ID signing + notarization (ND-050) — ad-hoc bundles aren't Gatekeeper-distributable and TCC grants don't transfer to other machines.

## Camera permission

First run triggers the macOS camera prompt (uses `NSCameraUsageDescription`). To reset during testing:
```bash
tccutil reset Camera <bundle-id>
```

## LaunchAgent (auto-start at login)

Install the plist (template/script under `scripts/`, owner: gordon):
```bash
cp scripts/com.nodonuts.agent.plist ~/Library/LaunchAgents/
launchctl load   ~/Library/LaunchAgents/com.nodonuts.agent.plist   # start + RunAtLoad
launchctl unload ~/Library/LaunchAgents/com.nodonuts.agent.plist   # stop
```

## Verifying a change works

Prefer the `/run` and `/verify` skills. For this app specifically, sanity checks:
- Menu-bar status icon appears and reflects PRESENT/ABSENT.
- Cover the camera / leave frame → locks after the grace period.
- Start a video call (camera busy) → stays unlocked (ADR-0003).
- Screen already locked/asleep → no errors, loop suspended.
