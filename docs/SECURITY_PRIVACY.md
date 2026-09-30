# Security & Privacy — No Donuts

Privacy is a hard product requirement, not a feature. The whole point of local recognition is that **your face never leaves your Mac.**

## No-recording guarantee

**No Donuts does not record, save, or share any video or images — ever.** While the app is running it samples individual camera frames only to answer one question on-device — "is a face in front of the screen right now?" — and each frame is discarded from memory immediately after that check. No frame is written to disk, kept in a buffer beyond the moment of analysis, uploaded, or sent over any network. There is no recording feature, no screenshot, no cloud, and no telemetry of image data. The macOS camera indicator light stays on the entire time the app is monitoring, so camera use is always visible and honest.

## Privacy principles

1. **On-device only.** Detection, embedding, and matching run locally (Vision + Core ML). There are **no network code paths** in the recognition or presence flow.
2. **No raw images persisted.** Camera frames live in memory for the duration of a tick and are discarded. We persist embeddings, not photos, wherever possible.
3. **Encrypted at rest.** Enrolled face **embeddings** (not images) are stored in the macOS **Keychain** (generic-password item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, never iCloud-synced), so they are encrypted at rest and access-controlled ([ADR-0012](adr/0012-local-identity-featureprint.md), ND-023). Identity itself is computed on-device via Apple Vision (`VNGenerateImageFeaturePrint`) with no bundled third-party model and no network. "Reset enrollment" deletes the Keychain item. The item carries a human-readable label ("No Donuts — your face signature") so the macOS Keychain-access prompt is legible; the enrollment is read **once and cached in memory** (the per-tick recognizer never re-hits the Keychain), and a one-time in-app explainer sets expectations before the first write. On **ad-hoc-signed dev builds** macOS still shows a Keychain-access prompt (its code identity isn't stable); a Developer-ID signature (ND-050) removes it for distribution.
4. **No telemetry by default.** Any diagnostics are local-only and opt-in.
5. **Least privilege.** Only the camera entitlement we need; clear `NSCameraUsageDescription` explaining why.
6. **Visible, honest camera use.** Monitoring uses a **persistent low-FPS capture session**, so the macOS **camera indicator light stays on the whole time** No Donuts is watching — there is no hidden or intermittent recording. Captured frames live **in memory only** and are never written to disk.

## Threat model

Scope and status as of 2026-09-28 (ND-109). Each row says what an attacker can do, what stops them, and what still gets through. **Status:** `Mitigated` (closed for this threat level) · `Partial` (reduced, known gap) · `Accepted` (gap kept on purpose, bounded or visible) · `Residual` (gap with no mitigation yet) · `In progress` · `Deferred` · `Out of scope`.

Timings assume shipped defaults: 1 s tick, 5-tick absence consensus, 5 s grace.

### Assumptions

The attacker is an **opportunist with physical access** to an unlocked Mac for seconds to minutes (a colleague, a passer-by). They do **not** know the user's password, so they can't use `sudo`, unlock the screen, or approve admin prompts. While at the unlocked session they can do anything the logged-in user can without a password: use the menu, run `defaults write`, `kill`, `launchctl`, `tccutil reset Camera`, change System Settings panes that don't ask for a password. macOS login, Touch ID, TCC, launchd and local notification delivery work as documented. The built-in camera is trustworthy hardware. The fleet is one laptop model (ND-111). The user glances at the menu bar now and then, so a **visible** degraded state counts as a mitigation, but a **silent** one does not.

### Security threats

| Threat / attacker capability | Attack | Mitigation | Residual risk | Status |
|---|---|---|---|---|
| **Walk-away** (baseline): passer-by at an unattended Mac | Uses the unlocked session after the user leaves | Absence consensus + grace, then a CGSession-verified lock (ADR-0010, EC-11) | ~10 s window at defaults. The user can stretch it within bounds (tick ≤ 10 s, grace ≤ 60 s, ADR-0019), up to ~110 s | Mitigated |
| **Stranger at keyboard** | Sits down after the user leaves | A non-matching face counts as absence (EC-03). 3 stranger ticks lock with no grace (ADR-0017, ND-061) | ~3 s of access. Before enrollment any face counts as present | Mitigated (once enrolled) |
| **Look-alike** colleague | Their face is close enough to match | FaceNet identity embedding (ADR-0014), per-model threshold (ND-076), face quality gate (ND-085) | Threshold is **untuned**: false-accept rate never measured (ND-056). A look-alike may pass | Partial |
| **Photo / screen spoof** at the lens | Holds a print or phone showing the user | Texture liveness floor on both embedder paths (ND-041, ND-072, EC-12). Spoof → stranger → fast lock | Sharp print or high-DPI screen may pass; no blink/motion check; spoof scores unmeasured. **v1 is not hardened** | Partial |
| **Virtual camera replay** | Installs OBS or a CMIO extension and loops a video of the user | Built-in camera only: built-in device type **and** built-in transport (ADR-0015, ND-075) | Forces a physical spoof at the real lens (row above) | Mitigated |
| **Camera unplug / wedge / revoke** | `tccutil reset Camera` (no admin), wedges or unplugs the device | Stale-frame guard (ND-055, ND-084). Lid open: 120 s unavailable → absence → lock (ADR-0016, ND-078). Not-protecting notification | ~2 min + consensus + grace unlocked. Lid closed: no lock (see clamshell row) | Mitigated (lid open) |
| **Camera busy / call abuse** | Opens Photo Booth so our session gets no frames | Busy counts as present only for 10 min; only a frame of the enrolled user resets the window (ND-098, ADR-0016, EC-01) | Up to ~10 min + consensus + grace unlocked | Accepted (bounded) |
| **Lid closed / desktop Mac** | Uses a clamshell setup or a desktop, where there's no built-in camera | Honest "camera unavailable" state + notification (EC-07, ADR-0015/0016). An unreadable lid state counts as open | **Unprotected** the whole time the lid is closed; desktops are never protected | Accepted gap |
| **Kill / crash / quit** | `kill`, force-quit, crash, menu Quit | KeepAlive agent relaunches (ADR-0018). Dead-man `nd.notRunning` notification ~10 min after death. Quit needs confirmation and gets a +30 min reminder (ND-082). Single instance (ND-083) | Short gap before relaunch (10 s throttle). A confirmed Quit is allowed by design | Mitigated |
| **Pause abuse** | Pauses protection from the menu | Pause is visible (camera light off, paused glyph) and in-memory only. Indefinite pause ends on lock/sleep, with a 30-min reminder (ND-080, EC-15) | Anyone at the unlocked Mac can pause. A timed pause (≤ 1 h) survives a lock by design | Accepted (visible) |
| **Trusted Wi-Fi spoof** | Evil-twin AP broadcasting a trusted SSID | Trust = SSID **+** gateway MAC, fresh read for each decision; unreadable = untrusted (ND-081, ND-036, EC-20) | An attacker who clones the SSID **and** answers ARP with the router's MAC. `defaults write` can add an entry, but the trusted-Wi-Fi state shows | Partial |
| **`defaults write` tampering** | Weakens threshold, anti-spoof, grace, tick | All tunables validated; out-of-range values rejected (ADR-0019, ND-062, ND-076). Weaker security tunables show "Protection reduced" in the menu (ND-077) | Grace/tick changes within bounds aren't flagged (they show in Settings). The user has to notice the banner | Mitigated (visible) |
| **Model file removal / swap** | Deletes or replaces the `.mlmodelc` in the ad-hoc bundle | Missing or mismatched model version → loud "identity off" (ND-073). SHA-256 + output-dim check at build (ND-087) | A post-build swap that keeps the version tag isn't caught at runtime; the ad-hoc signature doesn't seal the bundle (Developer-ID, ND-050) | In progress |
| **Keychain item deletion** | Deletes the enrollment item | Non-secret marker → loud "identity off: re-enroll" at next launch; the running app keeps its cached vectors (ND-073) | Deleting the marker too makes it look like "never enrolled" (presence-only), which shows as not enrolled | Mitigated (visible) |
| **Private lock API breakage** | A macOS update removes or changes the `login.framework` symbols | Self-test at launch and wake → persistent "can't lock" + notification (ND-058, ND-074). Each lock logs its mechanism | Both mechanisms are in one private framework, with no independent fallback | Accepted (loud) |
| **Lock failure** | The lock call runs but the screen doesn't lock | CGSession-verified `lock()`. On failure: `.lockFailed`, retries with backoff 10 → 60 s, notification with sound (ND-054, ND-079, EC-19) | Stays unlocked until a retry succeeds | Mitigated |
| **Launcher removal** | Removes the login item / `launchctl bootout`, then kills the app | Dead-man notification still fires after the kill (ADR-0018); ND-112: a +5 min "didn't start after login" alert is scheduled at logout/shutdown when Start at login is off, and cleared by the next launch (an agent booted out while still enabled remains a gap) | No relaunch. Logout cancels the dead-man, so after logout or a reboot the app is silently absent until the user notices the missing menu icon | Partial (ND-112, delivery across logout unverified) |
| **Notification permission denied** | User or attacker turns off notifications for No Donuts | Menu glyph and header still show state; diagnostics report the missing permission (ADR-0018); ND-113: persistent menu warning + "Open Notification Settings…" | Dead-man, lock-failed and not-protecting alerts can't fire. After a kill, nothing tells the user | Partial (ND-113) |
| **Local admin / root** | Knows the password or has root | None | Can disable anything | Out of scope |

### Privacy threats

| Threat / attacker capability | Attack | Mitigation | Residual risk | Status |
|---|---|---|---|---|
| **Frames / embeddings exfiltrated** | Network leak, telemetry, disk dump | No network code paths; frames stay in memory for one tick; only embeddings are stored, in the Keychain; no telemetry (principles above) | Malware running as the user can read memory or the Keychain item | Mitigated |
| **Logs leak personal data** | Reads `os_log` / diagnostics | Logs hold numeric scores, lock-mechanism and camera-device names only. No image, embedding, SSID or MAC; diagnostics show counts (ND-024, ND-081) | Scores are readable by anyone who can read the user's logs | Mitigated |
| **Drift monitor retains scores** | Reads drift history to profile the user | ND-119 keeps match-score margins and stranger-lock times in memory only (≤5 min / 15 min, capped); nothing persisted or sent. The notification copy is static (no scores); logs carry the mean margin and counts only | Same as logs: memory readable by malware running as the user | Mitigated |
| **Keychain at rest** | Enrollment copied off the device via backup or migration | Generic-password item requesting `…ThisDeviceOnly`; input validated before write (ND-093) | The legacy login keychain **ignores** `ThisDeviceOnly`, so the item can migrate. The fix is the data-protection keychain, with ND-050/ND-065 | Partial |
| **Colleagues' biometric data** | Deploying a face-watching app to colleagues | Only the enrolled user's embeddings are stored. Other faces are processed in memory as "stranger" and dropped. FaceScore photo folders are git-ignored (ND-105) | Privacy notice and explicit consent before enrollment built (ND-123: gate in `startEnrollment()`, launch re-ask for enrollments without consent, withdraw in Settings › About; contact line is a placeholder the company fills in). Still the company's: privacy-officer check and Québec Law 25 / CAI biometric declaration (ND-111, ADR-0024 (d)) | Partial |

### Out of scope

v1 does not defend against: a **local admin or root** user, or anyone who knows the password. **Malware already running as the user** (it can do everything the walk-up attacker can, and more). A **determined, prepared spoofer**: high-quality masks, a high-DPI replay held at the real lens, or anyone who can tune an attack against the threshold. **Shoulder-surfing** while the user is present (EC-06). **Fast user switching** and multi-account setups (EC-14). **Network attackers** beyond the trusted-Wi-Fi check. **Replacing macOS authentication**: we only lock, and unlocking stays with macOS. Against these, No Donuts is a convenience lock, not a security boundary.

## Explicit non-goals (v1)

See also *Out of scope* in the threat model above.


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
- **Notifications are local only** (ND-045). No Donuts requests UserNotifications authorization (at first launch) solely to post a **local** "not protecting — camera unavailable" alert; these are `UNUserNotificationCenter` local notifications with **no push service, no server, no network**, and no entitlement. The notification text is static and contains no personal data.
- **Trusted Wi-Fi entries store the SSID and the router's MAC address locally (UserDefaults, never transmitted); diagnostics show counts only (ND-081).** **Tuning knobs are local `UserDefaults`** (no network): `matchThreshold.<model version>` (identity strictness; per-model, values outside the model's safe range are rejected, so a low value can't make any face match — ND-076) and `visionOrientation` (camera orientation) can be set with `defaults write` for on-device tuning. The identity **match score is logged locally** (`os_log`) as a bare number to help tuning — never an image or embedding.

## Open items

- Confirm storage mechanism + key management for embeddings (cooper).
- Anti-spoofing: v1 scope is the texture floor only (see the threat model). Still open: a spoof-only measurement to tune the floor, and whether motion/blink liveness is realistic on-device (wiggum/cooper).
- Document enterprise/MDM permission pre-grant story (gordon).
