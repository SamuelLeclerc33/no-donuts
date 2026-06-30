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

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
