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
**Command Line Tools 27+ (ND-120):** the default macOS 27 SDK needs the `SwiftUIMacros` compiler plugin, which CLT doesn't ship, so bare `swift build` fails with "plugin for module 'SwiftUIMacros' not found". Wrap SwiftPM commands: `scripts/swift-env.sh swift build`, `scripts/swift-env.sh swift run EngineCheck`. It exports `SDKROOT` = newest installed `MacOSX26*.sdk` (warns once), respects a preset `SDKROOT`, and is a no-op on full Xcode. `scripts/make-app.sh` sources it automatically. You can also `. scripts/swift-env.sh` once per shell.

SPM is fine for compiling/logic, but the camera permission prompt and `LSUIElement` behavior need a real `.app` bundle (`Info.plist`) — see below.

## Build a runnable `.app` (local, CLT-friendly)

```bash
scripts/make-app.sh            # dev mode, optimized build; --debug for a faster compile
scripts/make-app.sh --release  # release mode: fails unless the model is present and hash-verified (ND-104)
open build/NoDonuts.app        # launch it
```
`scripts/make-app.sh` is the **canonical local build path** (ADR-0008): it runs `swift build`, assembles `build/NoDonuts.app`, and signs it (with the stable "No Donuts Dev" identity if present, else **ad-hoc** `codesign --sign -`) with the camera entitlement so the TCC prompt fires. No Xcode, no `.xcodeproj`.

## App bundle, signing, entitlements

- `Resources/Info.plist` must include `NSCameraUsageDescription` and `LSUIElement = true` (plus `CFBundleExecutable = NoDonuts`).
- **Version stamping (ND-067):** the version keys in `Resources/Info.plist` are placeholders (`0.0.0-unstamped` / `0`). `make-app.sh` stamps the **bundle's copy** via PlistBuddy before codesign: `CFBundleVersion` = `git rev-list --count HEAD`; `CFBundleShortVersionString` = `git describe --tags` minus a leading `v` (e.g. `1.1.0`, or `1.1.0-3-g<sha>` past the tag), or `0.<commit-count>-g<sha>` when no tag exists yet; `-dirty` is appended when tracked files differ from HEAD. It prints `==> stamped version …`. Check: `plutil -p build/NoDonuts.app/Contents/Info.plist | grep -i version`. Tag the release commit so a clean release build stamps a plain `X.Y.Z`.
- `Resources/NoDonuts.entitlements` carries the camera and location entitlements (location is needed for SSID reads once the hardened runtime is on, ND-088); `make-app.sh` embeds it at sign time.
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

- `make-app.sh` bundles the FaceNet **face-identity** model into `Contents/Resources/` so the app uses `CoreMLFaceEmbedder` at launch. Precedence: (a) a **pre-compiled** `Resources/Models/FaceNetVGGFace2.mlmodelc` → `cp -R` (the normal, **Xcode-free** path); (b) else a `FaceNetVGGFace2.mlpackage` + full-Xcode `xcrun coremlcompiler` → compile on the fly; (c) else warn and continue — the app falls back to `VisionFeaturePrintEmbedder`. Path (a) is first checked against the recorded SHA-256 in `Resources/Models/FaceNetVGGFace2.sha256` (`scripts/model-hash.sh`, ND-087): a mismatch warns loudly in dev mode. With `--release`, a missing model, missing hash, mismatch or `.mlpackage`-only checkout fails the build (ND-104). `CoreMLFaceEmbedder` also refuses a model whose output isn't 512-d. Check the launch log (`log stream --predicate 'subsystem == "com.nodonuts.app"'`) for the `active face embedder = …` line.
- **No full Xcode needed to bundle the model:** compile the `.mlpackage` to `.mlmodelc` with **coremltools** (`compile_model(...)`, pure Python) and drop it in `Resources/Models/` — see `Resources/Models/README.md`. Full Xcode's `coremlcompiler` is only the fallback (path b). This resolves the earlier "needs full Xcode" wrinkle and keeps model bundling on the CLT-only ADR-0008 path.
- The model blobs (`.mlpackage`, `.mlmodelc`) are **git-ignored**. Reproduce with `Resources/Models/convert_facenet.py` + the coremltools compile step — see `Resources/Models/README.md`.

## Camera permission

First run triggers the macOS camera prompt (uses `NSCameraUsageDescription`). To reset during testing:
```bash
tccutil reset Camera <bundle-id>
```

## Install and start at login (bundled LaunchAgent)

There is **one launcher** (ND-082 / ND-083): a LaunchAgent plist bundled inside the app, registered from the app with `SMAppService.agent(plistName:)`.

- Source: `Resources/LaunchAgents/com.nodonuts.app.agent.plist`. `make-app.sh` copies it to `NoDonuts.app/Contents/Library/LaunchAgents/` **before** codesign (the build fails if it's missing). Check: `codesign --verify --strict build/NoDonuts.app`.
- Label **`com.nodonuts.app.agent`**, `BundleProgram` `Contents/MacOS/NoDonuts`, `RunAtLoad`, `KeepAlive { SuccessfulExit = false }`, `ThrottleInterval` 10. A crash, kill, or non-zero exit is relaunched; menu **Quit** (exit 0) and the single-instance guard's duplicate exit (exit 0) are not.
- Turned on and off by **Settings › Start at login** (`LoginItem.swift`). If macOS parks it in `.requiresApproval`, the app opens System Settings › General › Login Items so you can approve it.
- Never copy this plist into `~/Library/LaunchAgents` by hand. `BundleProgram` only resolves through SMAppService.

```bash
scripts/install-app.sh             # make-app.sh + copy to /Applications + remove legacy agent + open
# then: menu bar → Settings → Start at login (approve in Login Items if asked)
launchctl print gui/$(id -u)/com.nodonuts.app.agent   # confirm it's loaded
scripts/uninstall.sh --keep-app     # stop + unregister start-at-login, keep app + data (alias: uninstall-launchagent.sh)
scripts/uninstall.sh                # ...and remove /Applications/NoDonuts.app (data kept)
scripts/uninstall.sh --purge        # ...and delete Keychain enrollment, defaults, TCC, caches (typed "yes")
scripts/uninstall.sh --purge --dry-run   # print the plan, change nothing
```

- **Register from the copy you'll actually run.** SMAppService records the bundle that called `register()`. Enabling it from `build/NoDonuts.app` makes login launch `build/`. Use `/Applications/NoDonuts.app`.
- The registration lives in macOS's login-items database, not in a file. `launchctl bootout` only unloads it until next login. To remove it for good, turn off the toggle, remove No Donuts in System Settings › Login Items, or run `scripts/uninstall.sh` (it calls `NoDonuts --unregister` before deleting the app). Run it as the logged-in user, never with sudo. See [docs/DEPLOYMENT.md](../../../docs/DEPLOYMENT.md#uninstall).
- After enabling, the running copy is the one you opened by hand. launchd's RunAtLoad copy exits 0 on the single-instance guard, so KeepAlive supervision starts at next login.

### Migrating from the old launchers

- **`SMAppService.mainApp` login item** (the old toggle): the app migrates it by itself. It unregisters `mainApp` and, if it was on, registers the agent in its place. You'll see `migration:` lines in the log.
- **Script-installed `~/Library/LaunchAgents/com.nodonuts.agent.plist`** (ND-016, `install-launchagent.sh`): run `scripts/migrate-launcher.sh` once. It does `launchctl bootout gui/$UID/com.nodonuts.agent` and deletes the plist. `install-app.sh` runs it too, and `uninstall.sh` does the same removal inline. `install-launchagent.sh` is deprecated and forwards to `install-app.sh`.

First launch prompts for Camera (and Location, if you use trusted Wi-Fi).

## Verifying a change works

Prefer the `/run` and `/verify` skills. For this app specifically, sanity checks:
- Menu-bar status icon appears and reflects PRESENT/ABSENT.
- Cover the camera / leave frame → locks after the grace period.
- Start a video call (camera busy) → stays unlocked (ADR-0003).
- Screen already locked/asleep → no errors, loop suspended.
