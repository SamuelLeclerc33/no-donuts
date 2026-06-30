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
9. ND-031 — camera-in-use detection ("in a meeting" signal) — blart
10. ND-033 — assume-present when camera busy + no frames (ADR-0003) — homer
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
- [ ] ND-013 Display/lock/session state detection (suspend loop when locked/asleep) — blart
- [x] ND-014 Verify a reliable programmatic **screen lock** under entitlements — wiggum
- [x] ND-015 Presence loop scaffold with fake "always present" recognizer — homer
- [ ] ND-016 LaunchAgent plist + install script (RunAtLoad) — gordon
- [ ] ND-017 Menu-bar presence indicator (present / away / in a meeting / can't-see-you) — krusty
- [x] ND-018 Runnable `.app` bundle with camera entitlement — `scripts/make-app.sh` (SPM build + bundle + ad-hoc codesign; CLT-only, no Xcode), ADR-0008 — gordon
- [ ] ND-019 Fix duplicate ADR number: `0005-docs-site.md` and `0005-presence-loop-concurrency.md` both numbered 0005 — renumber docs-site → 0007 and update CLAUDE.md + index references — gordon

> **Review follow-ups (from the ND-010/015 code review, deferred to their owning items):**
> - **ND-011** (blart): on `.unavailable` the engine returns without updating state, so the menu shows stale "present" — fix honest-status display + EC-08/09 fail policy. Also: the loop's first tick fires immediately at launch → real camera permission prompt would pop on every login; consider delaying the first real capture.
> - **ND-014** (wiggum): `PresenceEngine` is now `@MainActor`, so a synchronous `ScreenLocker.lock()` would block the UI at lock time — run the real lock off the main actor (ADR-0005).
> - **ND-025** (homer): remove/`#if DEBUG`-fence `AlwaysPresent*` fakes so they can't ship in a release binary and silently defeat locking.
> - **ND-042** (blart/homer): loop period = work + `Task.sleep` (drifts longer than `tickIntervalSeconds`); and `loopTask` cancellation interrupts only the sleep, not an in-flight `capture()`/`recognize()` — make the real async calls cancellation-aware.

> **Lock follow-ups (from the ND-014 code review — accepted weaker guarantee for MVP):**
> - **Verified lock state** (wiggum): osascript exit 0 ≠ screen locked (undetectable fail-open if Ctrl-Cmd-Q remapped/disabled). Confirm the real lock via `CGSessionCopyCurrentDictionary()` `CGSSessionScreenIsLocked` so `lock()` is honest regardless of mechanism.
> - **Non-blocking lock** (wiggum/homer): `lock()` runs `waitUntilExit()` on the `@MainActor` path; make it async so a hung `osascript` can't beachball the UI (pairs with the CGSession work).
> - **Lock-failed retry/backoff** (homer): after `.lockFailed` the engine attempts once per absence episode and then stops; add a coarse retry-with-backoff so it recovers if Accessibility is granted mid-absence.
> - **Log subsystem constant** (gordon/wiggum): extract the hardcoded `"com.nodonuts.app"` Logger subsystem to a shared constant tied to the bundle id (ADR-0004) so it can't drift at ND-050 rename.

> **Camera follow-ups (from the ND-018/011/012 code review — MUST resolve fail-opens BEFORE ND-025 wires the real recognizer; currently masked by the always-present fake):**
> - **⚠️ Fail-open policy** (homer/blart): `.unavailable` (no camera device / clamshell EC-07/EC-09, or persistent no-frame) → engine `.cameraUnavailable` → never locks. With the real recognizer this becomes a silent fail-open. Decide the EC-07/EC-09 fail policy (lean-secure vs don't-lock-out) and route persistent-no-frame through the ND-031 busy-camera path before ND-025.
> - **Retained pixel buffer** (blart): the delegate pins one `CVPixelBuffer` from the pool between ticks; deep-copy on read (or stop session between ticks) so it can't stall delivery — do when the frame is actually consumed (ND-020) / ND-042.
> - **First-tick latency** (blart): `waitForFirstFrame` can add ~1.5s to the first tick after permission; pre-warm at launch / shorten — ND-042.
> - **Duty-cycle** (blart/homer): even at ~1fps the persistent session runs continuously; consider stop-between-ticks for real power savings — ND-042.

## M2 — Local face recognition (identity) — ⏳ post-MVP (v1.1)

- [ ] ND-020 Vision face detection in the capture path — cooper
- [ ] ND-021 Select + bundle a Core ML face-embedding model — cooper
- [ ] ND-022 Enrollment flow: capture reference frames → embeddings — cooper + krusty
- [ ] ND-023 Encrypted-at-rest embedding store (Keychain/encrypted file) — cooper
- [ ] ND-024 Cosine matching + threshold; tune defaults on real data — cooper
- [ ] ND-025 Wire recognizer into presence engine (replace fake) — homer

## M3 — Presence policy & professional-friendliness

- [ ] ND-030 Grace period + consecutive-absent debounce — homer
- [ ] ND-031 Camera-in-use detection (another app holds the device) — blart
- [ ] ND-032 Attempt multi-client shared frames during a call — blart
- [ ] ND-033 Fallback "assume present" when busy + no frames (ADR-0003) — homer
- [ ] ND-034 Stranger-present-but-user-absent policy (see edge cases) — homer + wiggum
- [ ] ND-035 Pause (timed + indefinite) + manual lock-now — krusty + homer

## M4 — Settings, polish, anti-spoofing

- [ ] ND-040 Settings UI: tick interval, grace, sensitivity, autostart — krusty
- [ ] ND-041 Basic anti-spoofing (e.g. reject obvious photo; liveness signals) — wiggum + cooper
- [ ] ND-042 Power/CPU profiling + duty-cycle tuning — blart + homer
- [ ] ND-043 Onboarding: first-run enrollment + permission walkthrough — krusty
- [ ] ND-044 Logging/diagnostics (local only, privacy-safe) — gordon

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
