# Security & Privacy — No Donuts

Privacy is a hard product requirement, not a feature. The whole point of local recognition is that **your face never leaves your Mac.**

## Privacy principles

1. **On-device only.** Detection, embedding, and matching run locally (Vision + Core ML). There are **no network code paths** in the recognition or presence flow.
2. **No raw images persisted.** Camera frames live in memory for the duration of a tick and are discarded. We persist embeddings, not photos, wherever possible.
3. **Encrypted at rest.** Enrolled embeddings + settings are stored encrypted (Keychain or an encrypted local store). Reset/uninstall fully removes them.
4. **No telemetry by default.** Any diagnostics are local-only and opt-in.
5. **Least privilege.** Only the camera entitlement we need; clear `NSCameraUsageDescription` explaining why.
6. **Visible, honest camera use.** Monitoring uses a **persistent low-FPS capture session**, so the macOS **camera indicator light stays on the whole time** No Donuts is watching — there is no hidden or intermittent recording. Captured frames live **in memory only** and are never written to disk.

## Threat model

| Asset | Threat | Mitigation |
|---|---|---|
| Unattended unlocked session | User walks away; opportunistic snooping / "donuting" | Core function: detect absence → lock within grace period |
| Enrolled face data | Exfiltration of biometric data | Local-only, encrypted at rest, embeddings (not images), no network |
| Spoofing presence | Photo/phone held to camera to keep it unlocked | Basic anti-spoofing (M4): reject obvious flat/static photo, liveness signals. **v1 not hardened against determined attackers.** |
| Fail-open | Bug/permission issue makes it silently never lock | Explicit fail policy + visible status; uncertain states lean conservative. **Caveat (MVP):** lock confirmation is best-effort — `lock()` confirms keystroke dispatch, not a verified lock, so a remapped/disabled Ctrl-Cmd-Q shortcut can fail open undetectably (EC-19, ND-014). |
| Stranger present | Someone else sits down while user is gone | Non-matching face never counts as PRESENT (EC-03) |

## Explicit non-goals (v1)

- Defeating a determined, prepared spoofing attacker (high-quality 3D mask, etc.).
- Replacing macOS authentication. We **lock only**; unlock remains macOS/Touch ID/password. We never authenticate the user *into* the machine via face.

## Fail-safe posture

- Default leans **secure** (lock) under sustained uncertainty, balanced against not annoying the user via grace periods and call-awareness.
- Camera permission denied/restricted: do **not** silently pretend to protect. Surface clear status; pick a documented safe default (EC-08).
- A **detectably failed lock** (e.g. Accessibility outright denied, so `osascript` errors / exits non-zero) is **detected** via the `lock() -> Bool` return value and **surfaced** to the user — it is never silently treated as "locked" (EC-19, [ADR-0006](adr/0006-screen-lock-mechanism.md)).
- **Lock confirmation is currently best-effort, not verified.** A `true` from `lock()` means the Ctrl-Cmd-Q keystroke was **dispatched** (`osascript` exited 0), **not** that the screen is confirmed locked. If the Lock-Screen shortcut is **remapped/disabled**, the lock can fail open without detection. This is an accepted MVP limitation; **verified lock-state detection** (CGSession `CGSSessionScreenIsLocked`) plus an async/non-blocking `lock()` is a **planned hardening** (ND-014, [ADR-0006](adr/0006-screen-lock-mechanism.md)).

## Permissions & entitlements

- `NSCameraUsageDescription` — honest, specific copy.
- Camera access entitlement; avoid anything broader than required.
- Programmatic screen-lock mechanism validated against sandbox/entitlement constraints (ND-014, owner: wiggum).
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) — required by the screen-lock mechanism, which sends a synthetic **Ctrl-Cmd-Q** (Lock Screen) keystroke via System Events ([ADR-0006](adr/0006-screen-lock-mechanism.md)). This is a permission **distinct from** the camera grant; if denied, the lock keystroke is dropped (EC-19).

## Open items

- Confirm storage mechanism + key management for embeddings (cooper).
- Decide anti-spoofing scope and which liveness signals are realistic on-device (wiggum/cooper).
- Document enterprise/MDM permission pre-grant story (gordon).
