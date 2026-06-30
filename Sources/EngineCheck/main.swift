import Foundation
import NoDonutsCore

// Owner: homer — framework-free verification of the presence engine's decision
// logic. The engine is deterministic by design (injected `now` + injected
// protocols), so the full present/absent/grace/lock policy is checkable without a
// camera or a real screen lock. Runs in ANY toolchain (incl. Command Line Tools,
// where XCTest / Swift Testing are unavailable): `swift run EngineCheck`.
// Covers ND-014 (lock success/failure handling) and ND-015 (presence loop).

// MARK: - Configurable test doubles

final class StubCamera: CameraCapturing, @unchecked Sendable {
    var outcome: CaptureOutcome
    init(_ outcome: CaptureOutcome) { self.outcome = outcome }
    func capture() async -> CaptureOutcome { outcome }
}

final class StubRecognizer: FaceRecognizing, @unchecked Sendable {
    var result: RecognitionResult
    init(_ result: RecognitionResult) { self.result = result }
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult { result }
}

final class SpyLocker: ScreenLocking, @unchecked Sendable {
    var shouldSucceed: Bool
    private(set) var lockCallCount = 0
    init(succeed: Bool) { shouldSucceed = succeed }
    @discardableResult
    func lock() -> Bool { lockCallCount += 1; return shouldSucceed }
}

// MARK: - Tiny check runner

final class Checks {
    private(set) var passed = 0
    private(set) var failed = 0
    func expect(_ condition: Bool, _ name: String) {
        if condition { passed += 1; print("  ✅ \(name)") }
        else { failed += 1; print("  ❌ \(name)") }
    }
}

let t0 = Date(timeIntervalSinceReferenceDate: 0)

@MainActor
func makeEngine(_ camera: CameraCapturing, _ recognizer: FaceRecognizing,
                _ locker: ScreenLocking, _ config: Config = Config()) -> PresenceEngine {
    PresenceEngine(camera: camera, recognizer: recognizer, locker: locker, config: config)
}

@MainActor
func driveUntilGraceElapsed(_ engine: PresenceEngine, _ config: Config) async {
    for i in 0..<config.consecutiveAbsentTicksToLock {
        await engine.tick(now: t0.addingTimeInterval(Double(i)))
    }
    await engine.tick(now: t0.addingTimeInterval(Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
}

@MainActor
func runAll() async -> Bool {
    let c = Checks()
    print("PresenceEngine checks:")

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
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0...config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        c.expect(e.state == .absent && locker.lockCallCount == 0, "absent but within grace → no lock yet")
    }

    // Lock failure: no fail-open, no retry storm
    do {
        let config = Config()
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1, "lock fails → .lockFailed (no fail-open)")
    }
    do {
        let config = Config()
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        for i in 1...5 {
            await e.tick(now: t0.addingTimeInterval(config.graceSeconds + 10 + Double(i)))
        }
        c.expect(locker.lockCallCount == 1 && e.state == .lockFailed, "failed lock attempted once per episode (no storm)")
    }

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
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)                       // establish .present
        recognizer.result = .error("wedged recognizer")
        // Drive consecutive error ticks. Each escalation (every Nth error, where
        // N = maxConsecutiveErrorsBeforeAbsent) calls markAbsent — which resets the
        // error streak and advances the absence consensus by one. So reaching the
        // absence consensus takes maxConsecutiveErrorsBeforeAbsent escalations, i.e.
        // maxConsecutiveErrorsBeforeAbsent * consecutiveAbsentTicksToLock error ticks.
        // Then let grace elapse to actually lock.
        let errorTicks = config.maxConsecutiveErrorsBeforeAbsent * config.consecutiveAbsentTicksToLock
        for i in 0..<errorTicks {
            await e.tick(now: t0.addingTimeInterval(Double(i) + 1))
        }
        // A clean no-face reading after grace elapses drives the grace→lock path.
        recognizer.result = .noFace
        await e.tick(now: t0.addingTimeInterval(Double(errorTicks) + config.graceSeconds + 2))
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "sustained error escalates to absence → locks once (EC-10, no fail-open)")
    }

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
        e.lockNow()
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "lockNow success → suspended")
    }
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        e.lockNow()
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1, "lockNow failure → .lockFailed")
    }

    // Pause
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        e.isPaused = true
        await e.tick(now: t0)
        c.expect(e.state == .paused && locker.lockCallCount == 0, "paused → never locks")
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

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
