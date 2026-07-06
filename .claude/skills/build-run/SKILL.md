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

## Core ML face model (ND-021 / ADR-0014)

- If `Resources/Models/FaceNetVGGFace2.mlpackage` is present, `make-app.sh` compiles it to `FaceNetVGGFace2.mlmodelc` (via `xcrun coremlcompiler compile`) into `Contents/Resources/`, so the app uses the FaceNet **face-identity** embedder at launch (`CoreMLFaceEmbedder`). Otherwise it warns and continues — the app falls back to `VisionFeaturePrintEmbedder`. Check the launch log (`log stream --predicate 'subsystem == "com.nodonuts.app"'`) for the `active face embedder = …` line.
- **`coremlcompiler` ships with full Xcode, NOT Command Line Tools.** On a CLT-only machine the model can't be compiled/bundled and the app runs on the Vision fallback. Bundling the FaceNet model into a build therefore needs full Xcode installed (a wrinkle vs the CLT-only ADR-0008 path).
- The 45MB model blob is **git-ignored**. Reproduce it with `Resources/Models/convert_facenet.py` — see `Resources/Models/README.md`.

## Camera permission

First run triggers the macOS camera prompt (uses `NSCameraUsageDescription`). To reset during testing:
```bash
tccutil reset Camera <bundle-id>
```

## Install to start at login (LaunchAgent)

One script builds the app, installs it to `/Applications/NoDonuts.app`, and loads
the LaunchAgent so No Donuts starts at login (`RunAtLoad`):
```bash
scripts/install-launchagent.sh     # make-app.sh + copy to /Applications + load agent
scripts/uninstall-launchagent.sh   # unload + remove the agent (leaves the app + data, ND-052)
```
Both are idempotent (no sudo). The plist (`scripts/com.nodonuts.agent.plist`) uses
`KeepAlive` with `SuccessfulExit=false`, so launchd relaunches the app on a
crash/kill (it's a security enforcer) but honors the menu **Quit** (clean exit 0),
which stays quit until the next login/reload.
First launch prompts for Camera (and Location, if you use trusted Wi-Fi).

## Verifying a change works

Prefer the `/run` and `/verify` skills. For this app specifically, sanity checks:
- Menu-bar status icon appears and reflects PRESENT/ABSENT.
- Cover the camera / leave frame → locks after the grace period.
- Start a video call (camera busy) → stays unlocked (ADR-0003).
- Screen already locked/asleep → no errors, loop suspended.
