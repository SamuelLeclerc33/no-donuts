---
name: build-run
description: Build, sign, install, and run the No Donuts macOS menu-bar app, including camera permission and the LaunchAgent. Use when asked to build, run, launch, or install the app, or to set it to start at login.
---

# Build & run — No Donuts

## Prerequisite (important)

A signed menu-bar `.app` with camera entitlements needs **full Xcode**, not just Command Line Tools.

Check what's installed:
```bash
xcode-select -p        # CommandLineTools = NOT enough; want .../Xcode.app/...
xcodebuild -version    # should print Xcode version
```
If only Command Line Tools are present, install Xcode and run `sudo xcode-select -s /Applications/Xcode.app`.

## Build (SPM, for fast iteration on logic)

```bash
swift build            # builds the executable target
swift run NoDonuts     # runs it (camera prompt requires a proper app bundle, see below)
```
SPM is fine for compiling/logic, but the camera permission prompt and `LSUIElement` behavior need a real `.app` bundle (`Info.plist`). For the full app, build the Xcode app target / packaging scripts under `scripts/` (owner: gordon).

## App bundle, signing, entitlements

- `Resources/Info.plist` must include `NSCameraUsageDescription` and `LSUIElement = true`.
- `Resources/NoDonuts.entitlements` carries the camera entitlement.
- Codesign with a Developer ID for distribution; ad-hoc sign for local runs.

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
