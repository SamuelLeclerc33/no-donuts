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

/// Fake embedder for identity-recognizer checks: returns a fixed `FaceEmbeddingOutcome`
/// you set per test. No Vision, no camera. Convenience init from `[Float]?` (nil = noFace).
final class FakeEmbedder: FaceEmbedding, @unchecked Sendable {
    var outcome: FaceEmbeddingOutcome
    init(_ outcome: FaceEmbeddingOutcome) { self.outcome = outcome }
    /// nil vector → `.noFace`; a vector → `.embedding(vector)`.
    convenience init(_ vector: [Float]?) {
        self.init(vector.map(FaceEmbeddingOutcome.embedding) ?? .noFace)
    }
    func embedding(for frame: CapturedFrame) async -> FaceEmbeddingOutcome { outcome }
}

// EnrollmentState isn't Equatable (associated value), so tiny matchers for the checks.
func isNotEnrolled(_ s: EnrollmentState) -> Bool { if case .notEnrolled = s { return true }; return false }
func isEnrolledState(_ s: EnrollmentState) -> Bool { if case .enrolled = s { return true }; return false }

final class SpyLocker: ScreenLocking, @unchecked Sendable {
    var shouldSucceed: Bool
    private(set) var lockCallCount = 0
    init(succeed: Bool) { shouldSucceed = succeed }
    @discardableResult
    func lock() async -> Bool { lockCallCount += 1; return shouldSucceed }
}

/// Locker whose `lock()` yields (a suspension point) before returning, and records
/// both how many times it was entered and whether two calls were ever in flight at
/// once. Used to prove the engine's in-flight guard prevents overlapping locks.
@MainActor
final class SlowSpyLocker: ScreenLocking {
    var shouldSucceed: Bool
    private(set) var lockCallCount = 0
    private(set) var maxConcurrent = 0
    private var inFlight = 0
    init(succeed: Bool) { shouldSucceed = succeed }
    @discardableResult
    func lock() async -> Bool {
        lockCallCount += 1
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        await Task.yield()   // suspension point: lets a second concurrent call interleave if unguarded
        inFlight -= 1
        return shouldSucceed
    }
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
        await e.lockNow()
        c.expect(e.state == .suspended && locker.lockCallCount == 1, "lockNow success → suspended")
    }
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.lockNow()
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1, "lockNow failure → .lockFailed")
    }

    // Code review [1]: a FAILED manual lockNow() sets .lockFailed but not
    // lockAttempted. A subsequent no-face tick must NOT clobber that warning with
    // .absent (which would hide the "can't lock — grant Accessibility" status).
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        await e.lockNow()                            // → .lockFailed (manual, lockAttempted stays false)
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

    // TrustedNetworksStore fail-safe (ND-036). Backed by a throwaway UserDefaults
    // suite (unique name) so it never touches real prefs; if the suite init fails,
    // fall back to .standard with a unique key. Fail-safe: nil/empty SSID is NEVER
    // trusted → enforcement stays ON when the SSID can't be read.
    do {
        let suiteName = "com.nodonuts.enginecheck.\(UUID().uuidString)"
        let usedSuite = UserDefaults(suiteName: suiteName)
        let store: TrustedNetworksStore
        if let suite = usedSuite {
            store = TrustedNetworksStore(defaults: suite)
        } else {
            store = TrustedNetworksStore(key: "trustedWiFiSSIDs.\(UUID().uuidString)")
        }
        let nilNotTrusted = store.isTrusted(nil) == false
        let emptyNotTrusted = store.isTrusted("") == false
        store.add("Home")
        let homeTrusted = store.isTrusted("Home") == true
        let homeContained = store.contains("Home") == true
        store.remove("Home")
        let removedNotTrusted = store.isTrusted("Home") == false
        c.expect(nilNotTrusted && emptyNotTrusted && homeTrusted && homeContained && removedNotTrusted,
                 "TrustedNetworksStore: nil/empty never trusted; add/remove round-trips (ND-036)")
        // Clean up the throwaway suite so nothing persists on disk.
        if usedSuite != nil { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    }

    // MARK: - Recognition core (cooper): cosine, identity recognizer, store (ND-021/024)

    print("\nRecognition checks:")

    // cosineSimilarity — pure math.
    do {
        let a: [Float] = [1, 2, 3, 4]
        c.expect(abs(cosineSimilarity(a, a) - 1.0) < 1e-6, "cosine: identical vectors → ~1.0")
        c.expect(cosineSimilarity([1, 0], [0, 1]) == 0, "cosine: orthogonal [1,0]/[0,1] → 0")
        c.expect(cosineSimilarity([1, 2, 3], [1, 2]) == 0, "cosine: mismatched lengths → 0")
        c.expect(cosineSimilarity([], []) == 0, "cosine: empty → 0")
        c.expect(cosineSimilarity([0, 0], [1, 1]) == 0, "cosine: zero-norm vector → 0")
        c.expect(cosineSimilarity([Float.nan, 1], [1, 1]) == 0, "cosine: NaN component → 0 (corrupt blob, no match)")
        c.expect(cosineSimilarity([Float.infinity, 1], [1, 1]) == 0, "cosine: Inf component → 0")
    }

    // IdentityRecognizer with fake embedder + in-memory store.
    let matchV: [Float] = [1, 0, 0, 0]
    let differentV: [Float] = [0, 1, 0, 0]  // orthogonal to matchV → cos 0 < threshold
    let threshold = Config().matchThreshold

    // (a) not enrolled + embedder returns a vector → present (presence-only fallback).
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "identity: not enrolled + face → present (presence-only fallback)")
    }

    // (b) not enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: not enrolled + no face → .noFace")
    }

    // (c) enrolled with V, embedder returns V → present, confidence >= threshold.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV])
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        if case let .enrolledUserPresent(confidence) = result {
            c.expect(confidence >= threshold, "identity: enrolled + matching → present, confidence >= threshold")
        } else {
            c.expect(false, "identity: enrolled + matching → present, confidence >= threshold")
        }
    }

    // (d) enrolled, embedder returns a very different vector (cos < threshold) → strangerOnly (EC-03).
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV])
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly, "identity: enrolled + non-matching face → .strangerOnly (EC-03)")
    }

    // (e) enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV])
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: enrolled + no face → .noFace")
    }

    // (f) FAIL-SAFE: embedder .failure → .error (EC-10 hold), NOT .noFace/absence —
    // both when enrolled and when not enrolled. A transient Vision glitch must not
    // count toward the absence consensus and lock a present user.
    do {
        let notEnrolled = InMemoryEnrollmentStore()
        let r1 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: notEnrolled, matchThreshold: threshold)
        let res1 = await r1.recognize(CapturedFrame())
        let enrolled = InMemoryEnrollmentStore()
        try? enrolled.enroll(embeddings: [matchV])
        let r2 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: enrolled, matchThreshold: threshold)
        let res2 = await r2.recognize(CapturedFrame())
        c.expect(res1 == .error("face embedding failed") && res2 == .error("face embedding failed"),
                 "identity: embedder .failure → .error (EC-10 hold), never absence")
    }

    // (g) FAIL-SAFE (S1): store .unavailable (Keychain read failed) → .error even with a
    // face present — MUST NOT drop to presence-only (which would let any stranger pass).
    do {
        let store = InMemoryEnrollmentStore(embeddings: [matchV], simulateUnavailable: true)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .error("enrollment store unavailable"),
                 "identity: store .unavailable + face → .error (fail-safe, never presence-only) [S1]")
    }

    // InMemoryEnrollmentStore round-trip + enrollmentState transitions.
    do {
        let store = InMemoryEnrollmentStore()
        let notEnrolledInitially = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        try? store.enroll(embeddings: [matchV])
        let enrolledAfter = store.isEnrolled && store.enrolledEmbeddings() == [matchV] && isEnrolledState(store.enrollmentState())
        try? store.reset()
        let notEnrolledAfterReset = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        c.expect(notEnrolledInitially && enrolledAfter && notEnrolledAfterReset,
                 "InMemoryEnrollmentStore: enrollmentState notEnrolled → enrolled → reset round-trip")
    }

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
