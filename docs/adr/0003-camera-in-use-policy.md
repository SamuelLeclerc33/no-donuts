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

A future refinement may add a max-duration guard for "busy but no frames" to avoid an indefinitely-open session if a call app is left running unattended (tracked as an edge case).

## Consequences

- Calls are never interrupted — the primary professional requirement.
- Best-effort accuracy: when multi-client frames are available we still verify identity during calls.
- Introduces a deliberate fail-open path (busy + no frames → present). Documented and bounded; revisit with a max-duration guard (EC-01, ND-033).
- Requires validating macOS multi-client camera capture feasibility (ND-032, owner: blart).

## Alternatives considered

- **Always assume present when busy (no frame attempt):** simpler, but gives up identity verification during calls entirely.
- **Pause checks when busy:** equivalent risk to assume-present without the chance to verify; rejected in favor of attempting shared frames first.
- **Lock anyway if no match during a call:** unacceptable — interrupts meetings, defeats the professional goal.
