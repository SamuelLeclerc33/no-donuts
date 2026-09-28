import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// Present path, ND-017 responsive indicator, ND-033 bounded busy.
@MainActor
func runPresenceBasicsChecks(_ c: Checks) async {

    // Present path
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.tick(now: t0)
        c.expect(e.state == .present && locker.lockCallCount == 0, "enrolled user present → unlocked")
    }
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.cameraBusyNoFrames), StubRecognizer(.noFace), locker)
        await e.tick(now: t0)
        c.expect(e.state == .callAssumedPresent && locker.lockCallCount == 0, "camera busy → assume present, no lock (ADR-0003)")
    }

    // ND-017: responsive indicator. From .present, a SINGLE no-face tick must flip
    // the state to .absent immediately (honest "away" from the first no-face tick)
    // WITHOUT locking — the lock is still gated on consensus + grace.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)                        // establish .present
        recognizer.result = .noFace
        await e.tick(now: t0.addingTimeInterval(1))  // single no-face tick
        c.expect(e.state == .absent && locker.lockCallCount == 0,
                 "single no-face from present → .absent immediately, no lock (ND-017)")
    }

    // ND-033: bounded busy→assume-present. Continuous busy UNDER the cap keeps
    // assuming present and never locks.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.cameraBusyNoFrames), StubRecognizer(.noFace), locker, config)
        // Several busy ticks, all within maxCallAssumedPresentSeconds of the first.
        for i in 0..<5 {
            await e.tick(now: t0.addingTimeInterval(Double(i) * config.tickIntervalSeconds))
        }
        // One more, still under the cap.
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds - 1))
        c.expect(e.state == .callAssumedPresent && locker.lockCallCount == 0,
                 "busy under cap → assume present, no lock (ND-033/ADR-0003)")
    }

    // ND-033: continuous busy PAST the cap escalates to absence and, with continued
    // busy ticks + grace, locks exactly once (a call app left running unattended).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.cameraBusyNoFrames), StubRecognizer(.noFace), locker, config)
        // First busy tick opens the assume-present window at t0.
        await e.tick(now: t0)
        // Drive consecutiveAbsentTicksToLock busy escalations, all past the cap so
        // each calls markAbsent and advances the absence consensus by one.
        let base = config.maxCallAssumedPresentSeconds
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        // Final busy tick after grace elapses → lock fires once.
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(e.state == .suspended && locker.lockCallCount == 1,
                 "busy past cap → escalates to absence, locks once (ND-033)")
    }

    // ND-033: busy → a real present frame resets the window; a subsequent SHORT busy
    // burst assumes present again (the window was cleared, not still expired).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(camera, recognizer, locker, config)
        // Busy past the cap would escalate — but first establish a long busy run,
        // then a real present frame that must reset callAssumedSince.
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds - 1)) // still under cap
        // Real frame with enrolled user present → resets the busy window.
        camera.outcome = .frame(CapturedFrame())
        recognizer.result = .enrolledUserPresent(confidence: 1)
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds))
        let presentAfterFrame = e.state == .present
        // A short busy burst right after must assume present again (window reset).
        camera.outcome = .cameraBusyNoFrames
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds + 1))
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds + 2))
        c.expect(presentAfterFrame && e.state == .callAssumedPresent && locker.lockCallCount == 0,
                 "busy → present frame resets window → short busy assumes present again (ND-033)")
    }

    // ND-033 regression: sessionSuspended() (the production lock/unlock path) must
    // clear the busy/assume-present window. Otherwise, after the cap fires + the
    // user unlocks + rejoins a call, the engine sees the STALE callAssumedSince and
    // immediately re-escalates → locks during a FRESH call. Drive busy ticks under
    // the cap, simulate a lock via sessionSuspended(), then drive busy ticks again
    // only slightly later: the window must have been cleared, so we assume present
    // again (no immediate over-cap escalation).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        // Open the busy window and accumulate toward (but not past) the cap.
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds - 1)) // still under cap
        let assumedBeforeSuspend = e.state == .callAssumedPresent && locker.lockCallCount == 0
        // Simulate the OS session suspend (lock). Production path — must clear the
        // busy window via resetAbsenceAccounting().
        e.sessionSuspended()
        // Resume + rejoin a call: busy ticks again, only slightly later than the
        // OLD window's start. If callAssumedSince had survived, the stale elapsed
        // time would exceed the cap and escalate → lock. It must NOT.
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds + 5))
        await e.tick(now: t0.addingTimeInterval(config.maxCallAssumedPresentSeconds + 6))
        c.expect(assumedBeforeSuspend && e.state == .callAssumedPresent && locker.lockCallCount == 0,
                 "sessionSuspended() clears busy window → fresh call assumes present, no lock (ND-033)")
    }

    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.suspended), StubRecognizer(.noFace), locker)
        await e.tick(now: t0)
        c.expect(e.state == .suspended && locker.lockCallCount == 0, "camera suspended → suspended, no lock")
    }
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.unavailable("denied")), StubRecognizer(.noFace), locker)
        await e.tick(now: t0)
        c.expect(e.state == .cameraUnavailable && locker.lockCallCount == 0, "camera unavailable → honest status, no lock (EC-08)")
    }
}

/// ND-078 / ND-098: camera-unavailable window, lid policy, escalation.
@MainActor
func runCameraUnavailableEscalationChecks(_ c: Checks) async {
    // ND-078 / ND-098: defaults.
    c.expect(Config().maxCameraUnavailableSeconds == 120, "default maxCameraUnavailableSeconds == 120 (ND-078)")
    c.expect(Config().maxCallAssumedPresentSeconds == 600, "default maxCallAssumedPresentSeconds == 600 (ND-098)")

    // ND-078: lid open → no lock before the cap; escalates at the cap and locks
    // after the normal consensus + grace.
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.unavailable("wedged")), StubRecognizer(.noFace), locker, config)
        var t = 0.0
        var heldBeforeCap = true
        while t < cap {
            await e.tick(now: t0.addingTimeInterval(t))
            if e.state != .cameraUnavailable || locker.lockCallCount != 0 { heldBeforeCap = false }
            t += 1
        }
        c.expect(heldBeforeCap, "lid open: unavailable < cap → .cameraUnavailable, no lock (ND-078)")
        let notEscalatingBeforeCap = !e.cameraUnavailableEscalating
        await e.tick(now: t0.addingTimeInterval(cap))
        c.expect(notEscalatingBeforeCap && e.cameraUnavailableEscalating
                 && e.state == .cameraUnavailable && locker.lockCallCount == 0,
                 "lid open: unavailable at cap → escalating, display stays .cameraUnavailable, no lock yet (ND-078)")
        var displayHeld = true
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(cap + Double(i)))
            if e.state != .cameraUnavailable { displayHeld = false }
        }
        await e.tick(now: t0.addingTimeInterval(cap + Double(config.consecutiveAbsentTicksToLock) + 1))
        if e.state != .cameraUnavailable { displayHeld = false }
        c.expect(displayHeld, "lid open: between cap expiry and lock, display stays .cameraUnavailable (ND-078)")
        let noLockInGrace = locker.lockCallCount == 0
        await e.tick(now: t0.addingTimeInterval(cap + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds))
        c.expect(noLockInGrace && e.state == .suspended && locker.lockCallCount == 1,
                 "lid open: unavailable past cap + consensus + grace → locks once (ND-078)")
    }

    // ND-078: lid closed → never locks, even after an hour of unavailability.
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.unavailable("clamshell")), StubRecognizer(.noFace), locker,
                           lid: { .closed })
        var allUnavailable = true
        for i in stride(from: 0, through: 3600, by: 1) {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
            if e.state != .cameraUnavailable { allUnavailable = false }
        }
        c.expect(allUnavailable && locker.lockCallCount == 0,
                 "lid closed: 1h unavailable → .cameraUnavailable, never locks (ND-078)")
    }

    // ND-078: no lid (desktop Mac, built-in-only camera → permanently unavailable)
    // never escalates or locks; also with busy/no-face interleavings.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.unavailable("no built-in camera"))
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config, lid: { .noLid })
        var ok = true
        for i in stride(from: 0, through: 3600, by: 1) {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
            if e.state != .cameraUnavailable || e.cameraUnavailableEscalating { ok = false }
        }
        let lockerB = SpyLocker(succeed: true)
        let camB = StubCamera(.frame(CapturedFrame()))
        let b = makeEngine(camB, StubRecognizer(.noFace), lockerB, config, lid: { .noLid })
        for i in 0..<600 {
            camB.outcome = i % 2 == 0 ? .frame(CapturedFrame()) : .unavailable("none")
            await b.tick(now: t0.addingTimeInterval(Double(i)))
        }
        c.expect(ok && locker.lockCallCount == 0 && lockerB.lockCallCount == 0,
                 "no lid (desktop): 1h unavailable (+interleavings) → never escalates, never locks (ND-078)")
    }

    // ND-078: a frame after escalation clears cameraUnavailableEscalating.
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let camera = StubCamera(.unavailable("wedged"))
        let e = makeEngine(camera, StubRecognizer(.enrolledUserPresent(confidence: 1)), SpyLocker(succeed: true), config)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(cap))
        let was = e.cameraUnavailableEscalating
        camera.outcome = .frame(CapturedFrame())
        await e.tick(now: t0.addingTimeInterval(cap + 1))
        c.expect(was && !e.cameraUnavailableEscalating && e.state == .present,
                 "frame after escalation → present, cameraUnavailableEscalating cleared (ND-078)")
    }

    // ND-078: a real frame mid-window resets it — a fresh full cap is needed.
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.unavailable("wedged"))
        let e = makeEngine(camera, StubRecognizer(.enrolledUserPresent(confidence: 1)), locker, config)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(cap - 1))
        camera.outcome = .frame(CapturedFrame())
        await e.tick(now: t0.addingTimeInterval(cap - 0.5))
        let present = e.state == .present
        camera.outcome = .unavailable("wedged")
        await e.tick(now: t0.addingTimeInterval(cap))          // new window opens here
        await e.tick(now: t0.addingTimeInterval(2 * cap - 1))  // still under the NEW cap
        c.expect(present && e.state == .cameraUnavailable && locker.lockCallCount == 0,
                 "lid open: frame mid-window resets the unavailable window (ND-078)")
    }

    // ND-078: lid open → closed mid-window resets it; reopening needs a fresh full cap.
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let locker = SpyLocker(succeed: true)
        let lid = FakeLid(.open)
        let e = makeEngine(StubCamera(.unavailable("wedged")), StubRecognizer(.noFace), locker, config,
                           lid: { lid.state })
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(cap - 1))
        lid.state = .closed
        await e.tick(now: t0.addingTimeInterval(cap + 10))       // clears the window
        lid.state = .open
        await e.tick(now: t0.addingTimeInterval(cap + 20))       // new window opens here
        await e.tick(now: t0.addingTimeInterval(2 * cap + 19))   // under the new cap
        c.expect(e.state == .cameraUnavailable && locker.lockCallCount == 0,
                 "lid open → closed mid-window resets the unavailable window (ND-078)")
    }

    // ND-078: unavailable ticks interleaved with busy ticks do NOT restart the
    // ND-033 call cap — busy past the cap still escalates and locks.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        let callCap = config.maxCallAssumedPresentSeconds
        // Alternate busy / unavailable every 30s: the unavailable run never reaches
        // its own cap, and must not reset callAssumedSince either.
        var t = 0.0
        var phase = 0
        while t < callCap {
            camera.outcome = phase % 2 == 0 ? .cameraBusyNoFrames : .unavailable("flap")
            await e.tick(now: t0.addingTimeInterval(t))
            t += 30; phase += 1
        }
        let noLockBeforeCap = locker.lockCallCount == 0
        camera.outcome = .cameraBusyNoFrames
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(callCap + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(callCap + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(noLockBeforeCap && e.state == .suspended && locker.lockCallCount == 1,
                 "unavailable ticks interleaved with busy don't restart the call cap (ND-078/ND-033)")
    }

    // ND-078 security fix: pre-cap unavailable ticks HOLD (don't reset), so every
    // interleaving of absence ticks with unavailable ticks still locks (lid open).
    do {
        // (a) busy past the call cap, unavailable every other tick.
        let config = Config()
        let callCap = config.maxCallAssumedPresentSeconds
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        await e.tick(now: t0)
        for i in 0..<60 {
            camera.outcome = i % 2 == 0 ? .cameraBusyNoFrames : .unavailable("flicker")
            await e.tick(now: t0.addingTimeInterval(callCap + Double(i)))
        }
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "lid open: busy past call cap interleaved with unavailable → locks (ND-078 fix)")
    }
    do {
        // (b) no-face frames interleaved with unavailable ("no fresh frame").
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.frame(CapturedFrame()))
        let e = makeEngine(camera, StubRecognizer(.noFace), locker)
        for i in 0..<60 {
            camera.outcome = i % 2 == 0 ? .frame(CapturedFrame()) : .unavailable("stale")
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "lid open: no-face frames interleaved with unavailable → locks (ND-078 fix)")
    }
    do {
        // (c) lid closed: interleavings keep today's reset → never lock.
        let config = Config()
        let callCap = config.maxCallAssumedPresentSeconds
        let lockerA = SpyLocker(succeed: true)
        let camA = StubCamera(.cameraBusyNoFrames)
        let a = makeEngine(camA, StubRecognizer(.noFace), lockerA, config, lid: { .closed })
        await a.tick(now: t0)
        for i in 0..<600 {
            camA.outcome = i % 2 == 0 ? .cameraBusyNoFrames : .unavailable("clamshell")
            await a.tick(now: t0.addingTimeInterval(callCap + Double(i)))
        }
        let lockerB = SpyLocker(succeed: true)
        let camB = StubCamera(.frame(CapturedFrame()))
        let b = makeEngine(camB, StubRecognizer(.noFace), lockerB, config, lid: { .closed })
        for i in 0..<600 {
            camB.outcome = i % 2 == 0 ? .frame(CapturedFrame()) : .unavailable("clamshell")
            await b.tick(now: t0.addingTimeInterval(Double(i)))
        }
        c.expect(lockerA.lockCallCount == 0 && lockerB.lockCallCount == 0,
                 "lid closed: busy/no-face interleaved with unavailable → never locks (ND-078)")
    }
    do {
        // (d) present user + brief unavailable blip → frames resume showing the user → no lock.
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.frame(CapturedFrame()))
        let e = makeEngine(camera, StubRecognizer(.enrolledUserPresent(confidence: 1)), locker, config)
        await e.tick(now: t0)
        camera.outcome = .unavailable("blip")
        for i in 1...10 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let heldUnavailable = e.state == .cameraUnavailable
        camera.outcome = .frame(CapturedFrame())
        for i in 11...60 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(heldUnavailable && e.state == .present && locker.lockCallCount == 0,
                 "present + brief unavailable blip → frames resume with user → no false lock (ND-078)")
    }
    do {
        // (e) hold keeps an unresolved .lockFailed warning and its retry schedule.
        let config = Config()
        let locker = ScriptedLocker([false])
        let camera = StubCamera(.frame(CapturedFrame()))
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        let firstAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        camera.outcome = .unavailable("blip")
        await e.tick(now: t0.addingTimeInterval(firstAt + 3))
        let keptFailed = e.state == .lockFailed && e.lockFailureCount == 1
        camera.outcome = .frame(CapturedFrame())
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        c.expect(keptFailed && locker.lockCallCount == 2 && e.lockFailureCount == 2,
                 "unavailable hold keeps .lockFailed + retry schedule (ND-078/ND-054)")
    }

    // ND-098: busy interleaved with frames. Only an enrolled-user frame ends the
    // busy window; noFace / error frames don't, so the call cap still bounds it.
    for (label, result) in [("noFace", RecognitionResult.noFace),
                            ("strangerOnly", RecognitionResult.strangerOnly),
                            ("error", RecognitionResult.error("vision"))] {
        let config = Config()
        let callCap = config.maxCallAssumedPresentSeconds
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let e = makeEngine(camera, StubRecognizer(result), locker, config)
        var firstLockAt: Double?
        var t = 0.0
        while t < callCap + 60 {
            camera.outcome = Int(t) % 2 == 0 ? .cameraBusyNoFrames : .frame(CapturedFrame())
            await e.tick(now: t0.addingTimeInterval(t))
            if firstLockAt == nil && locker.lockCallCount > 0 { firstLockAt = t }
            t += 1
        }
        let bound = callCap + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 5
        c.expect(firstLockAt.map { $0 >= callCap && $0 <= bound } ?? false,
                 "busy/\(label) alternating → no lock before cap, locks by cap + consensus + grace (ND-098), at \(firstLockAt.map { String($0) } ?? "never")")
    }
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.cameraBusyNoFrames)
        let e = makeEngine(camera, StubRecognizer(.enrolledUserPresent(confidence: 1)), locker, config)
        var t = 0.0
        while t < 3 * config.maxCallAssumedPresentSeconds {
            camera.outcome = Int(t) % 2 == 0 ? .cameraBusyNoFrames : .frame(CapturedFrame())
            await e.tick(now: t0.addingTimeInterval(t))
            t += 1
        }
        c.expect(locker.lockCallCount == 0,
                 "busy/enrolledUserPresent alternating (user really present) → never locks (ND-098)")
    }

    // ND-078: pause mid-window clears it (full reset).
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.unavailable("wedged")), StubRecognizer(.noFace), locker, config)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(cap - 1))
        e.pause()
        await e.tick(now: t0.addingTimeInterval(cap + 5))        // new window opens here
        c.expect(e.state == .cameraUnavailable && locker.lockCallCount == 0,
                 "pause clears the unavailable window (ND-078)")
    }

    // ND-078 + ND-054: after escalation, a failed lock is retried on the backoff.
    do {
        let config = Config()
        let cap = config.maxCameraUnavailableSeconds
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.unavailable("wedged")), StubRecognizer(.noFace), locker, config)
        await e.tick(now: t0)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(cap + Double(i)))
        }
        let firstAt = cap + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt))
        let failedOnce = locker.lockCallCount == 1 && e.state == .lockFailed && e.lockFailureCount == 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 5))
        let noEarly = locker.lockCallCount == 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        c.expect(failedOnce && noEarly && locker.lockCallCount == 2 && e.state == .lockFailed,
                 "unavailable escalation: failed lock retried at +10s, not before (ND-078/ND-054)")
    }
}

/// Absence → lock; ND-061 stranger-at-keyboard fast path (ADR-0017).
@MainActor
func runAbsenceAndStrangerChecks(_ c: Checks) async {
    // Absence → lock
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "absence past grace → locks once")
    }
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker, config)
        await driveUntilGraceElapsed(e, config)
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "stranger counts as absent → locks (EC-03)")
    }

    // MARK: ND-061 stranger-at-keyboard fast path (ADR-0017)
    do {
        let d = Config()
        c.expect(d.consecutiveStrangerTicksToLock == 3 && d.strangerGraceSeconds == 0
                 && d.consecutiveAbsentTicksToLock == 5 && d.graceSeconds == 5,
                 "ND-061 defaults: stranger 3 ticks + 0s grace; empty desk unchanged 5 ticks + 5s")
    }
    do {
        // 3 consecutive stranger ticks → lock AT tick 3, no grace.
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(1))
        let noLockAt2 = locker.lockCallCount == 0 && e.state == .absent
        await e.tick(now: t0.addingTimeInterval(2))
        let lockedAt3 = locker.lockCallCount == 1 && e.state == .suspended
        for i in 3..<30 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(noLockAt2 && lockedAt3 && locker.lockCallCount == 1,
                 "ND-061: 3 stranger ticks → locks at tick 3 (no grace), once; not at tick 2")
    }
    do {
        // stranger, stranger, noFace, noFace... → no fast lock; normal path still
        // locks at consensus (5 ticks, strangers counted) + 5s grace.
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.strangerOnly, .strangerOnly, .noFace]), locker, config)
        var firstLockAt: Double?
        for i in 0..<30 {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
            if firstLockAt == nil && locker.lockCallCount > 0 { firstLockAt = Double(i) }
        }
        let expected = Double(config.consecutiveAbsentTicksToLock - 1) + config.graceSeconds  // consensus tick 4, +5s
        c.expect(firstLockAt == expected && locker.lockCallCount == 1,
                 "ND-061: 2 stranger + noFace → no fast lock; normal consensus+grace locks at t=\(expected), got \(firstLockAt.map { String($0) } ?? "never")")
    }
    do {
        // stranger, noFace, stranger, stranger → streak broken by noFace → no fast lock at tick 4.
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.strangerOnly, .noFace, .strangerOnly, .strangerOnly, .noFace]), locker)
        for i in 0..<4 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 0 && e.state == .absent,
                 "ND-061: noFace breaks the stranger streak (stranger, noFace, stranger, stranger → no fast lock)")
    }
    do {
        // stranger, error, stranger, stranger → error HOLDS the streak (EC-10) → locks on the 3rd stranger.
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.strangerOnly, .error("vision"), .strangerOnly, .strangerOnly]), locker)
        for i in 0..<3 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let noLockYet = locker.lockCallCount == 0
        await e.tick(now: t0.addingTimeInterval(3))
        c.expect(noLockYet && locker.lockCallCount == 1 && e.state == .suspended,
                 "ND-061: stranger, error, stranger, stranger → error holds streak → locks at 3rd stranger (EC-10)")
    }
    do {
        // stranger, stranger, present, stranger, stranger → present resets everything → no lock.
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.strangerOnly, .strangerOnly, .enrolledUserPresent(confidence: 1),
                                          .strangerOnly, .strangerOnly]), locker)
        for i in 0..<5 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 0 && e.state == .absent,
                 "ND-061: stranger, stranger, present, stranger, stranger → present resets streak → no lock")
    }
    do {
        // Failed fast lock → ND-054 backoff: no retry before +10s, retry at +10s.
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker)
        for i in 0..<3 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let failed = locker.lockCallCount == 1 && e.state == .lockFailed && e.lockFailureCount == 1
        var early = false
        for i in 3..<12 {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
            if locker.lockCallCount != 1 { early = true }
        }
        await e.tick(now: t0.addingTimeInterval(12))
        c.expect(failed && !early && locker.lockCallCount == 2 && e.lockFailureCount == 2 && e.state == .lockFailed,
                 "ND-061: failed fast lock → .lockFailed, retried on ND-054 backoff at +10s, not before")
    }
    do {
        // Fast lock succeeds → the session-suspend it causes resets; a later
        // stranger run needs a fresh 3-tick streak (no carry-over).
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker)
        for i in 0..<3 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        e.sessionSuspended()
        await e.tick(now: t0.addingTimeInterval(100))
        await e.tick(now: t0.addingTimeInterval(101))
        let noCarry = locker.lockCallCount == 1
        await e.tick(now: t0.addingTimeInterval(102))
        c.expect(noCarry && locker.lockCallCount == 2,
                 "ND-061: after lock + sessionSuspended, a new stranger run needs a fresh 3-tick streak")
    }
    do {
        // Non-zero stranger grace is honored: 3 ticks + 2s.
        var config = Config()
        config.strangerGraceSeconds = 2
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker, config)
        for i in 0..<4 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let noLockInGrace = locker.lockCallCount == 0
        await e.tick(now: t0.addingTimeInterval(4))
        c.expect(noLockInGrace && locker.lockCallCount == 1,
                 "ND-061: strangerGraceSeconds=2 → locks 2s after the 3rd stranger tick, not before")
    }
    do {
        // Cancelled tick never fast-locks (shared maybeLock cancellation guard).
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.strangerOnly), locker)
        for i in 0..<2 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await e.tick(now: t0.addingTimeInterval(2))
        }
        await task.value
        c.expect(locker.lockCallCount == 0, "ND-061: cancelled tick at the stranger threshold does not lock")
    }
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0...config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        c.expect(e.state == .absent && locker.lockCallCount == 0, "absent but within grace → no lock yet")
    }
}

/// Recognition error → conservative HOLD (EC-10, ND-060).
@MainActor
func runRecognitionErrorHoldChecks(_ c: Checks) async {
    // Recognition error → conservative HOLD (EC-10)
    do {
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        await e.tick(now: t0)                       // establish .present
        recognizer.result = .error("vision glitch")
        await e.tick(now: t0.addingTimeInterval(1))  // error tick must not change state
        c.expect(e.state == .present && locker.lockCallCount == 0, "recognition error from present → holds .present, no lock (EC-10)")
    }

    // Error mid-absence preserves absence progress (neither resets nor advances consensus).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        // 1 absent tick (below consensus).
        await e.tick(now: t0)
        // One transient error tick: must not reset or advance the absence consensus.
        recognizer.result = .error("vision glitch")
        await e.tick(now: t0.addingTimeInterval(1))
        // Resume no-face ticks + time; absence must still reach grace and lock once.
        recognizer.result = .noFace
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i) + 1))
        }
        await e.tick(now: t0.addingTimeInterval(Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 2))
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "error mid-absence preserves progress → still locks once (EC-10)")
    }

    // Sustained error from present escalates to absence → lock (bounded hold, no fail-open).
    // ND-060: once the error streak reaches maxConsecutiveErrorsBeforeAbsent, EVERY further
    // consecutive error tick is an absence tick (the streak is not reset on escalation).
    // Pinned time-to-lock for a fully wedged recognizer at defaults (1s tick): the lock
    // fires on error tick #(maxErrors − 1 + consensus + grace/tick) = 3 − 1 + 5 + 5 = 12,
    // i.e. 12s after the last present reading — plain absence (10s, below) + 2s, not
    // the old maxErrors × consensus + grace ≈ 20s.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)                       // establish .present
        recognizer.result = .error("wedged recognizer")
        let expected = config.maxConsecutiveErrorsBeforeAbsent - 1 + config.consecutiveAbsentTicksToLock
            + Int(config.graceSeconds / config.tickIntervalSeconds)
        var firstLockAt: Int?
        for n in 1...30 {
            await e.tick(now: t0.addingTimeInterval(Double(n) * config.tickIntervalSeconds))
            if firstLockAt == nil, locker.lockCallCount > 0 { firstLockAt = n }
        }
        c.expect(expected == 12 && firstLockAt == expected,
                 "ND-060: fully wedged recognizer from present locks on error tick #12 (≈12s at defaults, got \(firstLockAt.map(String.init) ?? "never"))")
        c.expect(e.state == .suspended && locker.lockCallCount == 1,
                 "sustained error escalates to absence → locks once, no re-lock storm (EC-10, no fail-open)")
    }
    // Reference: plain absence from present locks on no-face tick #10 at defaults.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)
        recognizer.result = .noFace
        var firstLockAt: Int?
        for n in 1...30 {
            await e.tick(now: t0.addingTimeInterval(Double(n)))
            if firstLockAt == nil, locker.lockCallCount > 0 { firstLockAt = n }
        }
        c.expect(firstLockAt == 10, "ND-060: reference — plain absence from present locks on no-face tick #10 (defaults)")
    }
    // ND-060: a clean reading ends the escalated streak — after present, a single error
    // is held again (no immediate escalation to .absent).
    do {
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.error("wedged"))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        for n in 0..<4 { await e.tick(now: t0.addingTimeInterval(Double(n))) }   // escalated
        let escalated = e.state == .absent
        recognizer.result = .enrolledUserPresent(confidence: 1)
        await e.tick(now: t0.addingTimeInterval(4))
        recognizer.result = .error("glitch")
        await e.tick(now: t0.addingTimeInterval(5))
        c.expect(escalated && e.state == .present && locker.lockCallCount == 0,
                 "ND-060: a clean reading resets the escalated error streak → next lone error is held")
    }
    // ND-060: an escalated error streak interrupted by noFace still locks on the normal
    // path (noFace resets the error streak but counts as absence itself).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.error("wedged"))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        var t = 0.0
        for n in 0..<40 {
            recognizer.result = n % 4 == 3 ? .noFace : .error("wedged")
            await e.tick(now: t0.addingTimeInterval(t)); t += 1
        }
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "ND-060: error/noFace interleaving still reaches consensus + grace → locks once")
    }
}

/// Recovery, manual Lock now, reentrancy/cancellation guards, pause().
@MainActor
func runRecoveryManualLockAndPauseChecks(_ c: Checks) async {
    // Recovery
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await driveUntilGraceElapsed(e, config)
        recognizer.result = .enrolledUserPresent(confidence: 1)
        await e.tick(now: t0.addingTimeInterval(1000))
        let returned = e.state == .present
        recognizer.result = .noFace
        let base = 2000.0
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(returned && e.state == .suspended && locker.lockCallCount == 2, "return resets; new absence can lock again")
    }

    // Manual "Lock now"
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.lockNow()
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "lockNow success → suspended")
    }
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.lockNow()
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1, "lockNow failure → .lockFailed")
    }

    // Code review [1]: a FAILED manual lockNow() sets .lockFailed but records no
    // auto-lock episode state. A subsequent no-face tick must NOT clobber that warning with
    // .absent (which would hide the "can't lock — grant Accessibility" status).
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        await e.lockNow()                            // → .lockFailed (manual; no episode state recorded)
        await e.tick(now: t0.addingTimeInterval(1))  // single no-face tick
        c.expect(e.state == .lockFailed,
                 "no-face tick after failed lockNow keeps .lockFailed warning (not clobbered to .absent) [code review 1]")
    }

    // Code review [2]: async reentrancy guard. Now that locker.lock() is async
    // (~3s in prod), a manual lockNow() and the auto tick loop (or two lockNow()
    // calls) can both reach attemptLock() and run two OVERLAPPING locker.lock()
    // calls that clobber state/accounting. The in-flight guard (isLocking) must
    // ensure the second attempt is SKIPPED while the first is suspended. Fire two
    // overlapping lockNow() calls at a locker that yields mid-lock: exactly one
    // must enter, and the two must never be in flight at once.
    do {
        let locker = SlowSpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        async let a: Void = e.lockNow()
        async let b: Void = e.lockNow()
        _ = await (a, b)
        c.expect(locker.lockCallCount == 1 && locker.maxConcurrent <= 1 && e.state == .suspended,
                 "overlapping lockNow() → guard skips the second, no concurrent lock (code review 2)")
    }

    // Cooperative cancellation guard ("nothing locks mid-capture / mid-pause"). When
    // the App cancels the presence loop Task (pause / trusted-network / enrollment /
    // session-suspend), an already-in-flight tick must NOT lock — Swift doesn't abort
    // a suspended `await`, so markAbsent guards on Task.isCancelled before locking.
    // We reproduce that by driving the engine to the EXACT grace-expiry tick from
    // inside a Task we've cancelled: the auto-lock must not fire. (Task.isCancelled
    // reflects the surrounding Task, so we run the final tick inside a cancelled one.)
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        // Accumulate the full absence consensus WITHOUT crossing grace yet (no lock).
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let noLockBeforeGrace = locker.lockCallCount == 0
        // The grace-expiry tick would normally lock. Run it inside a CANCELLED task.
        // The Task inherits @MainActor isolation (the engine is main-actor), and
        // Task.isCancelled inside it is true → markAbsent bails before attemptLock.
        let cancelledTick = Task { @MainActor in
            await e.tick(now: t0.addingTimeInterval(Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        }
        cancelledTick.cancel()
        await cancelledTick.value
        c.expect(noLockBeforeGrace && locker.lockCallCount == 0,
                 "cancelled loop task at grace-expiry → auto-lock suppressed (cooperative cancellation)")
    }

    // Manual lockNow() must STILL lock even when its Task is cancelled — the guard
    // is in the AUTO path (markAbsent), not in attemptLock(). Prove a cancelled
    // Task around lockNow() locks anyway (manual "Lock now" is never gated).
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        let cancelledManual = Task { @MainActor in await e.lockNow() }
        cancelledManual.cancel()
        await cancelledManual.value
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "lockNow() locks even inside a cancelled task (manual path never gated)")
    }

    // pause() — the PRODUCTION pause entry point (ND-035). There is NO engine-held
    // pause latch: it was removed to kill the fail-OPEN where a stuck latch made
    // every tick short-circuit to .paused and the Mac never locked again (ADR-0011).
    // Pause is App-gate-driven — the App stops the loop AND suspends the camera;
    // pause() only sets honest display state + clears accounting. First: pause()
    // drives .paused and never locks.
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        e.pause()
        c.expect(e.state == .paused && locker.lockCallCount == 0, "pause() → paused display, no lock (ND-035)")
    }

    // pause() resets absence accounting (mirrors the sessionSuspended() reset
    // test): drive partway toward absence, call pause(), then a later no-face
    // episode must need the FULL consensus + grace before it can lock — proving
    // the partial absence was cleared (ND-035).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        // 1-2 absent ticks, below the consensus threshold.
        let partial = max(1, config.consecutiveAbsentTicksToLock - 1)
        for i in 0..<partial {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        // Production pause entry point: must mark paused + reset accounting.
        e.pause()
        let pausedAndReset = e.state == .paused && locker.lockCallCount == 0
        // Resume (App restarts the loop): a single no-face tick right after pause
        // must NOT lock — the partial absence was cleared, so full consensus +
        // grace is required.
        await e.tick(now: t0.addingTimeInterval(Double(partial) + 1))
        let noInstantLock = locker.lockCallCount == 0
        // And the full episode (consensus + grace) still locks exactly once.
        let base = Double(partial) + 1
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(pausedAndReset && noInstantLock && e.state == .suspended && locker.lockCallCount == 1,
                 "pause() resets absence → resume needs full consensus, no false lock (ND-035)")
    }
}

/// disabledOnTrustedNetwork(), suspend/sessionSuspended() resets, updateConfig().
@MainActor
func runTrustedDisableSuspendAndConfigChecks(_ c: Checks) async {
    // disabledOnTrustedNetwork() — on a trusted Wi-Fi network (ND-036), the App
    // layer stops the loop + camera; the engine sets .trustedNetwork and, like
    // the suspend reset, clears absence accounting so leaving the network rebuilds
    // the FULL consensus + grace before it can lock (EC-20).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        // 1 absent tick (below consensus).
        await e.tick(now: t0)
        // Trusted network detected → .trustedNetwork + accounting reset.
        e.disabledOnTrustedNetwork()
        let trustedAndReset = e.state == .trustedNetwork && locker.lockCallCount == 0
        // Leave the network: a single no-face tick right after must NOT lock —
        // partial absence was cleared, so full consensus + grace is required.
        await e.tick(now: t0.addingTimeInterval(2))
        let noInstantLock = locker.lockCallCount == 0
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i) + 2))
        }
        await e.tick(now: t0.addingTimeInterval(Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 3))
        c.expect(trustedAndReset && noInstantLock && e.state == .suspended && locker.lockCallCount == 1,
                 "disabledOnTrustedNetwork() → .trustedNetwork, resets absence so leaving needs full consensus (ND-036/EC-20)")
    }

    // Suspend (locked/asleep/inactive) resets absence → no grace-less false lock
    // on resume (EC-02/EC-13, ND-013). Drive 1 absent tick, then a suspended
    // tick; absence accounting must be cleared so a subsequent no-face episode
    // requires the FULL consensus + grace again before it can lock.
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let camera = StubCamera(.frame(CapturedFrame()))
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        // 1 absent tick (partway toward absence, below consensus).
        await e.tick(now: t0)
        // Session suspends (lock/sleep) → camera reports suspended.
        camera.outcome = .suspended
        await e.tick(now: t0.addingTimeInterval(1))
        let suspendedAndReset = e.state == .suspended && locker.lockCallCount == 0
        // Resume: a single no-face tick right after suspend must NOT instantly
        // lock — absence was reset, so the full consensus + grace is required.
        camera.outcome = .frame(CapturedFrame())
        await e.tick(now: t0.addingTimeInterval(2))
        let noInstantLock = locker.lockCallCount == 0
        // And the full episode (consensus + grace) still locks exactly once.
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i) + 2))
        }
        await e.tick(now: t0.addingTimeInterval(Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 3))
        c.expect(suspendedAndReset && noInstantLock && e.state == .suspended && locker.lockCallCount == 1,
                 "suspend resets absence → resume needs full consensus, no false lock (EC-02/EC-13)")
    }

    // sessionSuspended() — the PRODUCTION reset path (app calls it on OS session
    // suspend; the in-tick .suspended capture branch is only a backstop). Drive
    // partway toward absence (below consensus), call sessionSuspended(), then
    // resume with no-face ticks and confirm the FULL consensus + grace is needed
    // again — i.e. the suspend reset cleared the partial absence (EC-02/EC-13).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        // 1-2 absent ticks, below the consensus threshold.
        let partial = max(1, config.consecutiveAbsentTicksToLock - 1)
        for i in 0..<partial {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        // Production session-suspend entry point: must mark suspended + reset.
        e.sessionSuspended()
        let suspendedAndReset = e.state == .suspended && locker.lockCallCount == 0
        // Resume: a single no-face tick right after suspend must NOT lock —
        // the partial absence was cleared, so full consensus + grace is required.
        await e.tick(now: t0.addingTimeInterval(Double(partial) + 1))
        let noInstantLock = locker.lockCallCount == 0
        // And the full episode (consensus + grace) still locks exactly once.
        let base = Double(partial) + 1
        for i in 1..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(suspendedAndReset && noInstantLock && e.state == .suspended && locker.lockCallCount == 1,
                 "sessionSuspended() resets absence → resume needs full consensus, no false lock (EC-02/EC-13)")
    }

    // updateConfig() live-applies new tunables without a relaunch (ND-040). Start
    // STRICT (huge graceSeconds + consensus) so a short absence run can NEVER reach
    // the lock; confirm no lock. Then updateConfig() to SMALL grace/consensus and
    // drive a fresh absence run: the loosened thresholds must now take effect on the
    // NEXT ticks and lock exactly once. Proves the engine reads config live (not a
    // copy captured at init) and that swapping config mid-run applies immediately.
    do {
        var strict = Config()
        strict.graceSeconds = 100_000
        strict.consecutiveAbsentTicksToLock = 100_000
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, strict)
        // A short absence run under the strict config: nowhere near consensus/grace.
        for i in 0..<10 {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let noLockWhileStrict = locker.lockCallCount == 0 && e.state == .absent
        // Loosen live. Absence accounting is intentionally NOT reset, but the strict
        // run never crossed even the small consensus quickly enough with fresh timing,
        // so drive a clean run against the new (small) thresholds.
        var loose = Config()
        loose.graceSeconds = 2
        loose.consecutiveAbsentTicksToLock = 3
        e.updateConfig(loose)
        // Continue the same no-face episode. Consensus is already exceeded (>10 absent
        // ticks), so the next tick starts the (small) grace clock (absentSince was
        // never set under the strict consensus gate); a further tick past grace locks.
        await e.tick(now: t0.addingTimeInterval(20))   // consensus met → grace clock starts
        let notYetLocked = locker.lockCallCount == 0
        await e.tick(now: t0.addingTimeInterval(25))   // past the 2s grace → locks
        c.expect(noLockWhileStrict && notYetLocked && e.state == .suspended && locker.lockCallCount == 1,
                 "updateConfig() live-applies: strict never locks, loosened config locks next tick (ND-040)")
    }

    // ND-110: updateConfig() MID-EPISODE keeps the in-progress absence episode (tick
    // count AND the running grace clock) and the new thresholds apply from the next
    // tick; updateConfig() itself never locks. Tick-pinned at 1s ticks from .present.
    func firstLock(update afterTick: Int, _ newConfig: Config) async -> (atUpdate: Bool, firstLockAt: Int?, count: Int) {
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, Config())
        await e.tick(now: t0)                              // establish .present
        recognizer.result = .noFace
        var lockedAtUpdate = false
        var firstLockAt: Int?
        for n in 1...30 {
            await e.tick(now: t0.addingTimeInterval(Double(n)))
            if firstLockAt == nil, locker.lockCallCount > 0 { firstLockAt = n }
            if n == afterTick {
                e.updateConfig(newConfig)
                lockedAtUpdate = locker.lockCallCount > 0
            }
        }
        return (lockedAtUpdate, firstLockAt, locker.lockCallCount)
    }
    do {
        // Defaults lock on no-face tick #10 (consensus 5 at tick 5 starts the 5s grace).
        // Tighten consensus 5 → 3 and grace 5 → 2 after tick 3: the 3 absent ticks
        // already counted are kept, so tick 4 meets consensus and starts grace → lock at
        // tick 6. A reset episode would lock at tick 9; the old config at tick 10.
        var tight = Config()
        tight.consecutiveAbsentTicksToLock = 3
        tight.graceSeconds = 2
        let r = await firstLock(update: 3, tight)
        c.expect(!r.atUpdate && r.firstLockAt == 6 && r.count == 1,
                 "ND-110 updateConfig mid-episode (before consensus): absent-tick count kept, new consensus/grace apply → locks at tick 6 (got \(r.firstLockAt.map(String.init) ?? "never"))")
    }
    do {
        // Grace clock already running (started at tick 5). Tighten grace 5 → 2 after
        // tick 6: elapsed is already 1s, so tick 7 (2s since tick 5) is due. Proves the
        // grace START is kept (not restarted at the update) and the new grace applies on
        // the next tick — not retroactively inside updateConfig().
        var shortGrace = Config()
        shortGrace.graceSeconds = 2
        let r = await firstLock(update: 6, shortGrace)
        c.expect(!r.atUpdate && r.firstLockAt == 7 && r.count == 1,
                 "ND-110 updateConfig mid-grace (tighten): grace clock kept, shorter grace applies next tick → locks at tick 7 (got \(r.firstLockAt.map(String.init) ?? "never"))")
    }
    do {
        // Tighten past the already-elapsed time: after tick 8 (3s into grace) set grace 2.
        // The update alone must not lock; the NEXT tick does (tick 9).
        var shortGrace = Config()
        shortGrace.graceSeconds = 2
        let r = await firstLock(update: 8, shortGrace)
        c.expect(!r.atUpdate && r.firstLockAt == 9 && r.count == 1,
                 "ND-110 updateConfig with grace already exceeded: no lock inside updateConfig, locks on the next tick (got \(r.firstLockAt.map(String.init) ?? "never"))")
    }
    do {
        // Loosen grace 5 → 10 mid-grace (after tick 6): the old deadline (tick 10) no
        // longer applies; the grace still counts from tick 5 → lock at tick 15, once.
        var longGrace = Config()
        longGrace.graceSeconds = 10
        let r = await firstLock(update: 6, longGrace)
        c.expect(!r.atUpdate && r.firstLockAt == 15 && r.count == 1,
                 "ND-110 updateConfig mid-grace (loosen): grace counts from the original start → locks at tick 15 (got \(r.firstLockAt.map(String.init) ?? "never"))")
    }
}
