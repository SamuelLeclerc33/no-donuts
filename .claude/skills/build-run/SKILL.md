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
`scripts/make-app.sh` is the **canonical local build path** (ADR-0008): it runs `swift build`, assembles `build/NoDonuts.app`, and signs it (with the stable "No Donuts Dev" identity if present, else **ad-hoc** `codesign --sign -`) with the camera entitlement so the TCC prompt fires. No Xcode, no `.xcodeproj`.

## App bundle, signing, entitlements

- `Resources/Info.plist` must include `NSCameraUsageDescription` and `LSUIElement = true` (plus `CFBundleExecutable = NoDonuts`).
- `Resources/NoDonuts.entitlements` carries the camera entitlement; `make-app.sh` embeds it at sign time.
- Ad-hoc signing (`--sign -`) works for local runs, but see **Stable dev signing** below to stop re-prompts. **Distribution** needs Developer-ID signing + notarization (ND-050) — ad-hoc bundles aren't Gatekeeper-distributable and TCC grants don't transfer to other machines.

## Stable dev signing (stops Keychain / camera re-prompts)

An ad-hoc signature's designated requirement is its **cdhash**, which changes on every rebuild, so macOS re-asks "NoDonuts wants to use your confidential information" (login-keychain ACL) and re-requests Camera (TCC) after each build. Fix, once per machine (no Apple account, no network):
```bash
scripts/make-dev-cert.sh           # self-signed "No Donuts Dev" code-signing cert -> login keychain
scripts/make-app.sh                # now prints: codesign with stable dev identity "No Donuts Dev" (...)
codesign -d -r- build/NoDonuts.app # DR is now certificate-based, not cdhash
```
- The script is idempotent (no-op if the identity already exists). It asks for your **login password / Touch ID** once, to trust the cert for code signing in your user trust settings. Key material is only kept in the keychain; temp files are deleted.
- `make-app.sh` auto-detects the identity (`security find-identity -v -p codesigning`) and falls back to ad-hoc with a hint if it's missing. Same entitlements/flags either way; **no hardened runtime** (that's ND-050).
- **One last round of prompts** on the first launch after switching identity: Keychain → **Always Allow**; Camera → allow again. After that, rebuilds keep matching.
- Remove it: `scripts/make-dev-cert.sh --remove` (may ask for your password to drop the trust setting).
- Local dev only. It is not a Developer ID and does not make the bundle Gatekeeper-distributable.

## Core ML face model (ND-021 / ADR-0014)

- `make-app.sh` bundles the FaceNet **face-identity** model into `Contents/Resources/` so the app uses `CoreMLFaceEmbedder` at launch. Precedence: (a) a **pre-compiled** `Resources/Models/FaceNetVGGFace2.mlmodelc` → `cp -R` (the normal, **Xcode-free** path); (b) else a `FaceNetVGGFace2.mlpackage` + full-Xcode `xcrun coremlcompiler` → compile on the fly; (c) else warn and continue — the app falls back to `VisionFeaturePrintEmbedder`. Check the launch log (`log stream --predicate 'subsystem == "com.nodonuts.app"'`) for the `active face embedder = …` line.
- **No full Xcode needed to bundle the model:** compile the `.mlpackage` to `.mlmodelc` with **coremltools** (`compile_model(...)`, pure Python) and drop it in `Resources/Models/` — see `Resources/Models/README.md`. Full Xcode's `coremlcompiler` is only the fallback (path b). This resolves the earlier "needs full Xcode" wrinkle and keeps model bundling on the CLT-only ADR-0008 path.
- The model blobs (`.mlpackage`, `.mlmodelc`) are **git-ignored**. Reproduce with `Resources/Models/convert_facenet.py` + the coremltools compile step — see `Resources/Models/README.md`.

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
