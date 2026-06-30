# Product Requirements — No Donuts

## Problem

People walk away from unlocked Macs. In an office that means "donut" pranks at best and a real security/compliance exposure at worst (open email, source code, customer data). Manual locking (⌃⌘Q / hot corners) depends on remembering. Time-based auto-lock is either too aggressive (locks while you're reading) or too slow (locks long after you've left).

## Solution

Continuously and locally verify that the enrolled user is physically present via the camera. Lock promptly when they leave; never get in the way while they're there — including during video calls.

## Target users

- **Primary:** professionals on managed/unmanaged Macs who handle sensitive data and attend frequent video calls.
- **Secondary:** privacy-conscious individuals who want presence-based locking without cloud face recognition.

## Goals

1. Lock within a short, configurable grace period after the user leaves.
2. Never lock while the enrolled user is present and looking at / near the screen.
3. Never interrupt an active video call.
4. 100% on-device recognition — no images or embeddings leave the Mac.
5. Negligible CPU/battery impact (duty-cycled checks, Neural Engine for ML).
6. Trivial to enroll, pause, and uninstall.

## Non-goals (for v1)

- Multi-user / fast-user-switching presence (single enrolled identity first).
- Mobile, Windows, or Linux.
- Cloud sync of settings or enrollment data.
- Liveness/anti-spoofing hardened to a determined attacker (basic measures only — see [SECURITY_PRIVACY](SECURITY_PRIVACY.md)).
- Unlocking the Mac via face (we only **lock**; unlock stays with macOS/Touch ID/password).

## Functional requirements

- **FR1 Enrollment.** User captures several reference frames; app stores face embeddings locally (encrypted at rest). Re-enroll and reset supported.
- **FR2 Presence loop.** Every N seconds (default ~3–5s, configurable), capture a frame and classify state: PRESENT / ABSENT / UNKNOWN.
- **FR3 Identity match.** A detected face must match the enrolled embedding above a threshold to count as PRESENT. A stranger ≠ present.
- **FR4 Grace period.** Lock only after the user has been continuously ABSENT for a configurable grace period (default e.g. 20–30s) to absorb brief turn-aways.
- **FR5 Lock.** When the grace period elapses, lock the screen using a supported macOS mechanism.
- **FR6 Call awareness.** If another app is using the camera, attempt multi-client capture; if frames are unavailable, treat the user as present and do not lock. (See [ADR-0003](adr/0003-camera-in-use-policy.md).)
- **FR7 Already-locked / asleep.** Do nothing when the screen is already locked, the display is asleep, or the session is inactive.
- **FR8 Menu-bar control.** Status indicator, pause (timed + indefinite), enroll/re-enroll, settings, quit.
- **FR9 Auto-start.** Optional LaunchAgent that starts the app at login.
- **FR10 Permissions.** Graceful handling of camera permission states (not-yet-asked, denied, restricted).

## Success metrics

- False-lock rate (locks while user present) below an acceptable threshold during a workday.
- Median time-to-lock after leaving within the configured grace period ± small margin.
- Zero locks triggered during an active video call in testing.
- Steady-state CPU well under a defined budget; no measurable battery complaint.

## Open product questions

Tracked in [EDGE_CASES.md](EDGE_CASES.md) and the backlog. Examples: behavior with external monitors/closed lid, multiple faces in frame, glasses/hats/lighting, "someone else sat down" (stranger present, user absent), enterprise deployment/MDM.
