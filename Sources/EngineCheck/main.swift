import Foundation
import ImageIO
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

/// Fake embedder for identity-recognizer checks: returns a fixed `FaceEmbeddingResult`
/// you set per test. No Vision, no camera. The liveness texture score defaults HIGH
/// (well above the spoof floor) so existing tests stay "live" unless they opt into a
/// low score. Convenience inits from `[Float]?` (nil = noFace), from the legacy
/// `FaceEmbeddingOutcome` (e.g. `.failure`), and from a vector + explicit texture score.
final class FakeEmbedder: FaceEmbedding, @unchecked Sendable {
    var result: FaceEmbeddingResult
    /// ADR-0014: the model this fake claims to implement. Its `version` is what the
    /// recognizer compares stored enrollments against (version-mismatch tests) and its
    /// `defaultMatchThreshold` is the base default when the recognizer is built without an
    /// explicit threshold. Defaults to a stable test descriptor.
    let descriptor: FaceEmbeddingModelDescriptor
    init(result: FaceEmbeddingResult, descriptor: FaceEmbeddingModelDescriptor = .fakeTest) {
        self.result = result
        self.descriptor = descriptor
    }
    /// nil vector → `.noFace`; a vector → `.embedding(vector, high live score)`.
    convenience init(_ vector: [Float]?, descriptor: FaceEmbeddingModelDescriptor = .fakeTest) {
        self.init(result: vector.map { .embedding($0, textureScore: 10_000) } ?? .noFace, descriptor: descriptor)
    }
    /// Map the legacy `FaceEmbeddingOutcome` to the richer result so existing call
    /// sites (`FakeEmbedder(.failure)`) keep compiling.
    convenience init(_ outcome: FaceEmbeddingOutcome) {
        switch outcome {
        case let .embedding(v): self.init(result: .embedding(v, textureScore: 10_000))
        case .noFace: self.init(result: .noFace)
        case .failure: self.init(result: .failure)
        }
    }
    /// Vector + explicit texture score (anti-spoof gating tests).
    convenience init(_ vector: [Float], textureScore: Double) {
        self.init(result: .embedding(vector, textureScore: textureScore))
    }
    func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult { result }
}

extension FaceEmbeddingModelDescriptor {
    /// Stable descriptor for EngineCheck's `FakeEmbedder` (ADR-0014). Its `version` is the
    /// "active model version" the version-mismatch checks compare against.
    static let fakeTest = FaceEmbeddingModelDescriptor(
        version: "fake-test-v1",
        displayName: "Fake test embedder",
        inputSize: 0,
        outputDimension: 4,
        defaultMatchThreshold: 0.6,
        thresholdIsTuned: false
    )
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
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
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
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly, "identity: enrolled + non-matching face → .strangerOnly (EC-03)")
    }

    // (e) enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
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
        try? enrolled.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
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

    // MARK: Embedding versioning + forced re-enrollment (ADR-0014, ND-021) — cooper

    // (v1) VERSION MISMATCH: an enrollment stored under a DIFFERENT model version than the
    // active embedder must NOT be cross-compared (unrelated embedding spaces). The
    // recognizer treats it as NOT enrolled for this model → presence-only fallback, forcing
    // re-enrollment — even with a face that would otherwise mismatch (differentV). If the
    // stale vectors were (wrongly) compared, differentV would score below threshold →
    // .strangerOnly; presence-only proves we skipped the cross-model compare.
    do {
        // Enrolled under an OLD model version; active embedder is `.fakeTest` (v1).
        let store = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0")
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "versioning: stored version != active model → re-enroll required (presence-only), never cross-compare (ADR-0014)")
    }

    // (v2) LEGACY (no-version) record: a pre-versioning enrollment (modelVersion nil) is
    // stale under ANY active versioned model → same forced re-enroll (presence-only),
    // never compared. Uses matchV (which WOULD match) to prove the version gate fires
    // BEFORE the cosine compare.
    do {
        let store = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: nil)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "versioning: legacy no-version record → treated as stale, re-enroll required (ADR-0014)")
    }

    // (v3) VERSION MATCH still recognizes normally: enrolled under the ACTIVE version, a
    // matching face → present; a non-matching face → stranger. Proves the version gate
    // only blocks MISMATCHES, not the normal identity path.
    do {
        let matchStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let rMatch = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: matchStore)
        let matched = await rMatch.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = matched { present = true }
        let strangerStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let rStranger = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: strangerStore)
        let stranger = await rStranger.recognize(CapturedFrame())
        c.expect(present && stranger == .strangerOnly,
                 "versioning: matching active version → normal identity (present / stranger), gate only blocks mismatch (ADR-0014)")
    }

    // (v4) DESCRIPTOR THRESHOLD plumbs through as the base default: build the recognizer
    // WITHOUT an explicit threshold, so it must use the embedder descriptor's
    // `defaultMatchThreshold`. Use a descriptor with a high threshold that a partial match
    // (cos ≈ 0.707) can't clear → stranger; then a descriptor with a low threshold the same
    // score clears → present. Proves descriptor.defaultMatchThreshold drives the decision.
    do {
        let partialV: [Float] = [1, 1, 0, 0]  // cos vs matchV=[1,0,0,0] = 1/sqrt(2) ≈ 0.707
        func desc(_ t: Double) -> FaceEmbeddingModelDescriptor {
            FaceEmbeddingModelDescriptor(version: "fake-test-v1", displayName: "d",
                                         inputSize: 0, outputDimension: 4,
                                         defaultMatchThreshold: t, thresholdIsTuned: false)
        }
        // High descriptor threshold (0.9): 0.707 < 0.9 → stranger.
        let highStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "fake-test-v1")
        let rHigh = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc(0.9)), store: highStore)
        let high = await rHigh.recognize(CapturedFrame())
        // Low descriptor threshold (0.5): 0.707 >= 0.5 → present.
        let lowStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "fake-test-v1")
        let rLow = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc(0.5)), store: lowStore)
        let low = await rLow.recognize(CapturedFrame())
        var presentLow = false
        if case .enrolledUserPresent = low { presentLow = true }
        c.expect(high == .strangerOnly && presentLow,
                 "descriptor threshold: no explicit threshold → descriptor.defaultMatchThreshold drives decision (0.9 → stranger, 0.5 → present) (ADR-0014)")
    }

    // MARK: Anti-spoofing (ND-041, EC-12) + live threshold (ND-040) — cooper/wiggum

    // isLikelySpoof pure-function boundaries: strictly below floor → true; at/above → live.
    do {
        let floor = defaultSpoofTextureFloor
        let belowFlagged = isLikelySpoof(textureScore: floor - 0.01, floor: floor) == true
        let atFloorLive = isLikelySpoof(textureScore: floor, floor: floor) == false           // exactly-at → live
        let aboveLive = isLikelySpoof(textureScore: floor + 0.01, floor: floor) == false
        let zeroFlagged = isLikelySpoof(textureScore: 0, floor: floor) == true
        let hugeLive = isLikelySpoof(textureScore: 10_000, floor: floor) == false
        // .infinity sentinel (embedder returns it when anti-spoof is off / luminance
        // extraction failed) → treated as LIVE, never flagged (FIX #7 / EC-12).
        let infinityLive = isLikelySpoof(textureScore: .infinity, floor: floor) == false
        c.expect(belowFlagged && atFloorLive && aboveLive && zeroFlagged && hugeLive && infinityLive,
                 "isLikelySpoof: < floor → true (spoof); >= floor → false (live); .infinity → live (ND-041)")
    }

    // isLikelySpoof with a RESOLVED floor (FIX #6): a score below the resolved floor →
    // spoof; at/above → live; .infinity → live regardless. Uses a throwaway suite to
    // resolve a custom floor, proving the resolver + isLikelySpoof compose correctly.
    do {
        let suiteName = "com.nodonuts.enginecheck.floorpair.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "spoofTextureFloor"
            suite.set(50.0, forKey: key)
            let floor = resolvedSpoofTextureFloor(defaults: suite, key: key)   // 50.0
            let belowFlagged = isLikelySpoof(textureScore: 49.9, floor: floor) == true
            let atLive = isLikelySpoof(textureScore: 50.0, floor: floor) == false
            let aboveLive = isLikelySpoof(textureScore: 50.1, floor: floor) == false
            let infLive = isLikelySpoof(textureScore: .infinity, floor: floor) == false
            c.expect(floor == 50.0 && belowFlagged && atLive && aboveLive && infLive,
                     "isLikelySpoof + resolved floor (50): below → spoof, at/above → live, .infinity → live (ND-041/FIX#6)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "isLikelySpoof + resolved floor: throwaway suite unavailable, skipped")
        }
    }

    // faceTextureScore pure metric: a flat (uniform) crop scores 0; a high-contrast
    // checkerboard scores well above the floor — the metric actually separates them.
    do {
        let w = 8, h = 8
        let flat = [Double](repeating: 128, count: w * h)  // no texture at all
        var checker = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { checker[y * w + x] = ((x + y) % 2 == 0) ? 0 : 255 } }
        let flatScore = faceTextureScore(luminance: flat, width: w, height: h)
        let checkerScore = faceTextureScore(luminance: checker, width: w, height: h)
        c.expect(flatScore == 0 && checkerScore > defaultSpoofTextureFloor && isLikelySpoof(textureScore: flatScore) && !isLikelySpoof(textureScore: checkerScore),
                 "faceTextureScore: flat crop → 0 (spoof); checkerboard → high (live) (ND-041)")
    }

    // (h) enrolled + matching + LIVE (score above floor) + anti-spoof ON → present.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // High texture score → clearly live.
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10_000), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = result { present = true }
        c.expect(present, "anti-spoof: enrolled + matching + live → present (ND-041)")
    }

    // (i) enrolled + matching + FLAGGED (score below floor) + anti-spoof ON → strangerOnly.
    // Uses a throwaway UserDefaults suite as the SOURCE OF TRUTH by pointing the
    // process default at it — but the recognizer reads `.standard`, so we set the key
    // on `.standard` and restore it, keeping the check hermetic.
    do {
        let key = "antiSpoofEnabled"
        let floorKey = "spoofTextureFloor"
        let hadValue = UserDefaults.standard.object(forKey: key) != nil
        let prior = UserDefaults.standard.object(forKey: key)
        let hadFloor = UserDefaults.standard.object(forKey: floorKey) != nil
        let priorFloor = UserDefaults.standard.object(forKey: floorKey)
        UserDefaults.standard.set(true, forKey: key)          // explicitly ON
        UserDefaults.standard.set(100.0, forKey: floorKey)    // FIX #6: floor via defaults, resolved per call
        defer {
            if hadValue { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            if hadFloor { UserDefaults.standard.set(priorFloor, forKey: floorKey) }
            else { UserDefaults.standard.removeObject(forKey: floorKey) }
        }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // Texture score BELOW the resolved floor (10 < 100) → flagged as spoof. Proves
        // the recognizer uses the LIVE resolved floor, not the hardcoded default.
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly,
                 "anti-spoof: enrolled + matching + flat + enabled (resolved floor 100) → .strangerOnly (ND-041/EC-12/FIX#6)")
    }

    // (j) enrolled + matching + FLAGGED + anti-spoof OFF → present (toggle off ignores).
    do {
        let key = "antiSpoofEnabled"
        let hadValue = UserDefaults.standard.object(forKey: key) != nil
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)   // toggle OFF
        defer {
            if hadValue { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 0), store: store, matchThreshold: threshold)
        let result = await r.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = result { present = true }
        c.expect(present, "anti-spoof: flagged but toggle OFF → present (ignores anti-spoof) (ND-041)")
    }

    // (k) resolvedAntiSpoofEnabled default: absent key → true (ON by default); explicit
    // false → false. Throwaway suite, cleaned up.
    do {
        let suiteName = "com.nodonuts.enginecheck.antispoof.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "antiSpoofEnabled"
            let absentOn = resolvedAntiSpoofEnabled(defaults: suite, key: key) == true
            suite.set(false, forKey: key)
            let explicitOff = resolvedAntiSpoofEnabled(defaults: suite, key: key) == false
            suite.set(true, forKey: key)
            let explicitOn = resolvedAntiSpoofEnabled(defaults: suite, key: key) == true
            c.expect(absentOn && explicitOff && explicitOn,
                     "resolvedAntiSpoofEnabled: absent → ON; false → off; true → on (ND-041)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedAntiSpoofEnabled: throwaway suite unavailable, skipped")
        }
    }

    // (l) LIVE threshold (ND-040): with `matchThreshold` set on defaults, the recognizer
    // resolves it PER CALL. Set a HIGH threshold that even a perfect match can't clear
    // → the enrolled user reads as stranger; then set it back low → present. Proves the
    // init param is only a BASE and the live UserDefaults value wins. Hermetic on
    // `.standard` (recognizer reads `.standard`), save/restore.
    do {
        let key = "matchThreshold"
        let hadValue = UserDefaults.standard.object(forKey: key) != nil
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if hadValue { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // Base default passed at init is lenient (0.6); a perfect self-match = 1.0.
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10_000), store: store, matchThreshold: threshold)
        // Live: set a strict 0.99 → matching vector (cos 1.0) still clears? cos of
        // identical is ~1.0 >= 0.99 → present. Use 0.999999 is > cos rounding; instead
        // prove the LIVE value is consulted by setting a value the base wouldn't give:
        // set threshold ABOVE the actual score by using a different (non-identical) ref.
        UserDefaults.standard.set(0.5, forKey: key)
        let atLow = await r.recognize(CapturedFrame())
        var presentAtLow = false
        if case .enrolledUserPresent = atLow { presentAtLow = true }
        // Now raise to a value the (orthogonal) score can't meet using a different embed.
        let store2 = InMemoryEnrollmentStore()
        try? store2.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // Embed a vector at cosine ~0.7 vs matchV so the threshold is the deciding factor.
        let partialV: [Float] = [1, 1, 0, 0]  // cos(matchV=[1,0,0,0]) = 1/sqrt(2) ≈ 0.707
        let r2 = IdentityRecognizer(embedder: FakeEmbedder(partialV, textureScore: 10_000), store: store2, matchThreshold: threshold)
        UserDefaults.standard.set(0.5, forKey: key)   // 0.707 >= 0.5 → present
        let below = await r2.recognize(CapturedFrame())
        var presentBelow = false
        if case .enrolledUserPresent = below { presentBelow = true }
        UserDefaults.standard.set(0.9, forKey: key)   // 0.707 < 0.9 → stranger (live change applied)
        let above = await r2.recognize(CapturedFrame())
        let strangerAbove = above == .strangerOnly
        c.expect(presentAtLow && presentBelow && strangerAbove,
                 "live threshold: recognizer resolves matchThreshold per call — 0.5 → present, 0.9 → stranger (ND-040)")
    }

    // InMemoryEnrollmentStore round-trip + enrollmentState transitions.
    do {
        let store = InMemoryEnrollmentStore()
        let notEnrolledInitially = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let enrolledAfter = store.isEnrolled && store.enrolledEmbeddings() == [matchV] && isEnrolledState(store.enrollmentState())
        try? store.reset()
        let notEnrolledAfterReset = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        c.expect(notEnrolledInitially && enrolledAfter && notEnrolledAfterReset,
                 "InMemoryEnrollmentStore: enrollmentState notEnrolled → enrolled → reset round-trip")
    }

    // resolvedVisionOrientation fallback (cooper). Uses a throwaway UserDefaults
    // suite (like the TrustedNetworksStore check) so it never touches real prefs.
    // Default (key absent) → .up; out-of-range (99) → .up; valid 6 → .right.
    do {
        let suiteName = "com.nodonuts.enginecheck.orientation.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "visionOrientation"
            // Absent → .up
            let absentUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Out-of-range rawValue → .up
            suite.set(99, forKey: key)
            let outOfRangeUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Zero (invalid rawValue) → .up
            suite.set(0, forKey: key)
            let zeroUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Valid 6 → .right
            suite.set(6, forKey: key)
            let sixRight = resolvedVisionOrientation(defaults: suite, key: key) == .right
            c.expect(absentUp && outOfRangeUp && zeroUp && sixRight,
                     "resolvedVisionOrientation: absent/out-of-range/0 → .up; 6 → .right")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            // Couldn't make a throwaway suite — don't touch .standard; skip cleanly.
            c.expect(true, "resolvedVisionOrientation: throwaway suite unavailable, skipped")
        }
    }

    // resolvedMatchThreshold validation (cooper). Throwaway UserDefaults suite so it
    // never touches real prefs. Absent / <= 0 / >= 1 / non-open values → default;
    // only a number strictly in (0,1) is accepted. Guards against fail-open (0) and
    // permanent-lockout (1.0) overrides.
    do {
        let suiteName = "com.nodonuts.enginecheck.threshold.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "matchThreshold"
            let def = 0.6
            // Absent → default
            let absentDefault = resolvedMatchThreshold(default: def, defaults: suite, key: key) == def
            // 0.0 (fail-open) → default
            suite.set(0.0, forKey: key)
            let zeroDefault = resolvedMatchThreshold(default: def, defaults: suite, key: key) == def
            // Negative → default
            suite.set(-0.5, forKey: key)
            let negativeDefault = resolvedMatchThreshold(default: def, defaults: suite, key: key) == def
            // 1.0 (permanent lockout) → default
            suite.set(1.0, forKey: key)
            let oneDefault = resolvedMatchThreshold(default: def, defaults: suite, key: key) == def
            // 1.5 (above range) → default
            suite.set(1.5, forKey: key)
            let aboveDefault = resolvedMatchThreshold(default: def, defaults: suite, key: key) == def
            // 0.75 (valid, in open interval) → 0.75
            suite.set(0.75, forKey: key)
            let validAccepted = resolvedMatchThreshold(default: def, defaults: suite, key: key) == 0.75
            c.expect(absentDefault && zeroDefault && negativeDefault && oneDefault && aboveDefault && validAccepted,
                     "resolvedMatchThreshold: absent/0/negative/1.0/1.5 → default; 0.75 → 0.75")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            // Couldn't make a throwaway suite — don't touch .standard; skip cleanly.
            c.expect(true, "resolvedMatchThreshold: throwaway suite unavailable, skipped")
        }
    }

    // resolvedSpoofTextureFloor validation (cooper, FIX #6). Throwaway UserDefaults
    // suite so it never touches real prefs. Absent / 0 / negative / NaN / non-numeric
    // → default; only a finite strictly-positive number is accepted. Mirrors the other
    // resolvers; lets the floor be tuned live via `defaults write ... spoofTextureFloor`.
    do {
        let suiteName = "com.nodonuts.enginecheck.spooffloor.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "spoofTextureFloor"
            let def = defaultSpoofTextureFloor   // 12.0
            // Absent → default
            let absentDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // 0.0 → default (a zero floor can never flag; treat as junk)
            suite.set(0.0, forKey: key)
            let zeroDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Negative → default
            suite.set(-5.0, forKey: key)
            let negativeDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // NaN → default
            suite.set(Double.nan, forKey: key)
            let nanDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Infinity → default
            suite.set(Double.infinity, forKey: key)
            let infDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Non-numeric (a stored String) → default
            suite.set("nope", forKey: key)
            let stringDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Valid positive → that value
            suite.set(25.0, forKey: key)
            let validAccepted = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == 25.0
            // Tiny positive (the "effectively disable" escape hatch) → accepted
            suite.set(0.0001, forKey: key)
            let tinyAccepted = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == 0.0001
            c.expect(absentDefault && zeroDefault && negativeDefault && nanDefault && infDefault
                     && stringDefault && validAccepted && tinyAccepted,
                     "resolvedSpoofTextureFloor: absent/0/negative/NaN/inf/non-numeric → default; positive → that (ND-041/FIX#6)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedSpoofTextureFloor: throwaway suite unavailable, skipped")
        }
    }

    // MARK: ND-056 / ND-021 Phase 2 — threshold analysis (ThresholdAnalysis.swift)
    //
    // These back the FaceScore harness's recommendation. A shipped `matchThreshold` is a
    // security parameter, so the arithmetic under it is pinned here.
    do {
        // Percentiles are nearest-rank over SORTED input, and the input need not arrive
        // sorted (FaceScore appends scores in directory order).
        let d = ScoreDistribution([0.9, 0.1, 0.5, 0.7, 0.3])
        let basics = d.count == 5 && d.minimum == 0.1 && d.maximum == 0.9
            && d.sorted == [0.1, 0.3, 0.5, 0.7, 0.9]
        let meanOK = (d.mean.map { abs($0 - 0.5) < 1e-9 }) ?? false
        // Nearest-rank: p50 of 5 samples → index floor(0.5*5)=2 → 0.5.
        let percentileOK = d.percentile(0.5) == 0.5 && d.percentile(0.0) == 0.1 && d.percentile(1.0) == 0.9
        c.expect(basics && meanOK && percentileOK,
                 "ScoreDistribution: sorts unsorted input; min/max/mean/nearest-rank percentiles")

        // Empty → nil everywhere, never a NaN that could be mistaken for a real statistic.
        let empty = ScoreDistribution([])
        c.expect(empty.isEmpty && empty.minimum == nil && empty.maximum == nil
                 && empty.mean == nil && empty.standardDeviation == nil && empty.percentile(0.5) == nil,
                 "ScoreDistribution: empty set → nil statistics (never NaN)")

        // Single sample → spread is undefined, not zero.
        c.expect(ScoreDistribution([0.42]).standardDeviation == nil,
                 "ScoreDistribution: single sample → nil standard deviation")
    }

    do {
        // FRR/FAR must mirror IdentityRecognizer's `maxSim >= threshold` accept test
        // EXACTLY: a score EQUAL to the threshold is accepted, so it is not a false
        // reject, and it IS a false accept. An off-by-one here biases every recommendation.
        let genuine = ScoreDistribution([0.4, 0.5, 0.6])
        let impostor = ScoreDistribution([0.2, 0.5, 0.8])
        let frr = falseRejectRate(genuine: genuine, at: 0.5)
        let far = falseAcceptRate(impostor: impostor, at: 0.5)
        let boundaryOK = (frr.map { abs($0 - 1.0 / 3.0) < 1e-9 }) ?? false
            && (far.map { abs($0 - 2.0 / 3.0) < 1e-9 }) ?? false
        c.expect(boundaryOK, "FRR/FAR: score == threshold is ACCEPTED, matching IdentityRecognizer's >=")

        // Empty class → nil, so a missing class can never read as "0% error".
        c.expect(falseRejectRate(genuine: ScoreDistribution([]), at: 0.5) == nil
                 && falseAcceptRate(impostor: ScoreDistribution([]), at: 0.5) == nil,
                 "FRR/FAR: empty class → nil (never a spurious 0%)")
    }

    do {
        // Genuine-only data — the exact state this project was in before FaceScore —
        // must be refused, not turned into a number.
        let genuineOnly = recommendThreshold(
            genuine: ScoreDistribution([0.88, 0.91, 0.93]),
            impostor: ScoreDistribution([])
        )
        var refusedGenuineOnly = false
        if case .insufficientData = genuineOnly { refusedGenuineOnly = true }
        c.expect(refusedGenuineOnly && !genuineOnly.justifiesTunedFlag,
                 "recommendThreshold: genuine-only data → insufficientData, never a threshold (ND-056)")

        // Clean separation → gap midpoint, and this is the ONLY case allowed to justify
        // flipping a descriptor's `thresholdIsTuned`.
        let separated = recommendThreshold(
            genuine: ScoreDistribution([0.80, 0.90, 0.95]),
            impostor: ScoreDistribution([0.20, 0.40, 0.60])
        )
        var separationOK = false
        if case let .cleanSeparation(threshold, margin, impostorMaximum, genuineMinimum) = separated {
            separationOK = abs(threshold - 0.70) < 1e-9 && abs(margin - 0.20) < 1e-9
                && impostorMaximum == 0.60 && genuineMinimum == 0.80
        }
        c.expect(separationOK && separated.justifiesTunedFlag,
                 "recommendThreshold: clean separation → gap midpoint, justifies thresholdIsTuned")

        // Overlap → report the equal-error point but REFUSE to bless it.
        let overlapping = recommendThreshold(
            genuine: ScoreDistribution([0.30, 0.60, 0.90]),
            impostor: ScoreDistribution([0.25, 0.65, 0.85])
        )
        var overlapOK = false
        if case let .overlap(equalError, _, _) = overlapping {
            overlapOK = equalError > 0.0 && equalError < 1.0
        }
        c.expect(overlapOK && !overlapping.justifiesTunedFlag,
                 "recommendThreshold: overlap → equal-error point reported, tuned flag REFUSED")

        // A single impostor above the genuine floor is enough to deny separation — the
        // conservative direction (one look-alike that matches is the EC-03 failure).
        let oneBadImpostor = recommendThreshold(
            genuine: ScoreDistribution([0.80, 0.90]),
            impostor: ScoreDistribution([0.10, 0.20, 0.85])
        )
        c.expect(!oneBadImpostor.justifiesTunedFlag,
                 "recommendThreshold: one impostor above the genuine floor denies clean separation (EC-03)")
    }

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
