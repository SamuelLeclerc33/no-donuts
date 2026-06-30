# Security & Privacy — No Donuts

Privacy is a hard product requirement, not a feature. The whole point of local recognition is that **your face never leaves your Mac.**

## Privacy principles

1. **On-device only.** Detection, embedding, and matching run locally (Vision + Core ML). There are **no network code paths** in the recognition or presence flow.
2. **No raw images persisted.** Camera frames live in memory for the duration of a tick and are discarded. We persist embeddings, not photos, wherever possible.
3. **Encrypted at rest.** Enrolled embeddings + settings are stored encrypted (Keychain or an encrypted local store). Reset/uninstall fully removes them.
4. **No telemetry by default.** Any diagnostics are local-only and opt-in.
5. **Least privilege.** Only the camera entitlement we need; clear `NSCameraUsageDescription` explaining why.

## Threat model

| Asset | Threat | Mitigation |
|---|---|---|
| Unattended unlocked session | User walks away; opportunistic snooping / "donuting" | Core function: detect absence → lock within grace period |
| Enrolled face data | Exfiltration of biometric data | Local-only, encrypted at rest, embeddings (not images), no network |
| Spoofing presence | Photo/phone held to camera to keep it unlocked | Basic anti-spoofing (M4): reject obvious flat/static photo, liveness signals. **v1 not hardened against determined attackers.** |
| Fail-open | Bug/permission issue makes it silently never lock | Explicit fail policy + visible status; uncertain states lean conservative |
| Stranger present | Someone else sits down while user is gone | Non-matching face never counts as PRESENT (EC-03) |

## Explicit non-goals (v1)

- Defeating a determined, prepared spoofing attacker (high-quality 3D mask, etc.).
- Replacing macOS authentication. We **lock only**; unlock remains macOS/Touch ID/password. We never authenticate the user *into* the machine via face.

## Fail-safe posture

- Default leans **secure** (lock) under sustained uncertainty, balanced against not annoying the user via grace periods and call-awareness.
- Camera permission denied/restricted: do **not** silently pretend to protect. Surface clear status; pick a documented safe default (EC-08).

## Permissions & entitlements

- `NSCameraUsageDescription` — honest, specific copy.
- Camera access entitlement; avoid anything broader than required.
- Programmatic screen-lock mechanism validated against sandbox/entitlement constraints (ND-014, owner: wiggum).

## Open items

- Confirm storage mechanism + key management for embeddings (cooper).
- Decide anti-spoofing scope and which liveness signals are realistic on-device (wiggum/cooper).
- Document enterprise/MDM permission pre-grant story (gordon).
