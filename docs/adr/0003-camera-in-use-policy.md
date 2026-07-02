# ADR-0003 — Camera-in-use: try shared frames, fall back to assume-present

- Status: Accepted
- Date: 2026-06-30
- Owner: blart / homer

## Context

A core professional requirement: **never lock the user out during a video call.** During calls another app (Zoom/Teams/Meet/etc.) is actively using the camera. We need a policy for what to do when the camera is busy.

## Decision

When another app is using the camera:
1. **Attempt multi-client capture** to obtain frames alongside the call app, and run normal recognition if we get them.
2. If frames are **not available** while the camera is busy, **assume the user is present** and do **not** lock (a camera-in-use almost always means the user is in front of it).

The fail-open is **bounded by a max-duration guard** (ND-033, implemented): after `maxCallAssumedPresentSeconds` of CONTINUOUS busy-no-frames (default 30 min, tunable via `Config`), the engine stops assuming present and escalates to absence, so a call app left running unattended can't keep the Mac unlocked indefinitely. Any non-busy outcome resets the window.

## Consequences

- Calls are never interrupted — the primary professional requirement.
- Best-effort accuracy: when multi-client frames are available we still verify identity during calls.
- Introduces a deliberate fail-open path (busy + no frames → present). Documented and bounded: the max-duration guard is now implemented (default 30 min, tunable via `Config.maxCallAssumedPresentSeconds`), so the fail-open can no longer hold the Mac unlocked forever (EC-01, ND-033).
- **ND-032 (explicit multi-client shared-frame acquisition) closed as not-needed on macOS.** In practice macOS already shares the camera across clients, so decision step 1 ("attempt multi-client capture") happens implicitly: our persistent `AVCaptureSession` normally keeps receiving frames even while a call app holds the device → normal recognition runs during calls. No explicit shared-stream code is required; adding it would be speculative and can't be exercised headless. The only path that needs the fallback is busy-**no**-frames, which the bounded assume-present policy (step 2) already covers. **Caveat:** this is a design-rationale close, not a live multi-app on-device test — reopen ND-032 if real-world use shows a busy call delivering no frames to a second session on some hardware.

## Alternatives considered

- **Always assume present when busy (no frame attempt):** simpler, but gives up identity verification during calls entirely.
- **Pause checks when busy:** equivalent risk to assume-present without the chance to verify; rejected in favor of attempting shared frames first.
- **Lock anyway if no match during a call:** unacceptable — interrupts meetings, defeats the professional goal.
