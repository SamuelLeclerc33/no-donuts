# No Donuts 🍩🚫

> **Don't get donut'd.** Leave your Mac unattended and someone "donuts" you — fires off a cheeky message to the team, or you owe the office a box of donuts. **No Donuts** makes sure that never happens: it watches the camera, and the moment *you* are no longer in front of it, the Mac locks itself.

No Donuts is a macOS menu-bar app that periodically verifies — **fully on-device** — that the enrolled user is present in front of the camera. Present → the Mac stays unlocked. Gone → it locks. It is built to be professional-friendly: when you are on a video call, it stays out of the way instead of locking you out mid-meeting.

!!! warning "Status: scaffolding"
    This repo currently contains documentation, decisions, a backlog, and code stubs. Nothing is shippable yet. See the [Backlog](BACKLOG.md) for what's planned and what's next.

## Core principles

- **Local-only face recognition.** All detection and matching runs on-device via Apple's Vision framework + a Core ML embedding model. No images leave the machine. No API calls, no per-frame token cost.
- **Professional-friendly.** A video call should never get interrupted by an unexpected lock. See [ADR-0003](adr/0003-camera-in-use-policy.md).
- **Fail safe, not fail open — but configurable.** When uncertain, the default leans toward locking (security), with explicit grace periods and overrides to avoid annoyance.
- **User in control.** Menu-bar status, pause, enroll/re-enroll, and tunable sensitivity.

## How it works (target design)

```
every N seconds:
  ├─ is the screen already locked / asleep?      → do nothing
  ├─ is another app using the camera (a call)?   → try shared frames; if none, assume PRESENT
  ├─ grab a frame → Vision face detection
  │     ├─ no face        → ABSENT  (start grace timer)
  │     └─ face found     → Core ML embedding → cosine match vs enrolled
  │           ├─ match    → PRESENT (reset timers)
  │           └─ stranger → ABSENT  (start grace timer)
  └─ if ABSENT longer than grace period          → LOCK
```

Full design in [Architecture](ARCHITECTURE.md).

## Decisions made so far

| Decision | Choice | ADR |
|---|---|---|
| Form factor | Menu-bar app + LaunchAgent (auto-start at login) | [ADR-0001](adr/0001-form-factor.md) |
| Face engine | Apple Vision + Core ML embeddings (all local) | [ADR-0002](adr/0002-face-recognition-engine.md) |
| Camera-in-use | Try shared frames; fall back to "assume present" | [ADR-0003](adr/0003-camera-in-use-policy.md) |
| App identity | Bundle id, name, minimum macOS 15 | [ADR-0004](adr/0004-app-identity.md) |
| Docs site | MkDocs + Material, fully offline, committed `site/` | [ADR-0005](adr/0005-docs-site.md) |

## Documentation map

- [Product Requirements](PRD.md) — what we're building and why
- [Architecture](ARCHITECTURE.md) — components, data flow, state machine
- [Security & Privacy](SECURITY_PRIVACY.md) — threat model, data handling, anti-spoofing
- [Backlog](BACKLOG.md) — the living backlog (we track work here)
- [Edge Cases](EDGE_CASES.md) — running list of edge cases to validate together
- [Decisions (ADRs)](adr/README.md) — architecture decision records

It's an office thing. Don't get donut'd. 🍩
