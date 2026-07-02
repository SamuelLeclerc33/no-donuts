# Backlog — No Donuts

The single source of truth for planned work. Keep it current (see the `backlog` skill).

**Status legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked
**Owner** = the responsible sub-agent (see `CLAUDE.md` at the repo root for module ownership).

---

## 🎯 v1.2 plan — hardening & trust (current focus)

*MVP + v1.1 identity are shipped and were **code-verified in the 2026-07-02 full-backlog review** (all six domain owners audited their done items: build green, `EngineCheck` 47/47, no functional regressions). The plan below is what that review surfaced — see [M6](#m6--v12-hardening-from-the-2026-07-02-full-review) for full item descriptions.*

**Goal:** eliminate the remaining silent fail-opens, put identity on a measured footing, and never let the UI claim protection it isn't delivering.

**P0 — fail-safe integrity (the app must never silently not-protect):**
1. ND-054 — lock-failed alarm + retry w/ backoff (the biggest real fail-open left) — wiggum + homer + krusty
2. ND-055 — stale-frame guard (dead frame source currently serves the last good frame forever → never locks) — blart
3. ND-056 — threshold tuning study → data-driven `matchThreshold` default (identity currently hangs on an untuned 0.6 guess) — cooper
4. ND-057 — menu honesty: `autoenablesItems = false` + `menuWillOpen` refresh — krusty
5. ND-058 — launch-time lock self-test — wiggum

**P1 — correctness & policy:**
6. ND-059 — multi-face matching (EC-06; after ND-056) — cooper
7. ND-060 — EC-10 error-escalation cadence decision — homer
8. ND-061 — stranger-at-keyboard urgency (needs ADR) — homer + cooper
9. ND-062 — validated runtime tunables (substrate for ND-040) — homer
10. ND-063 — enrollment quality: distinct frames + consistency gate — blart + cooper
11. ND-064 — shared CGSession reader (drift is already live) — wiggum
12. ND-065 — identity constants + Keychain migration plan (gates ND-050) — gordon

**P2 — features & polish (existing M4 items, now unblocked and re-scoped):**
ND-040 settings UI (after ND-062/056) · ND-043 onboarding + denied-camera recovery · ND-041 anti-spoofing v1 · ND-042 loop timing/power (absorbs several camera follow-ups) · ND-044 diagnostics (after ND-065) · ND-066 on-device multi-client validation (discharges the ND-032 caveat).

**Hygiene batch (cheap, batchable):** ND-019 (ADR renumber — target is now **0013**, not 0007) · ND-067 stale-docs sweep · ND-068 delete dead `FaceDetectionRecognizer` · ND-069 `throttleOnBattery` implement-or-delete · ND-070 de-modalize alerts.

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
- [x] ND-013 Display/lock/session state detection (suspend loop when locked/asleep) — blart/homer (event-driven `SessionStateMonitor` in App target pauses loop + stops camera while locked/asleep/not-on-console, resumes on unlock/wake; app calls `engine.sessionSuspended()` on suspend to reset absence for false-lock-free resume (in-tick backstop: a tick racing a suspend falls through to `.unavailable` — the live camera never emits `CaptureOutcome.suspended`, see ND-067); ADR-0009, EC-02/EC-13)
- [x] ND-014 Verify a reliable programmatic **screen lock** under entitlements — wiggum
- [x] ND-015 Presence loop scaffold with fake "always present" recognizer — homer
- [x] ND-016 LaunchAgent plist + install script (RunAtLoad) — gordon (fixed plist path + `KeepAlive` dict `SuccessfulExit=false` = crash-recovery that honors a clean Quit; `scripts/install-launchagent.sh` installs to `/Applications` + bootstraps, `scripts/uninstall-launchagent.sh` undoes; ADR-0001)
- [x] ND-017 Menu-bar presence indicator (present / away / in a meeting / can't-see-you) — krusty/homer (per-state SF Symbol glyph + tint; `.absent` shown from the FIRST no-face tick (responsive); render cached to skip no-op redraws. Timing sped up for office-donut threat: tick 4→1s, consensus 3→5, grace 25→5 → walk-away→lock ≈ 10s. Fixed: a failed `lockNow()`'s "can't lock" warning was being clobbered to "away" by the next tick.)
- [x] ND-018 Runnable `.app` bundle with camera entitlement — `scripts/make-app.sh` (SPM build + bundle + ad-hoc codesign; CLT-only, no Xcode), ADR-0008 — gordon
- [ ] ND-019 Fix duplicate ADR number: `0005-docs-site.md` and `0005-presence-loop-concurrency.md` both numbered 0005 — renumber docs-site → **0013** (0007–0012 are all taken now; the old "→ 0007" plan is stale) and update the file's title line, `docs/adr/README.md`, `mkdocs.yml` nav, CLAUDE.md, `.githooks/pre-commit`, the `.gitignore` comment; rebuild `site/` — gordon

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

- [ ] ND-040 Settings UI: tick interval, grace, sensitivity, autostart — krusty (re-scoped 2026-07-02: this is now the accumulation point for three IOUs — the `matchThreshold` sensitivity slider (endpoints from ND-056), the trusted-networks list management promised at ND-036, and the validated tunables from ND-062. Do after ND-062/ND-056.)
- [ ] ND-041 Basic anti-spoofing (e.g. reject obvious photo; liveness signals) — wiggum + cooper (v1 scope from review: temporal liveness — a printed photo yields near-identical embeddings tick after tick, which is itself a signal; suspiciously-static face → treat as absent. Document what it does NOT stop (video replay, masks) in SECURITY_PRIVACY. EC-12)
- [ ] ND-042 Loop timing + power — blart + homer (re-scoped 2026-07-02, absorbs the camera follow-ups: fixed-cadence tick (deadline-based, not work+`sleep` — drift silently lengthens the ~10s walk-away math), cancellation-aware `capture()`, session pre-warm at launch (kills the ~1.5s first tick AND the resume-before-configured no-op), deep-copy the retained pixel buffer, duty-cycle measurement (EC-18; stop-between-ticks vs the deliberate camera-light-on honesty stance → ADR note if changed))
- [ ] ND-043 Onboarding: first-run enrollment + permission walkthrough — krusty (re-scoped 2026-07-02: also denied-camera *recovery* — an "Open System Settings → Privacy → Camera" action on the cameraUnavailable menu state and the ND-045 notification; enrollment nudge after first grant, since users currently stay presence-only silently)
- [ ] ND-044 Logging/diagnostics (local only, privacy-safe) — gordon (after ND-065: `scripts/diagnose.sh` or menu item wrapping `log show --predicate 'subsystem == <shared constant>'`; privacy note — scores are logged, frames never)
- [x] ND-045 "Not protecting" notification when camera unavailable (on entry + repeats ~5 min, clears on recovery) — krusty (`NotProtectingNotifier`, local UserNotifications; permission requested at first launch; no entitlement needed). EC-07/08/09 IMPLEMENTED.
- [x] ND-048 Request all required permissions at first launch (camera + **notifications**; the SAC/CGSession lock needs no Accessibility, ADR-0010 — original "Accessibility" wording corrected in the 2026-07-02 review; Location stays lazy by design, ND-036) — krusty (stale "grant Accessibility" code comments → ND-067)

## M5 — Distribution

- [ ] ND-050 Codesign + notarization pipeline — gordon (needs a decision ADR first: signing account (personal/Chrono — **not** the Serko account), final bundle id, hardened-runtime entitlement audit, `notarytool` flow. **Blocked on ND-065** — renaming the bundle id without the Keychain-service migration plan silently orphans enrollments)
- [ ] ND-051 Signed `.app` + DMG/installer — gordon
- [ ] ND-052 Uninstall path (remove LaunchAgent + data) — gordon (scope from review: `uninstall.sh --purge` = agent + `/Applications` app + Keychain enrollment item + `defaults delete com.nodonuts.app` + `tccutil reset Camera` — a trust/privacy story this app markets on)
- [ ] ND-053 MDM/enterprise deployment notes — gordon

## M6 — v1.2 Hardening (from the 2026-07-02 full review)

*Each done item in M0–M3 was re-verified against the code by its owning agent. All claims held (no functional regressions; `EngineCheck` 47/47). These are the gaps and promotions the review produced. Several existing follow-up bullets above are absorbed by these items — the item text says which.*

**P0 — fail-safe integrity:**

- [ ] ND-054 Lock-failed alarm + retry — on `.lockFailed`: notify via `NotProtectingNotifier` (on entry + repeat, clear on recovery), audible alert, and retry `locker.lock()` on coarse backoff (~30s, capped) while the absence episode persists. Today `lockAttempted` is set once per episode with no retry, and the only surfacing is a red menu glyph shown to an empty chair — the single biggest real fail-open (flagged independently by homer, wiggum, AND krusty). Absorbs the "Lock-failed retry/backoff" follow-up. A retry pass also absorbs the shared-3s-deadline nuance (slow CGSession `-suspend` locking *after* `lock()` returned false → transient false `.lockFailed`). EC-19. — wiggum + homer + krusty
- [ ] ND-055 Stale-frame fail-open guard — the delegate's cached `CVPixelBuffer` has no timestamp, and nothing observes `AVCaptureSessionRuntimeError` / `AVCaptureSessionWasInterrupted` / device-disconnect: if frame delivery dies while `running == true` (external cam unplugged, wedged virtual cam — the same DAL hardware class as EC-21), `capture()` serves the last good frame **forever** and the Mac never locks. Fix: timestamp the cached buffer, reject frames older than ~2× tick (routes into the existing honest busy/unavailable paths), observe runtime-error/disconnect to reset `configured`. — blart
- [ ] ND-056 Threshold tuning study — structured on-device captures (enrolled user across lighting/glasses/angles/distance vs 2–3 other faces), harvest scores from the existing per-tick logging, pick a data-driven `matchThreshold` default (current 0.6 is a self-documented guess on a *general-purpose* feature print — the EC-03 stranger-rejection guarantee is weaker than the ✅ rows imply), amend ADR-0012. Unblocks the ND-040 sensitivity slider with real endpoints. Carries the ND-024 follow-up. — cooper
- [ ] ND-057 Menu honesty pass — `menu.autoenablesItems = false` + `validateMenuItem`/`menuWillOpen` refresh. NSMenu auto-enablement currently force-enables items the code disabled (enroll-during-enrollment, trust-with-unknown-SSID) — functionally guarded, but the menu visually offers actions it claims are disabled; also fixes the stale "Resume (N min left)" label (computed at the last gate pass, never on open). One small change. — krusty
- [ ] ND-058 Launch-time lock self-test — at startup verify `dlsym(SACLockScreenImmediate)` resolves and the CGSession tool exists; if not, surface "locking may not work on this macOS" immediately instead of at the first real absence. Log which mechanism confirmed each lock (canary for macOS breaking the private API that ADR-0010 accepted as a risk). — wiggum

**P1 — correctness & policy:**

- [ ] ND-059 Multi-face matching (EC-06) — embed the top-2/3 detected faces by size and report present if ANY clears the threshold; `.strangerOnly` only when none do. Today only the LARGEST face is embedded: a colleague leaning in closer than the enrolled user → stranger score → false lock of the present user. Bounded top-N because matching any-of-N multiplies false-accept surface → sequence AFTER ND-056. EngineCheck via a per-face fake embedder. — cooper
- [ ] ND-060 EC-10 escalation cadence decision — `markAbsent` resets `consecutiveErrorTicks`, so a fully wedged recognizer needs 3×5 error ticks + grace ≈ **20s** to lock vs ~10s for plain absence. Either count an escalated tick without resetting the streak, or record the 2× behavior as intended (EDGE_CASES EC-10 + config comment). One line either way + an EngineCheck assertion pinning the chosen time-to-lock. — homer
- [ ] ND-061 Stranger-at-keyboard urgency — sustained `.strangerOnly` currently gets the identical 5-tick consensus + 5s grace as an empty desk, but grace exists to absorb the enrolled user turning away, not to give a stranger 10 seconds at the keyboard. Consider a shorter consensus/grace pair (e.g. 3 ticks + 0s) for the highest-threat observable state. Policy change → needs an ADR; interacts with ND-056/ND-059 false-positive rates. — homer + cooper
- [ ] ND-062 Validated runtime tunables — `matchThreshold` has a validated defaults-override resolver; `tickIntervalSeconds`/`graceSeconds`/`consecutiveAbsentTicksToLock` have none, and unvalidated values are dangerous (0s tick = CPU spin; huge grace = fail-open). Ship Core resolvers mirroring `resolvedMatchThreshold` (clamped ranges, EngineCheck-covered) so ND-040 builds on a safe substrate. — homer
- [ ] ND-063 Enrollment quality — two halves: (a) **distinct frames** (blart): the coordinator samples every 200ms but the camera delivers ~1fps, so "10 frames" ≈ 2–3 distinct images and `minimumVectors=3` can be met by one frame embedded thrice — expose frame identity/timestamp (or raise fps during the enrollment window) and require N distinct; (b) **consistency gate** (cooper): reject vector sets (or outliers) whose pairwise cosine falls below a floor, so a photobombed/blurry capture can't silently poison the reference set — honest `notEnoughFaces`-style retry, guidance wording with krusty. — blart + cooper + krusty
- [ ] ND-064 Shared CGSession reader — one defensive AppKit-free `NoDonutsCore/Support` helper (Bool **and** NSNumber bridging; locked / on-console / display-asleep) consumed by both `ScreenLocker.isScreenLockedNow()` and `SessionStateMonitor.currentlyActive()`. The feared drift already exists: the locker bridges NSNumber defensively, the monitor uses bare `as? Bool` only. Enables EngineCheck coverage of the parsing. Absorbs the "Dedupe CGSession lock-detection" follow-up. — wiggum + homer
- [ ] ND-065 Identity constants + Keychain migration plan — extract one shared constant for the 7+ hardcoded `"com.nodonuts.app"` Logger subsystems (ADR-0004), and decide (note in ADR-0004 or mini-ADR) whether the **Keychain service string** (`EnrollmentStore`, same literal) tracks the bundle id or stays fixed at the ND-050 rename — as-is it's a silent enrollment-loss trap. Gates ND-050 and ND-044. Absorbs the "Log subsystem constant" follow-up. — gordon + wiggum + cooper
- [ ] ND-066 On-device multi-client validation — live test with FaceTime/Photo Booth/Zoom holding the camera: (a) confirm our session still receives frames (the ADR-0003/ND-032 design rationale), and (b) when it doesn't, confirm `isInUseByAnotherApplication` actually fires within the 1.5s window — else the fallback lands on `.unavailable` and an on-a-call user gets "not protecting" nags instead of "in a meeting". Also fix the busy probe to query the *configured* input device rather than re-resolving `.default`. Discharges the explicit reopen-clause caveat on ND-032. — blart

**Hygiene (cheap, batchable):**

- [ ] ND-067 Stale-docs/comments sweep — (a) Accessibility ghosts (ADR-0010 removed the need): `Types.swift` "(e.g. Accessibility not granted)", `PresenceEngine` "grant Accessibility" comment, the EngineCheck label; (b) closed-item TODOs in `CameraController` (ND-032 "still TODO", ND-013 "detect locked → .suspended", header note); (c) `Package.swift` + `Info.plist` "requires full Xcode" comments contradicting ADR-0008; (d) `main.swift` threshold doc-comment says "(0.0, 1.0]" while the resolver correctly rejects 1.0; (e) stamp `CFBundleShortVersionString`/`CFBundleVersion` from `git describe` in `make-app.sh` (bundle still says 0.0.1 while the backlog calls this v1.1). — gordon + all
- [ ] ND-068 Delete dead `FaceDetectionRecognizer` — zero references anywhere (app, EngineCheck, Package); a compiled-in presence-only recognizer whose semantics contradict the enrolled identity policy is a wiring footgun (exactly the class of code the ND-025 follow-up worried about). Migrate its useful doc comments into `FaceRecognizer.swift`. Absorbs the "Two recognizer classes" follow-up. — cooper
- [ ] ND-069 `throttleOnBattery` implement-or-delete — declared in `Config`, read by nothing (EC-18). A tunable that silently does nothing is a trust hazard in a security tool; implement with ND-042's duty-cycle work or remove until real. — homer + blart
- [ ] ND-070 De-modalize alerts — three `NSAlert.runModal()` sites starve the main-actor loop (first-run explainer, Keychain explainer, enrollment-result); the enrollment-result one now runs while enforcement is active, so this grew since first filed. Absorbs the "First-run explainer non-blocking" follow-up. — krusty

> **Still-open small follow-ups retained from above (not promoted, do opportunistically):** consolidate the three identical engine disable methods into `disable(as:)`; wire `WiFiMonitor.stop()` (+ add a `SessionStateMonitor.stop()`) to an explicit shutdown path if one appears; gate no-op short-circuit in `applyEnforcement()` (real cost is the synchronous SSID read per gate pass); make `TrustedNetworksStore.contains(_:)` non-public so the single-trust-path invariant can't regress; enrolled-but-empty-references → presence-only branch in `FaceRecognizer` is a deliberate fail-open — keep an eye on it; auto-derive Vision orientation per device instead of the manual override; `kSecUseDataProtectionKeychain` hardening once real signing exists (ND-050).

## Tooling & tests

- [x] ND-046 Testable `NoDonutsCore` split + framework-free `EngineCheck` harness (`swift run EngineCheck`) — gordon/homer ([ADR-0007](adr/0007-package-layout-testable-core.md))
- [ ] ND-047 Add an XCTest/Swift-Testing target alongside EngineCheck once full Xcode is the baseline (richer reporting/IDE) — gordon

---

## Icebox / later

- Multi-user / fast-user-switching presence.
- Multiple enrolled faces (e.g. shared workstation allowlist).
- External monitor / clamshell behavior refinement.
- Configurable actions beyond lock (blur, dim, hide windows).
