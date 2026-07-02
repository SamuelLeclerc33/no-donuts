# Backlog — No Donuts

The single source of truth for planned work. Keep it current (see the `backlog` skill).

**Status legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked
**Owner** = the responsible sub-agent (see `CLAUDE.md` at the repo root for module ownership).

---

## 🎯 MVP plan — current focus

**MVP goal:** lock the Mac when no face is at it, **never lock during a video call**, show a live menu-bar indicator (present / away / in a meeting), start at login — all on-device. **Recognition is presence-only** ("any face = present"); recognizing *you specifically* (identity) is deferred to v1.1.

**P0 — prove the core loop end-to-end (demoable lock):**
1. ND-018 — runnable `.app` w/ camera entitlement (**prerequisite**; gates all P0 testing) — gordon
2. ND-014 — reliable programmatic screen lock (**highest risk, start first**) — wiggum
3. ND-011 — camera permission + denied/restricted — blart
4. ND-012 — single-frame capture per tick — blart
5. ND-020 — Vision face detection → presence-only recognizer — cooper
6. ND-025 — wire detection recognizer into engine, drop the fake — homer
7. ND-030 — grace + consecutive-absent debounce — homer

**P1 — correct & professional-friendly (completes MVP):**
8. ND-013 — suspend loop when locked/asleep/inactive — blart
9. ~~ND-031 — camera-in-use detection ("in a meeting" signal) — blart~~ ✅
10. ~~ND-033 — assume-present when camera busy + no frames (ADR-0003), bounded — homer~~ ✅
11. ND-017 — menu-bar indicator: present / away / in a meeting / can't-see-you — krusty
12. ND-016 — LaunchAgent autostart at login — gordon

**Deferred to post-MVP:** M2 identity (ND-021/022/023/024 = v1.1, "recognize you specifically", EC-03), ND-032, ND-034, ND-035 (pause — worth doing soon for trust), M4 (ND-040–044), M5 distribution (ND-050–053; run dev-signed via Xcode for MVP, notarize later).

---

## M0 — Scaffolding ✅ (current)

- [x] ND-001 Documentation: README, PRD, Architecture, Security/Privacy — gordon
- [x] ND-002 ADRs for form factor, face engine, camera-in-use — gordon
- [x] ND-003 Backlog + Edge-cases logs in repo — gordon
- [x] ND-004 Expert sub-agents (homer, cooper, blart, wiggum, krusty, gordon) — gordon
- [x] ND-005 Code skeleton: Package.swift + module stubs + Info.plist — gordon
- [x] ND-006 Decide bundle id, app name, and minimum macOS version — gordon
- [x] ND-007 Make Documentation into a website (MkDocs + Material, committed `site/`, pre-commit regen). - gordon

## M1 — Walking skeleton (it builds & runs, no recognition yet)

- [x] ND-010 Buildable menu-bar app (`LSUIElement`), status item, quit — krusty
- [x] ND-011 Camera permission request + state handling (denied/restricted) — blart (camera layer: `capture()` resolves auth, returns `.unavailable` on notDetermined-denied/denied/restricted/no-device; honest engine display tracked as a homer follow-up below)
- [x] ND-012 Single-frame capture each tick from AVFoundation — blart (persistent low-FPS `AVCaptureSession`, samples one `CVPixelBuffer` per tick; frames in-memory only)
- [x] ND-013 Display/lock/session state detection (suspend loop when locked/asleep) — blart/homer (event-driven `SessionStateMonitor` in App target pauses loop + stops camera while locked/asleep/not-on-console, resumes on unlock/wake; app calls `engine.sessionSuspended()` on suspend to reset absence for false-lock-free resume (the in-tick `.suspended` path is a backstop); ADR-0009, EC-02/EC-13)
- [x] ND-014 Verify a reliable programmatic **screen lock** under entitlements — wiggum
- [x] ND-015 Presence loop scaffold with fake "always present" recognizer — homer
- [x] ND-016 LaunchAgent plist + install script (RunAtLoad) — gordon (fixed plist path + `KeepAlive` dict `SuccessfulExit=false` = crash-recovery that honors a clean Quit; `scripts/install-launchagent.sh` installs to `/Applications` + bootstraps, `scripts/uninstall-launchagent.sh` undoes; ADR-0001)
- [x] ND-017 Menu-bar presence indicator (present / away / in a meeting / can't-see-you) — krusty/homer (per-state SF Symbol glyph + tint; `.absent` shown from the FIRST no-face tick (responsive); render cached to skip no-op redraws. Timing sped up for office-donut threat: tick 4→1s, consensus 3→5, grace 25→5 → walk-away→lock ≈ 10s. Fixed: a failed `lockNow()`'s "can't lock" warning was being clobbered to "away" by the next tick.)
- [x] ND-018 Runnable `.app` bundle with camera entitlement — `scripts/make-app.sh` (SPM build + bundle + ad-hoc codesign; CLT-only, no Xcode), ADR-0008 — gordon
- [ ] ND-019 Fix duplicate ADR number: `0005-docs-site.md` and `0005-presence-loop-concurrency.md` both numbered 0005 — renumber docs-site → 0007 and update CLAUDE.md + index references — gordon

> **Review follow-ups (from the ND-010/015 code review, deferred to their owning items):**
> - **ND-011** (blart): on `.unavailable` the engine returns without updating state, so the menu shows stale "present" — fix honest-status display + EC-08/09 fail policy. Also: the loop's first tick fires immediately at launch → real camera permission prompt would pop on every login; consider delaying the first real capture.
> - **ND-014** (wiggum): `PresenceEngine` is now `@MainActor`, so a synchronous `ScreenLocker.lock()` would block the UI at lock time — run the real lock off the main actor (ADR-0005).
> - **ND-025** (homer): remove/`#if DEBUG`-fence `AlwaysPresent*` fakes so they can't ship in a release binary and silently defeat locking.
> - **ND-042** (blart/homer): loop period = work + `Task.sleep` (drifts longer than `tickIntervalSeconds`); and `loopTask` cancellation interrupts only the sleep, not an in-flight `capture()`/`recognize()` — make the real async calls cancellation-aware.

> **Lock follow-ups:**
> - ✅ **Verified lock state** — resolved: lock is CGSession-verified (ADR-0010).
> - ✅ **Non-blocking lock** — resolved: `lock()` is async; verify poll uses `Task.sleep` + shared ~3s deadline (ND-048; osascript/`waitUntilExit` mechanism replaced by SAC/CGSession, ADR-0010).
> - ✅ **No-Accessibility mechanism** — resolved: SACLockScreenImmediate → CGSession -suspend (ADR-0010, supersedes 0006); Accessibility no longer needed.
> - **Lock-failed retry/backoff** (homer): after `.lockFailed` the engine attempts once per absence episode and then stops; add a coarse retry-with-backoff.
> - **Log subsystem constant** (gordon/wiggum): extract the hardcoded `"com.nodonuts.app"` Logger subsystem to a shared constant tied to the bundle id (ADR-0004) so it can't drift at ND-050 rename.
> - **Dedupe CGSession lock-detection** (wiggum/homer): `ScreenLocker.isScreenLockedNow()` and `SessionStateMonitor.currentlyActive()` both read `CGSessionCopyCurrentDictionary()` (locked/on-console) — extract one AppKit-free NoDonutsCore helper so they can't drift.
> - **First-run explainer non-blocking** (krusty): `NSAlert.runModal()` briefly starves the main-actor loop; make the one-time explainer non-blocking (only bites first-run before camera permission, so low impact).

> **Camera follow-ups (from the ND-018/011/012 code review — MUST resolve fail-opens BEFORE ND-025 wires the real recognizer; currently masked by the always-present fake):**
> - **✅ Fail-open policy (resolved at ND-020/025):** `.unavailable` → `.cameraUnavailable`, don't lock + honest status (EC-07/08/09 DECIDED; notification → ND-045). Sustained recognition `.error` now escalates to absence after `maxConsecutiveErrorsBeforeAbsent` (EC-10, no indefinite hold). Persistent no-frame routing through the busy-camera path remains for ND-031.
> - **Retained pixel buffer** (blart): the delegate pins one `CVPixelBuffer` from the pool between ticks; deep-copy on read (or stop session between ticks) so it can't stall delivery — do when the frame is actually consumed (ND-020) / ND-042.
> - **First-tick latency** (blart): `waitForFirstFrame` can add ~1.5s to the first tick after permission; pre-warm at launch / shorten — ND-042.
> - **Duty-cycle** (blart/homer): even at ~1fps the persistent session runs continuously; consider stop-between-ticks for real power savings — ND-042.

## M2 — Local face recognition (identity) — ✅ v1.1 (feature-print embedder; Core ML swap optional)

- [x] ND-020 Vision face detection in the capture path — cooper (presence-only `FaceDetectionRecognizer`; any face = present)
- [~] ND-021 Upgrade embedder to a Core ML face model (optional accuracy improvement) — cooper. **Reframed:** identity ships in v1.1 using Apple `VNGenerateImageFeaturePrint` behind the `FaceEmbedding` protocol ([ADR-0012](adr/0012-local-identity-featureprint.md)); this item is now the OPTIONAL drop-in of a FaceNet/ArcFace-class Core ML model for better accuracy (needs sourcing/licensing/bundling — blocked on a model file).
- [x] ND-022 Enrollment flow: capture reference frames → embeddings — cooper + krusty (`EnrollmentCoordinator`: menu "Enroll my face…" → ~10 frames over ~2–3s via `CameraController`, embed, store; enforcement gated off during capture; "Reset enrollment")
- [x] ND-023 Encrypted-at-rest embedding store (Keychain) — cooper (`EnrollmentStore`: Keychain generic-password, device-only, embeddings-only; `InMemoryEnrollmentStore` for tests)
- [x] ND-024 Cosine matching + threshold — cooper (`cosineSimilarity` + `IdentityRecognizer`; `.enrolledUserPresent(confidence:)` now the real max score; lenient default, **needs on-device tuning**)
- [x] ND-025 Wire recognizer into presence engine (replace fake) — homer (presence-only; fakes deleted) — see ND-034 (M3) for the strict stranger policy that identity enables

> **Identity follow-ups (from M2 / ND-021–024):**
> - **On-device threshold tuning** (cooper): observability + no-rebuild override now shipped — `IdentityRecognizer` logs the per-tick cosine score (`log stream`), and `matchThreshold` is overridable via `defaults write com.nodonuts.app matchThreshold <0–1>`. STILL TODO: pick a data-driven default from real captures (false-accept vs false-reject) and expose a slider in settings (ND-040).
> - ✅ **Camera orientation** — resolved: the Vision source orientation is `.up` by default but overridable via `defaults write com.nodonuts.app visionOrientation <1–8>`, applied consistently to detection + crop (cooper); the capture connection is forced non-mirrored for deterministic embeddings (blart). Remaining nicety: auto-derive orientation per device instead of the manual override.
> - **Multi-face (EC-06)** (cooper): the embedder matches only the LARGEST face; if a colleague's face is larger than the enrolled user's, the user could be missed → false lock. Scan all detected faces and match against any.
> - **Two recognizer classes** (cooper): `FaceDetectionRecognizer` (presence-only) and `IdentityRecognizer` (identity, with its own presence-only fallback) overlap on detection — the standalone `FaceDetectionRecognizer` is now unused in the app; consider removing or merging.

> **Suspend follow-ups (from the ND-013 code review):**
> - **resume()-before-configured** (blart): on first unlock after a launch-while-locked start the session isn't configured yet, so `resume()` is a no-op and the camera comes up only on the next `capture()`'s `ensureConfigured()` (brief `cameraUnavailable` flash). Minor; tie to ND-042 pre-warm.
> - **`.suspended` enum overload** (homer): `PresenceState.suspended` means both "we auto-locked" (attemptLock) and "OS session suspended" (ND-013). They converge to the same "locked" status today (no current bug), but consider splitting for clearer status/logic when polishing the indicator (ND-017).

## M3 — Presence policy & professional-friendliness ✅

- [x] ND-030 Grace period + consecutive-absent debounce — homer (implemented: `Config.graceSeconds=5` + `consecutiveAbsentTicksToLock=5` + `PresenceEngine.markAbsent` (consensus → grace); walk-away→lock ≈ 10s. EngineCheck-covered: past-grace→locks, within-grace→no-lock, full-consensus-pre-grace→no-lock. EC-04/EC-11)
- [x] ND-031 Camera-in-use detection (another app holds the device) — blart
- [x] ND-032 Attempt multi-client shared frames during a call — blart — **Resolved: not needed on macOS.** macOS shares the camera across clients, so a busy device still delivers frames to our session → normal detection handles the on-a-call case; the rare busy-**no**-frames case is already covered by busy→assume-present, bounded (ADR-0003/ND-033). No explicit shared-frame acquisition code added (would be speculative + untestable headless). **Caveat:** closed on design rationale, not a live multi-app on-device test — reopen if real-world use shows a busy call delivering no frames on some hardware. Folds into ND-031/EC-01.
- [x] ND-033 Fallback "assume present" when busy + no frames (ADR-0003), bounded by `maxCallAssumedPresentSeconds` (default 30 min) → escalates to absence so an unattended call app can't stay unlocked forever — homer
- [x] ND-034 Stranger-present-but-user-absent policy (EC-03) — cooper/homer (once enrolled, a non-matching face → `.strangerOnly` → absence → lock after grace; presence-only until enrolled). [ADR-0012](adr/0012-local-identity-featureprint.md)
- [x] ND-035 Pause (timed + indefinite) + manual lock-now — krusty + homer (Pause 15 min / 1 hr / until-resume; pausing stops the loop + turns the camera off; manual "Lock now" already existed. Enforced purely by the App gate — no engine pause latch, so it can't get stuck "paused" and silently stop locking. [ADR-0011](adr/0011-enforcement-gating.md), EC-15)
- [x] ND-036 Wi-Fi SSID exclusion list: pause enforcement on trusted networks (e.g. home) — krusty + homer (checkable "Trust this Wi-Fi network" menu item for the current SSID; list in UserDefaults; reading SSID uses CoreWLAN + Location (when-in-use), requested lazily on first trust. Fail-safe: unknown/unreadable SSID → never trusted → enforcement stays ON. [ADR-0011](adr/0011-enforcement-gating.md), EC-20). Follow-up: full trusted-list settings UI stays with ND-040.

> **Enforcement-gating follow-ups (from the ND-016/035/036 code review — non-blocking cleanups):**
> - **Single trust-check path** (krusty): the trust toggle now uses `TrustedNetworksStore.isTrusted`/`add`/`remove`; keep all "is this network trusted?" checks going through the store (don't re-introduce a raw `contains`).
> - **Consolidate disable methods** (homer): `sessionSuspended()` / `pause()` / `disabledOnTrustedNetwork()` are near-identical (`state = X; resetAbsenceAccounting()`); consider one `func disable(displayState:)` when convenient.
> - **`WiFiMonitor.stop()`** (krusty): implemented for symmetry but not yet wired to app teardown — hook it up if/when the app gains an explicit shutdown path.
> - **Gate no-op short-circuit** (krusty): `applyEnforcement()` re-renders + refreshes menu on every input callback even when the decision is unchanged; skip when the computed `enabled`/reason is identical to last time (minor).

## M4 — Settings, polish, anti-spoofing

- [ ] ND-040 Settings UI: tick interval, grace, sensitivity, autostart — krusty
- [ ] ND-041 Basic anti-spoofing (e.g. reject obvious photo; liveness signals) — wiggum + cooper
- [ ] ND-042 Power/CPU profiling + duty-cycle tuning — blart + homer
- [ ] ND-043 Onboarding: first-run enrollment + permission walkthrough — krusty
- [ ] ND-044 Logging/diagnostics (local only, privacy-safe) — gordon
- [x] ND-045 "Not protecting" notification when camera unavailable (on entry + repeats ~5 min, clears on recovery) — krusty (`NotProtectingNotifier`, local UserNotifications; permission requested at first launch; no entitlement needed). EC-07/08/09 IMPLEMENTED.
- [x] ND-048 Request all required permissions at first launch (camera + Accessibility for the lock) so the Accessibility need isn't discovered only on the first failed lock — krusty

## M5 — Distribution

- [ ] ND-050 Codesign + notarization pipeline — gordon
- [ ] ND-051 Signed `.app` + DMG/installer — gordon
- [ ] ND-052 Uninstall path (remove LaunchAgent + data) — gordon
- [ ] ND-053 MDM/enterprise deployment notes — gordon

## Tooling & tests

- [x] ND-046 Testable `NoDonutsCore` split + framework-free `EngineCheck` harness (`swift run EngineCheck`) — gordon/homer ([ADR-0007](adr/0007-package-layout-testable-core.md))
- [ ] ND-047 Add an XCTest/Swift-Testing target alongside EngineCheck once full Xcode is the baseline (richer reporting/IDE) — gordon

---

## Icebox / later

- Multi-user / fast-user-switching presence.
- Multiple enrolled faces (e.g. shared workstation allowlist).
- External monitor / clamshell behavior refinement.
- Configurable actions beyond lock (blur, dim, hide windows).
