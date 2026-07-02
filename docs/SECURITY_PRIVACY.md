# Security & Privacy — No Donuts

Privacy is a hard product requirement, not a feature. The whole point of local recognition is that **your face never leaves your Mac.**

## No-recording guarantee

**No Donuts does not record, save, or share any video or images — ever.** While the app is running it samples individual camera frames only to answer one question on-device — "is a face in front of the screen right now?" — and each frame is discarded from memory immediately after that check. No frame is written to disk, kept in a buffer beyond the moment of analysis, uploaded, or sent over any network. There is no recording feature, no screenshot, no cloud, and no telemetry of image data. The macOS camera indicator light stays on the entire time the app is monitoring, so camera use is always visible and honest.

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
| Fail-open | Bug/permission issue makes it silently never lock | Explicit fail policy + visible status; uncertain states lean conservative. `lock()` is **CGSession-verified** — it returns `true` only once the session actually reports locked, else it surfaces honest `.lockFailed` (no silent fail-open, EC-19, [ADR-0010](adr/0010-screen-lock-no-accessibility.md)). |
| Stranger present | Someone else sits down while user is gone | Non-matching face never counts as PRESENT (EC-03) |
| Enforcement disabled without user intent | A bug in pause / trusted-Wi-Fi gating silently stops protecting | Gating **fails toward enforcing**: an unknown/unreadable SSID is never "trusted" (ND-036, EC-20); disabled states are shown honestly in the menu bar and turn the camera light off, so "not watching" is always visible. |

## Explicit non-goals (v1)

- Defeating a determined, prepared spoofing attacker (high-quality 3D mask, etc.).
- Replacing macOS authentication. We **lock only**; unlock remains macOS/Touch ID/password. We never authenticate the user *into* the machine via face.

## Fail-safe posture

- Default leans **secure** (lock) under sustained uncertainty, balanced against not annoying the user via grace periods and call-awareness.
- Camera permission denied/restricted: do **not** silently pretend to protect. Surface clear status; pick a documented safe default (EC-08).
- A **failed lock is detected and surfaced**, never silently treated as "locked". `lock()` is **CGSession-verified**: it returns `true` only once the session actually reports locked (`CGSSessionScreenIsLocked`, or off-console as `CGSession -suspend` presents), otherwise the engine shows honest `.lockFailed` (EC-19, [ADR-0010](adr/0010-screen-lock-no-accessibility.md), supersedes ADR-0006).
- **Enforcement is disabled only on explicit signals, and always visibly.** The app stops locking only when (a) the session is already locked/asleep, (b) the user paused it, or (c) the current Wi-Fi is on the user's trusted list. All three turn the **camera light off** and show a distinct menu-bar state. Trusted-Wi-Fi gating **fails toward enforcing**: if the SSID can't be read (e.g. Location not granted), it is treated as untrusted and protection stays on (ND-036, EC-20, [ADR-0011](adr/0011-enforcement-gating.md)).

## Permissions & entitlements

- **Camera is the primary permission.** `NSCameraUsageDescription` — honest, specific copy. Camera access entitlement; avoid anything broader than required.
- **Location (when-in-use) is optional and only for the trusted-Wi-Fi feature** (ND-036, [ADR-0011](adr/0011-enforcement-gating.md)). On modern macOS, reading the current Wi-Fi network name (SSID) via CoreWLAN requires Location authorization. No Donuts requests it **lazily** — only when you first mark a network as trusted, never at launch — with an honest `NSLocationWhenInUseUsageDescription`. It uses Location **solely to read the SSID**; it does not read, store, or transmit your coordinates. **The SSID never leaves your device** (it's only compared against your local trusted list in `UserDefaults`). If Location is denied, the trusted-Wi-Fi feature is simply unavailable (the menu item is disabled) and normal enforcement continues — declining Location never weakens protection.
- **The screen lock requires no Accessibility permission** ([ADR-0010](adr/0010-screen-lock-no-accessibility.md)): the mechanism does not use synthetic keystrokes, so there is no Accessibility permission to request, prompt for, or recover from.
- **The camera permission is requested at first launch.** On the very first run — and only while the session is active — the app shows a one-time, plain-language explainer that it uses the **Camera** to check you're at your Mac and locks the screen when you step away, all on-device with nothing recorded. It then triggers the macOS Camera prompt.
- **Pause state is in-memory only** (not persisted); the **trusted-Wi-Fi list is stored locally** in `UserDefaults` and never transmitted.

## Open items

- Confirm storage mechanism + key management for embeddings (cooper).
- Decide anti-spoofing scope and which liveness signals are realistic on-device (wiggum/cooper).
- Document enterprise/MDM permission pre-grant story (gordon).
