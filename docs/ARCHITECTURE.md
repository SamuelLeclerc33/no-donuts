# Architecture — No Donuts

> Status: design + stubs. This describes the target structure; modules under `Sources/` are currently skeletons.

## Overview

A single Swift menu-bar process runs a duty-cycled **presence loop**. Each tick flows through capture → detect → recognize → decide → (maybe) lock. All ML is on-device.

```
 ┌─────────────┐   frame   ┌──────────────┐  face crop  ┌───────────────┐
 │  Camera     │──────────▶│  Recognition │────────────▶│  Presence     │
 │  (blart)    │           │  (cooper)    │  match?     │  Engine       │
 │  AVFoundation│           │ Vision+CoreML│             │  (homer)      │
 └─────┬───────┘           └──────────────┘             └──────┬────────┘
       │ camera-in-use?                                        │ decision
       │ display state                                         ▼
       │                                              ┌────────────────┐
       │                                              │  Lock (wiggum) │
       │                                              └────────────────┘
                ▲ status / control                            ▲
                │                                              │
          ┌───────────────────────────────────────────────────┐
          │              Menu-bar UI / Settings (krusty)       │
          └───────────────────────────────────────────────────┘
```

## Components

### Camera (`Sources/NoDonuts/Camera/`) — owner: **blart**
- AVFoundation capture session; pulls a single frame per tick (not a continuous stream) to save power.
- **Camera-in-use monitor:** detect when another app holds the camera. Attempt multi-client capture to still get frames; if not possible, emit `cameraBusyNoFrames`.
- Display/session state: is the screen locked, is the display asleep, is the session active. (Used to short-circuit the loop.)

### Recognition (`Sources/NoDonuts/Recognition/`) — owner: **cooper**
- **Detection:** Vision (`VNDetectFaceRectanglesRequest` / landmarks) → face bounding boxes.
- **Embedding:** a Core ML model produces a fixed-length face embedding per detected face.
- **Matching:** cosine similarity vs the enrolled embedding(s); threshold → match / no-match.
- **Enrollment store:** captures reference embeddings, persists them encrypted at rest, supports re-enroll/reset. Embeddings only — we avoid storing raw face images where possible.

### Presence Engine (`Sources/NoDonuts/Presence/`) — owner: **homer**
- The **state machine** and the brain of the app. Consumes recognition results + camera/display signals, applies policy (grace periods, call-awareness, pause), decides PRESENT/ABSENT and when to request a lock.
- Owns timers, debouncing, and the configurable thresholds.

### Lock (`Sources/NoDonuts/Lock/`) — owner: **wiggum**
- Executes the screen lock via a supported macOS mechanism.
- Enforces fail-safe semantics and houses basic anti-spoofing hooks. Never unlocks (out of scope).

### App / UI (`Sources/NoDonuts/App/`) — owner: **krusty**
- `NSStatusItem` menu-bar entry: live status, pause menu, enroll, settings, quit.
- Settings (AppKit/SwiftUI), enrollment flow UX, permission prompts.

### Build / packaging — owner: **gordon**
- `Package.swift`, `Resources/Info.plist` (incl. `NSCameraUsageDescription`), entitlements, codesigning, LaunchAgent plist, install scripts, release.

## Presence state machine (target)

States: `UNKNOWN` (startup), `PRESENT`, `ABSENT`, `PAUSED`, `CALL_ASSUMED_PRESENT`, `SUSPENDED` (screen locked/asleep).

Per tick (simplified):

```
if paused            -> PAUSED (no action)
if screen locked/asleep/inactive -> SUSPENDED (no action)
if camera busy:
    if got shared frame -> run recognition path
    else                -> CALL_ASSUMED_PRESENT (reset absence timer, no lock)
recognition path:
    enrolled face matched   -> PRESENT (reset absence timer)
    face but stranger only  -> ABSENT (start/continue absence timer)   [see edge case: stranger-present]
    no face                 -> ABSENT (start/continue absence timer)
    error/uncertain         -> per fail policy (default: do not reset; count toward absence conservatively)
transition:
    if ABSENT continuously >= graceSeconds -> request LOCK -> SUSPENDED
```

Tunables (config): `tickIntervalSeconds`, `graceSeconds`, `matchThreshold`, `consecutiveAbsentTicksToLock`, fail policy.

## Data flow & privacy

- Frames live in memory only; not written to disk, not transmitted.
- Persisted: enrolled embedding(s) + settings, encrypted at rest (Keychain / encrypted store). No network code paths.
- See [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md).

## Directory layout (target)

```
no-donuts/
├── Package.swift
├── Resources/
│   ├── Info.plist            # NSCameraUsageDescription, LSUIElement, etc.
│   └── NoDonuts.entitlements
├── Sources/NoDonuts/
│   ├── App/                  # krusty — menu bar, settings, enrollment UI, main entry
│   ├── Camera/               # blart — capture + camera-in-use + display state
│   ├── Recognition/          # cooper — Vision + Core ML + matching + enrollment store
│   ├── Presence/             # homer — state machine, policy, timers
│   ├── Lock/                 # wiggum — screen lock + fail-safe
│   └── Support/              # config, logging, shared types
├── scripts/                  # gordon — build/sign/install LaunchAgent
└── docs/
```

## Key risks / unknowns

- macOS API for **programmatic screen lock** that works reliably under sandbox/entitlements (wiggum to validate).
- **Multi-client camera capture** feasibility while another app holds the device (blart to validate — informs ADR-0003 fallback path).
- Choice and bundling of the **Core ML face-embedding model**, and on-device accuracy/threshold tuning (cooper).
