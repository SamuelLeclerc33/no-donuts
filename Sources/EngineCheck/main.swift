import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
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
    /// `defaultMatchThreshold` is the recognizer's sole default (ND-076). Defaults to a
    /// stable test descriptor.
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
        matchThresholdRange: 0.40...0.90,
        thresholdIsTuned: false
    )

    /// A `.fakeTest`-shaped descriptor with a UNIQUE version, so its per-model override key
    /// (`matchThreshold.<uuid>`) is guaranteed absent from any real defaults domain —
    /// lets recognizer tests that read `.standard` stay hermetic (ND-076).
    static func uniqueFake(defaultMatchThreshold t: Double = 0.6) -> FaceEmbeddingModelDescriptor {
        FaceEmbeddingModelDescriptor(version: "fake-test-\(UUID().uuidString)", displayName: "Fake",
                                     inputSize: 0, outputDimension: 4,
                                     defaultMatchThreshold: t, matchThresholdRange: 0.40...0.90,
                                     thresholdIsTuned: false)
    }
}

/// Synthetic 32-bit BGRA camera-style frame for the shared liveness helper (ND-072):
/// every channel of pixel (x, y) is `luma(x, y)`, so luminance == that value.
func makeGrayBGRAFrame(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> CVPixelBuffer? {
    let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: true]
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let v = luma(x, y)
            let o = y * rowBytes + x * 4
            bytes[o] = v; bytes[o + 1] = v; bytes[o + 2] = v; bytes[o + 3] = 255
        }
    }
    return buffer
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

/// ND-054: locker returning a scripted sequence of results (last one repeats).
final class ScriptedLocker: ScreenLocking, @unchecked Sendable {
    var script: [Bool]
    private(set) var lockCallCount = 0
    init(_ script: [Bool]) { self.script = script }
    @discardableResult
    func lock() async -> Bool {
        let r = script.isEmpty ? false : script[min(lockCallCount, script.count - 1)]
        lockCallCount += 1
        return r
    }
}

/// ND-079: locker whose FIRST lock() suspends until `release(_:)` is called, so a
/// manual lockNow() can be held "in flight" across an auto tick. Later calls
/// return `laterResult` immediately.
@MainActor
final class GatedLocker: ScreenLocking {
    private(set) var lockCallCount = 0
    var laterResult: Bool
    private var gate: CheckedContinuation<Bool, Never>?
    init(laterResult: Bool) { self.laterResult = laterResult }
    var isHeld: Bool { gate != nil }
    @discardableResult
    func lock() async -> Bool {
        lockCallCount += 1
        if lockCallCount == 1 {
            return await withCheckedContinuation { gate = $0 }
        }
        return laterResult
    }
    func release(_ result: Bool) { let g = gate; gate = nil; g?.resume(returning: result) }
}

/// ND-091: camera whose capture() suspends until `release(_:)`, so a tick can be held
/// "in flight" across a pause / session suspend / loop cancellation.
@MainActor
final class GatedCamera: CameraCapturing {
    private var gate: CheckedContinuation<CaptureOutcome, Never>?
    var isHeld: Bool { gate != nil }
    func capture() async -> CaptureOutcome { await withCheckedContinuation { gate = $0 } }
    func release(_ outcome: CaptureOutcome) { let g = gate; gate = nil; g?.resume(returning: outcome) }
}

/// ND-091: recognizer whose recognize() suspends until `release(_:)`.
@MainActor
final class GatedRecognizer: FaceRecognizing {
    private var gate: CheckedContinuation<RecognitionResult, Never>?
    var isHeld: Bool { gate != nil }
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult { await withCheckedContinuation { gate = $0 } }
    func release(_ result: RecognitionResult) { let g = gate; gate = nil; g?.resume(returning: result) }
}

// MARK: - Lock chain fakes (ND-058/ND-074)
//
// SAFETY: these NEVER touch login.framework. Fake resolvers return a dummy non-nil
// pointer that is NEVER dereferenced or called: selfTest() only resolves, and the
// lock() checks inject a recording `invoke` + fake `isLocked` probe. EngineCheck
// must never call the real ScreenLocker().lock() — it would lock this Mac.

/// Dummy, never-called "symbol" address for fake resolvers.
nonisolated(unsafe) let dummySymbol = UnsafeMutableRawPointer(bitPattern: 0x1)!

func fakeResolver(_ names: Set<String>) -> ScreenLocker.SymbolResolver {
    { name in names.contains(name) ? dummySymbol : nil }
}

/// Records invoked mechanisms and flips "locked" once a chosen mechanism is invoked.
final class FakeLockSession: @unchecked Sendable {
    private let q = NSLock()
    private var _invoked: [LockMechanism] = []
    private var _locked = false
    let locksOn: LockMechanism?
    init(locksOn: LockMechanism?) { self.locksOn = locksOn }
    var invoked: [LockMechanism] { q.lock(); defer { q.unlock() }; return _invoked }
    func invoke(_ m: LockMechanism) { q.lock(); _invoked.append(m); if m == locksOn { _locked = true }; q.unlock() }
    func isLocked() -> Bool { q.lock(); defer { q.unlock() }; return _locked }
    func locker(resolving names: Set<String>) -> ScreenLocker {
        ScreenLocker(resolveSymbol: fakeResolver(names),
                     invoke: { [self] m, _ in invoke(m) },   // never calls the pointer
                     isLocked: { [self] in isLocked() },
                     lockTimeout: 0.3)
    }
}

// MARK: - Enrollment capture fakes (ND-063)

/// Fake monotonic clock: `sleep` advances it instantly, so timeouts run without waiting.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
}

/// Camera that serves `frames` in order, each `repeats` times (the ~1 fps camera being
/// polled every 200 ms), then keeps serving the last one. No frames → `.unavailable`.
final class SequenceCamera: CameraCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let frames: [CapturedFrame]
    private let repeats: Int
    private var served = 0
    init(_ frames: [CapturedFrame], repeats: Int = 1) { self.frames = frames; self.repeats = repeats }
    func capture() async -> CaptureOutcome {
        guard !frames.isEmpty else { return .unavailable("no camera (test)") }
        let i: Int = lock.withLock {
            let i = min(served / repeats, frames.count - 1)
            served += 1
            return i
        }
        return .frame(frames[i])
    }
}

/// Embedder keyed by `captureTime`: returns the vector for that time (missing → noFace)
/// and counts how many times it was asked, to prove repeats are never embedded.
final class TimeKeyedEmbedder: FaceEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private let vectors: [TimeInterval: [Float]]
    private var calls = 0
    let descriptor: FaceEmbeddingModelDescriptor = .fakeTest
    init(_ vectors: [TimeInterval: [Float]]) { self.vectors = vectors }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult {
        lock.withLock { calls += 1 }
        guard let t = frame.captureTime, let v = vectors[t] else { return .noFace }
        return .embedding(v, textureScore: 10_000)
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
                _ locker: ScreenLocking, _ config: Config = Config(),
                lid: @escaping @Sendable () -> LidState = { .open }) -> PresenceEngine {
    // Hermetic: never read the real lid via IOKit in checks (ND-078). Default = open.
    PresenceEngine(camera: camera, recognizer: recognizer, locker: locker, config: config,
                   lidState: lid)
}

/// Thread-safe mutable lid flag for ND-078 checks.
final class FakeLid: @unchecked Sendable {
    private let q = NSLock()
    private var _state: LidState
    init(_ state: LidState) { _state = state }
    var state: LidState {
        get { q.lock(); defer { q.unlock() }; return _state }
        set { q.lock(); _state = newValue; q.unlock() }
    }
}

/// ND-091: returns a closure that runs one tick on a GatedCamera, releasing it with `outcome`.
@MainActor
func makeFeeder(_ camera: GatedCamera) -> (PresenceEngine, Date, CaptureOutcome) async -> Void {
    { engine, now, outcome in
        let t = Task { @MainActor in await engine.tick(now: now) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        camera.release(outcome)
        await t.value
    }
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
    /// Scripted recognizer: returns results in order (last one repeats).
    final class SeqRecognizer: FaceRecognizing, @unchecked Sendable {
        var script: [RecognitionResult]; var i = 0
        init(_ s: [RecognitionResult]) { script = s }
        func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
            defer { i += 1 }; return script[min(i, script.count - 1)]
        }
    }
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

    // Lock failure: no fail-open; bounded-backoff retries (ND-054)
    do {
        let config = Config()
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1 && e.lockFailureCount == 1,
                 "lock fails → .lockFailed, lockFailureCount 1 (no fail-open)")
    }

    // ND-054: lockRetryDelay is pure: 10/20/40/60/60…, n<=0 → 10, huge n capped.
    c.expect(lockRetryDelay(afterFailures: 0) == 10 && lockRetryDelay(afterFailures: -3) == 10,
             "lockRetryDelay(n<=0) == 10 (ND-054)")
    c.expect([1, 2, 3, 4, 5, 6].map { lockRetryDelay(afterFailures: $0) } == [10, 20, 40, 60, 60, 60],
             "lockRetryDelay(1...6) == 10/20/40/60/60/60 (ND-054)")
    c.expect(lockRetryDelay(afterFailures: Int.max) == 60, "lockRetryDelay(Int.max) == 60, no overflow (ND-054)")

    // ND-054: first failure → no retry before +10s, retry AT +10s; backoff schedule
    // 10/20/40/60/60 on continued failure; state stays .lockFailed (never .absent).
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        let firstAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 9.9))
        let noEarlyRetry = locker.lockCallCount == 1 && e.state == .lockFailed
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        let retriedAt10 = locker.lockCallCount == 2 && e.lockFailureCount == 2 && e.state == .lockFailed
        c.expect(noEarlyRetry, "failed auto-lock → no retry before +10s (ND-054)")
        c.expect(retriedAt10, "failed auto-lock → retried at +10s, lockFailureCount 2 (ND-054)")

        // Continue 1s ticks and record the times each lock call happens.
        var callTimes: [Double] = [firstAt, firstAt + 10]
        var stayedFailed = true
        var t = firstAt + 10
        while t < firstAt + 10 + 20 + 40 + 60 + 60 + 5 {
            t += 1
            let before = locker.lockCallCount
            await e.tick(now: t0.addingTimeInterval(t))
            if locker.lockCallCount > before { callTimes.append(t) }
            if e.state != .lockFailed { stayedFailed = false }
        }
        let gaps = zip(callTimes.dropFirst(), callTimes).map { $0 - $1 }
        c.expect(gaps == [10, 20, 40, 60, 60], "retry gaps follow 10/20/40/60/60 (ND-054), got \(gaps)")
        c.expect(stayedFailed && e.lockFailureCount == callTimes.count,
                 "retries keep .lockFailed (never clobbered to .absent); lockFailureCount tracks attempts (ND-054)")
    }

    // ND-054: a retry that SUCCEEDS stops retries → .suspended, no further lock calls.
    do {
        let config = Config()
        let locker = ScriptedLocker([false, true])
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        let firstAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))    // retry → success
        let lockedOnRetry = e.state == .suspended && locker.lockCallCount == 2
        for i in 1...200 {
            await e.tick(now: t0.addingTimeInterval(firstAt + 10 + Double(i)))
        }
        c.expect(lockedOnRetry && e.state == .suspended && locker.lockCallCount == 2,
                 "successful retry → .suspended, no further lock calls (ND-054)")
    }

    // ND-054: presence clears episode state — count back to 0, and a new absence
    // gets a fresh full consensus + grace, then a fresh first attempt.
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await driveUntilGraceElapsed(e, config)
        let failedFirst = e.lockFailureCount == 1
        recognizer.result = .enrolledUserPresent(confidence: 1)
        await e.tick(now: t0.addingTimeInterval(500))
        let cleared = e.state == .present && e.lockFailureCount == 0
        recognizer.result = .noFace
        // Within the new episode's grace: no lock even though the old retry time passed.
        for i in 0...config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(600 + Double(i)))
        }
        let noCarryOver = locker.lockCallCount == 1 && e.state == .absent
        await e.tick(now: t0.addingTimeInterval(600 + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(failedFirst && cleared && noCarryOver && locker.lockCallCount == 2 && e.lockFailureCount == 1,
                 "presence clears lock-failure episode state; new absence starts fresh (ND-054)")
    }

    // ND-054: a failed MANUAL lockNow() while present does not start retries or
    // count toward lockFailureCount.
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.lockNow()
        for i in 0..<120 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 1 && e.lockFailureCount == 0 && e.state == .present,
                 "failed manual lockNow while present → no retries, not counted (ND-054)")
    }

    // ND-079: a manual lockNow() still in flight at grace expiry → the auto path
    // skips WITHOUT recording an attempt; after the manual lock fails, the auto
    // path attempts on the very next tick.
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let manual = Task { @MainActor in await e.lockNow() }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        let held = locker.isHeld && locker.lockCallCount == 1
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(graceAt))         // auto path: manual in flight
        let skippedUnrecorded = locker.lockCallCount == 1 && e.lockFailureCount == 0
        locker.release(false)                                      // manual lock fails
        await manual.value
        let manualFailed = e.state == .lockFailed
        await e.tick(now: t0.addingTimeInterval(graceAt + 1))     // next tick → auto attempt
        c.expect(held && skippedUnrecorded, "manual lock in flight at grace expiry → auto skip not recorded (ND-079)")
        c.expect(manualFailed && locker.lockCallCount == 2 && e.state == .suspended,
                 "manual lock failed → auto path attempts on the next tick (ND-079)")
    }

    // ND-054: the busy-cap escalation path (ND-033) retries on the same backoff.
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.cameraBusyNoFrames), StubRecognizer(.noFace), locker, config)
        await e.tick(now: t0)
        let base = config.maxCallAssumedPresentSeconds
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        let firstAt = base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt))
        await e.tick(now: t0.addingTimeInterval(firstAt + 5))
        let noEarly = locker.lockCallCount == 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        c.expect(noEarly && locker.lockCallCount == 2 && e.state == .lockFailed,
                 "busy-cap escalation: failed lock retried at +10s, not before (ND-054/ND-033)")
    }

    // ND-054: an episode reset DURING an in-flight auto-lock (e.g. the session
    // suspend caused by that very lock) must not leak lockSucceeded into the next
    // episode — the next absence must still be able to lock.
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        let autoTick = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(graceAt)) }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        e.sessionSuspended()               // the lock "took" → OS session suspend mid-await
        locker.release(true)
        await autoTick.value
        let base = graceAt + 100
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(locker.lockCallCount == 2 && e.state == .suspended,
                 "reset during in-flight auto-lock doesn't leak into next episode; next absence locks (ND-054)")
    }

    // ND-054 review fix: a pause DURING an in-flight auto-lock that then FAILS must
    // not clobber .paused with .lockFailed (that would raise a false "will keep
    // retrying" alarm while the loop is stopped).
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        let autoTick = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(graceAt)) }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        e.pause()
        locker.release(false)
        await autoTick.value
        c.expect(e.state == .paused && e.lockFailureCount == 0,
                 "pause during in-flight auto-lock that fails → stays .paused, no failure recorded (ND-054)")
    }

    // ND-061 review fix: stranger, stranger, error×3 (escalated), stranger → still
    // fast-locks on the 3rd stranger reading (escalated errors hold the streak).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.strangerOnly)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(1))
        recognizer.result = .error("blur")
        for i in 0..<config.maxConsecutiveErrorsBeforeAbsent {
            await e.tick(now: t0.addingTimeInterval(2 + Double(i)))
        }
        c.expect(locker.lockCallCount == 0, "escalated errors between strangers don't lock by themselves (ND-061)")
        recognizer.result = .strangerOnly
        await e.tick(now: t0.addingTimeInterval(2 + Double(config.maxConsecutiveErrorsBeforeAbsent)))
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "escalated error ticks hold the stranger streak → 3rd stranger fast-locks (ND-061)")
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

    // TrustedNetworksStore (ND-036 → ND-081): trust = SSID + default-gateway MAC.
    // Backed by throwaway UserDefaults suites (unique names) so nothing touches real
    // prefs. Fail-safe matrix: only SSID match + MAC match → trusted.
    do {
        func makeSuite() -> (UserDefaults, String)? {
            let name = "com.nodonuts.enginecheck.\(UUID().uuidString)"
            return UserDefaults(suiteName: name).map { ($0, name) }
        }
        let macA = "bc:df:58:e2:de:5f"
        let macB = "a4:2b:b0:01:02:03"
        if let (suite, name) = makeSuite() {
            let store = TrustedNetworksStore(defaults: suite)
            c.expect(!store.isTrusted(ssid: nil, gatewayMAC: nil)
                     && !store.isTrusted(ssid: "", gatewayMAC: macA)
                     && !store.isTrusted(ssid: "Home", gatewayMAC: macA),
                     "ND-081: empty store / nil or empty SSID → not trusted")
            c.expect(!store.trust(ssid: "Home", gatewayMAC: nil)
                     && !store.trust(ssid: "Home", gatewayMAC: "00:00:00:00:00:00")
                     && !store.trust(ssid: "Home", gatewayMAC: "not-a-mac")
                     && !store.trust(ssid: "", gatewayMAC: macA)
                     && store.count == 0,
                     "ND-081: trust() refuses without an SSID and a valid router MAC (nothing stored)")
            let added = store.trust(ssid: "Home", gatewayMAC: macA.uppercased())
            c.expect(added && store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.isTrusted(ssid: "Home", gatewayMAC: "BC-DF-58-E2-DE-5F"),
                     "ND-081: SSID match + MAC match → trusted (MAC case/separator normalized)")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: macB),
                     "ND-081: SSID match + MAC MISMATCH (hotspot copying the SSID) → NOT trusted")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: nil)
                     && !store.isTrusted(ssid: "Home", gatewayMAC: "garbage"),
                     "ND-081: SSID match + router MAC unreadable/invalid → NOT trusted (fail-safe)")
            c.expect(!store.isTrusted(ssid: "Other", gatewayMAC: macA) && !store.isTrusted(ssid: "home", gatewayMAC: macA),
                     "ND-081: router MAC match on a different SSID → NOT trusted")
            c.expect(store.status(ssid: "Home", gatewayMAC: macA) == .trusted
                     && store.status(ssid: "Home", gatewayMAC: macB) == .otherRouter
                     && store.status(ssid: "Home", gatewayMAC: nil) == .otherRouter
                     && store.status(ssid: "Other", gatewayMAC: macA) == .notTrusted
                     && store.status(ssid: nil, gatewayMAC: macA) == .notTrusted,
                     "ND-081: status(): trusted / otherRouter / notTrusted for the menu label")
            store.trust(ssid: "Home", gatewayMAC: macB)
            let bothRouters = store.isTrusted(ssid: "Home", gatewayMAC: macA)
                && store.isTrusted(ssid: "Home", gatewayMAC: macB) && store.count == 2
            store.untrust(ssid: "Home", gatewayMAC: macA)
            c.expect(bothRouters && !store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.isTrusted(ssid: "Home", gatewayMAC: macB) && store.count == 1,
                     "ND-081: one SSID can be trusted on several routers; untrust removes only this router")
            store.remove(TrustedNetwork(ssid: "Home", gatewayMAC: macB))
            c.expect(store.count == 0 && !store.isTrusted(ssid: "Home", gatewayMAC: macB),
                     "ND-081: remove(entry) (Settings) drops that SSID + router")
            // A hand-edited entry with an invalid MAC decodes as legacy → never trusted.
            suite.set([["ssid": "Edited", "gatewayMAC": "zz:zz"]], forKey: "trustedWiFiNetworks")
            c.expect(!store.isTrusted(ssid: "Edited", gatewayMAC: "zz:zz")
                     && store.status(ssid: "Edited", gatewayMAC: macA) == .needsReTrust,
                     "ND-081: stored entry with an invalid MAC → legacy (needs re-trust), not trusted")
            UserDefaults.standard.removePersistentDomain(forName: name)
        } else {
            c.expect(false, "ND-081: could not create a throwaway UserDefaults suite")
        }

        // Migration: the pre-ND-081 SSID-only list becomes legacy entries that need a
        // re-confirm. They are NOT auto-bound to the router present at upgrade time.
        if let (suite, name) = makeSuite() {
            suite.set(["Home", "Cafe", "Work", ""], forKey: "trustedWiFiSSIDs")
            suite.set([["ssid": "Work", "gatewayMAC": macB]], forKey: "trustedWiFiNetworks")
            let store = TrustedNetworksStore(defaults: suite)
            let entries = store.all()
            let legacySSIDs = entries.filter(\.needsReTrust).map(\.ssid)
            c.expect(legacySSIDs == ["Cafe", "Home"] && entries.count == 3
                     && suite.object(forKey: "trustedWiFiSSIDs") == nil,
                     "ND-081 migration: SSID-only entries → legacy (needs re-trust); old key removed; no dup for an already-bound SSID; empty dropped")
            c.expect(!store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.status(ssid: "Home", gatewayMAC: macA) == .needsReTrust
                     && store.needsReTrustCount == 2,
                     "ND-081 migration: a legacy entry is NOT trusted on any router (enforcement stays on)")
            c.expect(store.isTrusted(ssid: "Work", gatewayMAC: macB),
                     "ND-081 migration: an already-bound entry keeps working")
            store.trust(ssid: "Home", gatewayMAC: macA)
            c.expect(store.isTrusted(ssid: "Home", gatewayMAC: macA)
                     && store.status(ssid: "Home", gatewayMAC: macA) == .trusted
                     && store.needsReTrustCount == 1 && store.count == 3,
                     "ND-081 migration: re-confirming binds the legacy entry to this router (replaces it)")
            let again = TrustedNetworksStore(defaults: suite).all()
            c.expect(again == store.all(), "ND-081 migration: idempotent across store instances")
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    // RouterReadCache (ND-081 review): trust needs a FRESH read. A cached MAC for a
    // cloneable key must not survive an invalidation (poll / wake / Wi-Fi event).
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = "en0|Home|aa:bb:cc:dd:ee:01"
        var cache = RouterReadCache(freshnessLimit: 25, negativeLifetime: 30)
        c.expect(cache.lookup(key: key, now: t0) == .none, "ND-081 cache: empty → none (read needed, not trusted)")
        let gen = cache.generation
        cache.record(key: key, generation: gen, mac: "bc:df:58:e2:de:5f", now: t0)
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(10)) == .fresh("bc:df:58:e2:de:5f"),
                 "ND-081 cache: read in the current generation → fresh")
        c.expect(cache.lookup(key: "en0|Other|x", now: t0) == .none,
                 "ND-081 cache: different key → none")
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(26)) == .none,
                 "ND-081 cache: older than the freshness limit → not fresh (backstop)")
        cache.invalidate(clearFailures: false)   // e.g. 15 s poll or wake
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(1)) == .none,
                 "ND-081 cache: SAME key after an invalidation → not fresh (evil twin can clone the key)")
        c.expect(!cache.record(key: key, generation: gen, mac: "bc:df:58:e2:de:5f", now: t0.addingTimeInterval(2))
                 && cache.lookup(key: key, now: t0.addingTimeInterval(2)) == .none,
                 "ND-081 cache: a read STARTED before the invalidation is discarded when it lands")
        cache.record(key: key, generation: cache.generation, mac: nil, now: t0.addingTimeInterval(3))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(20)) == .recentlyFailed
                 && cache.lookup(key: key, now: t0.addingTimeInterval(34)) == .none,
                 "ND-081 cache: failed read negative-cached for 30 s, then retried")
        cache.invalidate(clearFailures: false)
        let keptAcrossPoll = cache.lookup(key: key, now: t0.addingTimeInterval(5)) == .recentlyFailed
        cache.invalidate(clearFailures: true)    // Wi-Fi event / wake / Trust click
        c.expect(keptAcrossPoll && cache.lookup(key: key, now: t0.addingTimeInterval(5)) == .none,
                 "ND-081 cache: poll keeps the negative cache; events/wake clear it")
        cache.record(key: key, generation: cache.generation, mac: "bc:df:58:e2:de:5f", now: t0.addingTimeInterval(6))
        cache.record(key: key, generation: cache.generation, mac: nil, now: t0.addingTimeInterval(7))
        c.expect(cache.lookup(key: key, now: t0.addingTimeInterval(8)) == .recentlyFailed,
                 "ND-081 cache: a later failure for the key drops the verified MAC")
    }

    // Gateway MAC parsing (ND-081): MAC normalization, sysctl routing/ARP dumps built
    // from the real Darwin `rt_msghdr` layout, and the route(8)/arp(8) text fallbacks.
    do {
        c.expect(MACAddress.normalize("bc:df:58:e2:de:5f") == "bc:df:58:e2:de:5f"
                 && MACAddress.normalize("A4:2B:B0:1:2:3") == "a4:2b:b0:01:02:03"
                 && MACAddress.normalize(" a4-2b-b0-01-02-03\n") == "a4:2b:b0:01:02:03",
                 "ND-081: MAC normalize: case, 1-digit octets, '-' separators")
        c.expect(MACAddress.normalize("00:00:00:00:00:00") == nil
                 && MACAddress.normalize("ff:ff:ff:ff:ff:ff") == nil
                 && MACAddress.normalize("(incomplete)") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02:0g") == nil
                 && MACAddress.normalize("a4:2b:b0:01:02:003") == nil
                 && MACAddress.normalize("") == nil,
                 "ND-081: MAC normalize rejects zero/broadcast/incomplete/short/non-hex")
        c.expect(MACAddress.format([0xbc, 0xdf, 0x58, 0xe2, 0xde, 0x5f]) == "bc:df:58:e2:de:5f"
                 && MACAddress.format([]) == nil && MACAddress.format([1, 2, 3]) == nil,
                 "ND-081: MAC format from bytes (6 bytes only)")

        func pad4(_ b: [UInt8]) -> [UInt8] {
            let n = b.isEmpty ? 4 : 1 + ((b.count - 1) | 3)
            return b + [UInt8](repeating: 0, count: n - b.count)
        }
        func sin(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
            [16, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
        }
        /// Truncated netmask as the kernel writes it (sa_len covers the non-zero bytes).
        func mask(_ bytes: [UInt8]) -> [UInt8] {
            bytes.isEmpty ? [] : [UInt8(4 + bytes.count), 0xff, 0, 0] + bytes
        }
        func sdl(index: UInt16, name: String = "", mac: [UInt8]) -> [UInt8] {
            let n = Array(name.utf8)
            var b: [UInt8] = [0, UInt8(AF_LINK), UInt8(index & 0xff), UInt8(index >> 8),
                              6 /* IFT_ETHER */, UInt8(n.count), UInt8(mac.count), 0] + n + mac
            if b.count < 20 { b += [UInt8](repeating: 0, count: 20 - b.count) }
            b[0] = UInt8(b.count)
            return b
        }
        /// One routing message: real `rt_msghdr` bytes + sockaddrs in RTA bit order.
        func msg(flags: Int32, index: UInt16, dst: [UInt8]?, gw: [UInt8]?, netmask: [UInt8]?,
                 version: UInt8 = UInt8(RTM_VERSION)) -> [UInt8] {
            var addrs: Int32 = 0
            var body: [UInt8] = []
            if let dst { addrs |= RTA_DST; body += pad4(dst) }
            if let gw { addrs |= RTA_GATEWAY; body += pad4(gw) }
            if let netmask { addrs |= RTA_NETMASK; body += pad4(netmask) }
            var h = rt_msghdr()
            h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
            h.rtm_version = version
            h.rtm_type = UInt8(RTM_GET)
            h.rtm_index = index
            h.rtm_flags = flags
            h.rtm_addrs = addrs
            return withUnsafeBytes(of: &h) { Array($0) } + body
        }
        let en0: UInt16 = 15, utun: UInt16 = 20
        let upGw = RTF_UP | RTF_GATEWAY
        let routes: [UInt8] =
            // 10.1.0.0/16 via 192.168.86.254 on en0: a gateway route, but not the default.
            msg(flags: upGw, index: en0, dst: sin(10, 1, 0, 0), gw: sin(192, 168, 86, 254), netmask: mask([255, 255]))
            // VPN full-tunnel default on utun: must NOT be taken for the Wi-Fi router.
            + msg(flags: upGw | RTF_STATIC, index: utun, dst: sin(0, 0, 0, 0), gw: sin(10, 0, 0, 1), netmask: mask([]))
            // Wrong rtm_version: skipped.
            + msg(flags: upGw, index: en0, dst: sin(0, 0, 0, 0), gw: sin(6, 6, 6, 6), netmask: mask([]), version: 99)
            // Scoped default on en0, then the unscoped one (preferred).
            + msg(flags: upGw | RTF_IFSCOPE, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 2), netmask: mask([]))
            + msg(flags: upGw | RTF_STATIC, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 1), netmask: mask([]))
        let parsed = GatewayRouteParser.parse(routes)
        c.expect(parsed.count == 4 && parsed.first?.netmask == .inet("255.255.0.0")
                 && parsed.first?.destination == .inet("10.1.0.0"),
                 "ND-081: route dump decodes rt_msghdr + padded sockaddrs (bad version skipped)")
        c.expect(GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: en0) == "192.168.86.1",
                 "ND-081: default gateway on the Wi-Fi interface (unscoped preferred; /16 route ignored)")
        c.expect(GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: utun) == "10.0.0.1"
                 && GatewayRouteParser.defaultGateway(in: parsed, interfaceIndex: 99) == nil,
                 "ND-081: default gateway is per-interface (a VPN's default isn't Wi-Fi's); none → nil")
        let scopedOnly = GatewayRouteParser.parse(
            msg(flags: upGw | RTF_IFSCOPE, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 2), netmask: mask([])))
        let downRoute = GatewayRouteParser.parse(
            msg(flags: RTF_GATEWAY, index: en0, dst: sin(0, 0, 0, 0), gw: sin(192, 168, 86, 1), netmask: mask([])))
        c.expect(GatewayRouteParser.defaultGateway(in: scopedOnly, interfaceIndex: en0) == "192.168.86.2"
                 && GatewayRouteParser.defaultGateway(in: downRoute, interfaceIndex: en0) == nil,
                 "ND-081: scoped-only default is used; a route that isn't UP is not")
        let truncated = Array(routes.prefix(routes.count - 3))
        c.expect(GatewayRouteParser.parse([]).isEmpty && GatewayRouteParser.parse([1, 2, 3]).isEmpty
                 && GatewayRouteParser.parse(truncated).count == 3,
                 "ND-081: empty / short / truncated buffers parse safely (overrunning message dropped)")

        let router: [UInt8] = [0xbc, 0xdf, 0x58, 0xe2, 0xde, 0x5f]
        let arp: [UInt8] =
            // Same IP on another interface first (different MAC): must be skipped for en0.
            msg(flags: RTF_UP | RTF_LLINFO, index: utun, dst: sin(192, 168, 86, 1), gw: sdl(index: utun, mac: [2, 0, 0, 0, 0, 9]), netmask: nil)
            + msg(flags: RTF_UP | RTF_LLINFO, index: en0, dst: sin(192, 168, 86, 7), gw: sdl(index: en0, mac: []), netmask: nil)
            + msg(flags: RTF_UP | RTF_LLINFO, index: en0, dst: sin(192, 168, 86, 1), gw: sdl(index: en0, name: "en0", mac: router), netmask: nil)
        let arpParsed = GatewayRouteParser.parse(arp)
        c.expect(GatewayRouteParser.linkAddress(for: "192.168.86.1", in: arpParsed, interfaceIndex: en0) == "bc:df:58:e2:de:5f",
                 "ND-081: ARP dump → gateway MAC on the Wi-Fi interface (sockaddr_dl, name skipped)")
        c.expect(GatewayRouteParser.linkAddress(for: "192.168.86.7", in: arpParsed, interfaceIndex: en0) == nil
                 && GatewayRouteParser.linkAddress(for: "192.168.86.99", in: arpParsed, interfaceIndex: en0) == nil,
                 "ND-081: incomplete / missing ARP entry → nil (not trusted)")

        let routeGet = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.86.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        c.expect(GatewayRouteParser.parseRouteGetDefault(routeGet, interfaceName: "en0") == "192.168.86.1"
                 && GatewayRouteParser.parseRouteGetDefault(routeGet, interfaceName: "en1") == nil
                 && GatewayRouteParser.parseRouteGetDefault("route: writing to routing socket: not in table", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseRouteGetDefault("gateway: fe80::1\ninterface: en0", interfaceName: "en0") == nil,
                 "ND-081: route(8) fallback: gateway only when the default is on the Wi-Fi interface")
        c.expect(GatewayRouteParser.parseArpOutput("? (192.168.86.1) at bc:df:58:e2:de:5f on en0 ifscope [ethernet]\n",
                                                   ip: "192.168.86.1", interfaceName: "en0") == "bc:df:58:e2:de:5f"
                 && GatewayRouteParser.parseArpOutput("? (10.0.0.1) at a4:2b:b0:1:2:3 on en0 [ethernet]",
                                                      ip: "10.0.0.1", interfaceName: "en0") == "a4:2b:b0:01:02:03",
                 "ND-081: arp(8) fallback: MAC parsed and normalized")
        c.expect(GatewayRouteParser.parseArpOutput("? (192.168.86.1) at (incomplete) on en0 ifscope [ethernet]",
                                                   ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("192.168.86.1 (192.168.86.1) -- no entry",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("? (192.168.86.1) at bc:df:58:e2:de:5f on en7 [ethernet]",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil
                 && GatewayRouteParser.parseArpOutput("? (192.168.86.10) at bc:df:58:e2:de:5f on en0 [ethernet]",
                                                      ip: "192.168.86.1", interfaceName: "en0") == nil,
                 "ND-081: arp(8) fallback: incomplete / no entry / other interface / other IP → nil")
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
    let threshold = FaceEmbeddingModelDescriptor.fakeTest.defaultMatchThreshold

    // (a) not enrolled + embedder returns a vector → present (presence-only fallback).
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "identity: not enrolled + face → present (presence-only fallback)")
    }

    // (b) not enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: not enrolled + no face → .noFace")
    }

    // (c) enrolled with V, embedder returns V → present, confidence >= threshold.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
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
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly, "identity: enrolled + non-matching face → .strangerOnly (EC-03)")
    }

    // (e) enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: enrolled + no face → .noFace")
    }

    // (f) FAIL-SAFE: embedder .failure → .error (EC-10 hold), NOT .noFace/absence —
    // both when enrolled and when not enrolled. A transient Vision glitch must not
    // count toward the absence consensus and lock a present user.
    do {
        let notEnrolled = InMemoryEnrollmentStore()
        let r1 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: notEnrolled)
        let res1 = await r1.recognize(CapturedFrame())
        let enrolled = InMemoryEnrollmentStore()
        try? enrolled.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r2 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: enrolled)
        let res2 = await r2.recognize(CapturedFrame())
        c.expect(res1 == .error("face embedding failed") && res2 == .error("face embedding failed"),
                 "identity: embedder .failure → .error (EC-10 hold), never absence")
    }

    // (g) FAIL-SAFE (S1): store .unavailable (Keychain read failed) → .error even with a
    // face present — MUST NOT drop to presence-only (which would let any stranger pass).
    do {
        let store = InMemoryEnrollmentStore(embeddings: [matchV], simulateUnavailable: true)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
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
                                         defaultMatchThreshold: t, matchThresholdRange: 0.40...0.90,
                                         thresholdIsTuned: false)
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

    // MARK: Identity status surfacing (ND-073) — cooper

    // (s1) Pure status table: every branch, including the nil legacy version and a marker
    // alongside a matching enrollment (still .active — the marker never downgrades).
    do {
        let active = FaceEmbeddingModelDescriptor.fakeTest.version
        let t1 = identityStatus(for: .enrolled([matchV], modelVersion: active), activeVersion: active, markerVersion: nil) == .active
        let t2 = identityStatus(for: .enrolled([matchV], modelVersion: active), activeVersion: active, markerVersion: active) == .active
        let t3 = identityStatus(for: .enrolled([matchV], modelVersion: "old-v0"), activeVersion: active, markerVersion: "old-v0")
            == .off(.modelMismatch(stored: "old-v0", active: active))
        let t4 = identityStatus(for: .enrolled([matchV], modelVersion: nil), activeVersion: active, markerVersion: nil)
            == .off(.modelMismatch(stored: nil, active: active))
        let t5 = identityStatus(for: .notEnrolled, activeVersion: active, markerVersion: nil) == .notEnrolled
        let t6 = identityStatus(for: .notEnrolled, activeVersion: active, markerVersion: active)
            == .off(.enrollmentMissing(expected: active))
        let t7 = identityStatus(for: .unavailable, activeVersion: active, markerVersion: active) == .unknown
        c.expect(t1 && t2, "identityStatus: enrolled + matching version → .active (marker irrelevant) (ND-073)")
        c.expect(t3, "identityStatus: enrolled + different version → .off(.modelMismatch) (ND-073)")
        c.expect(t4, "identityStatus: legacy nil-version record → .off(.modelMismatch(stored: nil)) (ND-073)")
        c.expect(t5, "identityStatus: not enrolled + no marker → .notEnrolled (ND-073)")
        c.expect(t6, "identityStatus: not enrolled + marker → .off(.enrollmentMissing) (ND-073)")
        c.expect(t7, "identityStatus: store .unavailable → .unknown (ND-073)")
        let flags = IdentityStatus.active.hasStoredEnrollment
            && IdentityStatus.off(.modelMismatch(stored: nil, active: active)).hasStoredEnrollment
            && !IdentityStatus.off(.enrollmentMissing(expected: active)).hasStoredEnrollment
            && !IdentityStatus.notEnrolled.hasStoredEnrollment && !IdentityStatus.unknown.hasStoredEnrollment
            && IdentityStatus.off(.enrollmentMissing(expected: active)).isOff
            && !IdentityStatus.active.isOff && !IdentityStatus.unknown.isOff
        c.expect(flags, "IdentityStatus: isOff / hasStoredEnrollment convenience flags (ND-073)")
    }

    // (s2) Recognizer publishes status from its per-tick read; results unchanged.
    do {
        let active = FaceEmbeddingModelDescriptor.fakeTest.version
        // Initial status before any tick.
        let fresh = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: InMemoryEnrollmentStore())
        c.expect(fresh.lastIdentityStatus == .unknown, "recognizer status: initial value .unknown (ND-073)")

        // Mismatch → .off(.modelMismatch), result still presence-only.
        let mm = IdentityRecognizer(embedder: FakeEmbedder(differentV),
                                    store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0"))
        let mmRes = await mm.recognize(CapturedFrame())
        c.expect(mm.lastIdentityStatus == .off(.modelMismatch(stored: "old-model-v0", active: active))
                    && mmRes == .enrolledUserPresent(confidence: 1.0),
                 "recognizer status: version mismatch → .off(.modelMismatch), result still presence-only (ND-073)")

        // Match → .active.
        let ok = IdentityRecognizer(embedder: FakeEmbedder(matchV),
                                    store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: active),
                                    marker: InMemoryEnrollmentMarker(active))
        _ = await ok.recognize(CapturedFrame())
        c.expect(ok.lastIdentityStatus == .active, "recognizer status: matching version → .active (ND-073)")

        // Marker + empty store → .off(.enrollmentMissing), result still presence-only.
        let missing = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: InMemoryEnrollmentStore(),
                                         marker: InMemoryEnrollmentMarker(active))
        let missRes = await missing.recognize(CapturedFrame())
        c.expect(missing.lastIdentityStatus == .off(.enrollmentMissing(expected: active))
                    && missRes == .enrolledUserPresent(confidence: 1.0),
                 "recognizer status: marker + empty store → .off(.enrollmentMissing), result still presence-only (ND-073)")

        // Status updates even when the embed yields no face (it comes from the store read).
        let noFace = IdentityRecognizer(embedder: FakeEmbedder(nil),
                                        store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: active))
        _ = await noFace.recognize(CapturedFrame())
        c.expect(noFace.lastIdentityStatus == .active, "recognizer status: published from store read even on .noFace (ND-073)")

        // .unavailable keeps the previous status (no flapping), result still .error.
        let flaky = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0")
        let fr = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: flaky)
        _ = await fr.recognize(CapturedFrame())
        flaky.setSimulateUnavailable(true)
        let frRes = await fr.recognize(CapturedFrame())
        c.expect(fr.lastIdentityStatus == .off(.modelMismatch(stored: "old-model-v0", active: active))
                    && frRes == .error("enrollment store unavailable"),
                 "recognizer status: store .unavailable keeps previous status (no flap), result .error (ND-073)")
    }

    // (s3) Marker round-trip (in-memory + UserDefaults on an isolated suite).
    do {
        let m = InMemoryEnrollmentMarker()
        let start = m.markerVersion == nil
        m.setMarker("v-a")
        let afterSet = m.markerVersion == "v-a"
        m.setMarker("v-b")
        let overwritten = m.markerVersion == "v-b"
        m.clearMarker()
        c.expect(start && afterSet && overwritten && m.markerVersion == nil,
                 "InMemoryEnrollmentMarker: nil → set → overwrite → clear round-trip (ND-073)")

        let suite = "com.nodonuts.enginecheck.marker"
        if let d = UserDefaults(suiteName: suite) {
            d.removePersistentDomain(forName: suite)
            let ud = UserDefaultsEnrollmentMarker(defaults: d)
            let s0 = ud.markerVersion == nil
            ud.setMarker("v-x")
            let s1 = ud.markerVersion == "v-x" && d.string(forKey: "enrollmentMarkerModelVersion") == "v-x"
            ud.clearMarker()
            c.expect(s0 && s1 && ud.markerVersion == nil,
                     "UserDefaultsEnrollmentMarker: set/clear round-trip under key enrollmentMarkerModelVersion (ND-073)")
            d.removePersistentDomain(forName: suite)
        } else {
            c.expect(false, "UserDefaultsEnrollmentMarker: isolated suite available")
        }
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
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10_000), store: store)
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
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10), store: store)
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
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 0), store: store)
        let result = await r.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = result { present = true }
        c.expect(present, "anti-spoof: flagged but toggle OFF → present (ignores anti-spoof) (ND-041)")
    }

    // MARK: Shared inner-face liveness helper (ND-072, EC-12) — cooper/wiggum
    //
    // Both embedders now score liveness through ONE helper on the ORIGINAL frame's inner
    // face region. Synthetic BGRA frames (160×160, face box = central half → 120px padded
    // crop, 80px core: below the 128px working size, so no resample blurs the pattern).
    do {
        let side = 160
        let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let ctx = CIContext(options: nil)
        var seed: UInt32 = 0x9E37_79B9
        func noise() -> UInt8 { seed = seed &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: seed >> 24) }
        let flat = makeGrayBGRAFrame(width: side, height: side) { _, _ in 128 }
        let checker = makeGrayBGRAFrame(width: side, height: side) { x, y in ((x / 3 + y / 3) % 2 == 0) ? 30 : 220 }
        let noisy = makeGrayBGRAFrame(width: side, height: side) { _, _ in noise() }

        if let flat, let checker, let noisy {
            let flatScore = innerFaceTextureScore(frame: flat, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            let checkerScore = innerFaceTextureScore(frame: checker, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            let noiseScore = innerFaceTextureScore(frame: noisy, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            c.expect(flatScore.isFinite && isLikelySpoof(textureScore: flatScore),
                     "innerFaceTextureScore: flat frame → low finite score (\(flatScore)) → spoof at default floor (ND-072)")
            c.expect(checkerScore.isFinite && checkerScore > defaultSpoofTextureFloor * 10,
                     "innerFaceTextureScore: checkerboard frame → high score (\(checkerScore)) → live (ND-072)")
            c.expect(noiseScore.isFinite && noiseScore > defaultSpoofTextureFloor * 10,
                     "innerFaceTextureScore: noise frame → high score (\(noiseScore)) → live (ND-072)")

            // Rotated source orientation (same one detection used) still extracts + scores.
            let rotated = innerFaceTextureScore(frame: checker, faceBoundingBox: face, orientation: .right, ciContext: ctx)
            c.expect(rotated.isFinite && rotated > defaultSpoofTextureFloor,
                     "innerFaceTextureScore: non-.up orientation → still scores the face region (ND-072)")

            // Same pixels as the Vision path: the frame-based helper == the Vision
            // embedder's call (faceCoreTextureScore on its rendered padded crop). This is
            // what keeps the floor on one scale across both embedders.
            var samePixels = false
            let ci = CIImage(cvPixelBuffer: noisy).oriented(.up)
            if let rect = paddedFaceCropRect(faceBoundingBox: face, paddingFraction: 0.25, orientedExtent: ci.extent),
               let cg = ctx.createCGImage(ci.cropped(to: rect), from: rect),
               let visionPath = faceCoreTextureScore(paddedCrop: cg, paddingFraction: 0.25) {
                samePixels = visionPath == noiseScore
            }
            c.expect(samePixels, "innerFaceTextureScore == Vision-path faceCoreTextureScore on the same frame (one scale, ND-072)")

            // Extraction failures / ambiguity → .infinity (LIVE), never a spoof (EC-12).
            let zeroBox = innerFaceTextureScore(frame: flat, faceBoundingBox: .zero, orientation: .up, ciContext: ctx)
            let nanBox = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: .nan, y: 0.2, width: 0.5, height: 0.5),
                                               orientation: .up, ciContext: ctx)
            let offFrame = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: 2, y: 2, width: 0.5, height: 0.5),
                                                 orientation: .up, ciContext: ctx)
            let tiny = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: 0.5, y: 0.5, width: 0.004, height: 0.004),
                                             orientation: .up, ciContext: ctx)
            let badPad = innerFaceTextureScore(frame: flat, faceBoundingBox: face, orientation: .up,
                                               paddingFraction: -1, ciContext: ctx)
            c.expect(zeroBox == .infinity && nanBox == .infinity && offFrame == .infinity && tiny == .infinity && badPad == .infinity,
                     "innerFaceTextureScore: empty/NaN/off-frame/tiny box or bad padding → .infinity (live, never spoof) (ND-072/EC-12)")

            // Core-ML-style outcome into the REAL recognizer gate at the DEFAULT floor (12):
            // the helper's flat-frame score trips it (→ .strangerOnly); its textured score
            // and the .infinity failure sentinel do not (→ present).
            let key = "antiSpoofEnabled", floorKey = "spoofTextureFloor"
            let prior = UserDefaults.standard.object(forKey: key)
            let priorFloor = UserDefaults.standard.object(forKey: floorKey)
            UserDefaults.standard.set(true, forKey: key)
            UserDefaults.standard.removeObject(forKey: floorKey)   // → defaultSpoofTextureFloor
            defer {
                if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                if let priorFloor { UserDefaults.standard.set(priorFloor, forKey: floorKey) }
            }
            let desc = FaceEmbeddingModelDescriptor.uniqueFake()
            let store = InMemoryEnrollmentStore()
            try? store.enroll(embeddings: [matchV], modelVersion: desc.version)
            func gate(_ score: Double) async -> RecognitionResult {
                await IdentityRecognizer(embedder: FakeEmbedder(result: .embedding(matchV, textureScore: score), descriptor: desc),
                                         store: store).recognize(CapturedFrame())
            }
            let flatResult = await gate(flatScore)
            var texturedPresent = false, failurePresent = false
            if case .enrolledUserPresent = await gate(noiseScore) { texturedPresent = true }
            if case .enrolledUserPresent = await gate(zeroBox) { failurePresent = true }
            c.expect(flatResult == .strangerOnly && texturedPresent && failurePresent,
                     "anti-spoof gate on Core-ML-style scores (default floor): flat → .strangerOnly; textured / .infinity → present (ND-072)")
        } else {
            c.expect(false, "innerFaceTextureScore: could not allocate synthetic CVPixelBuffers")
        }
    }

    // Shared padded-crop geometry (both embedders' crop + the liveness helper): the exact
    // arithmetic the embedders used inline before ND-072 (regression guard).
    do {
        let extent = CGRect(x: 0, y: 0, width: 160, height: 160)
        let centered = paddedFaceCropRect(faceBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                          paddingFraction: 0.25, orientedExtent: extent)
        let edge = paddedFaceCropRect(faceBoundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                      paddingFraction: 0.25, orientedExtent: extent)
        let off = paddedFaceCropRect(faceBoundingBox: CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
                                     paddingFraction: 0.25, orientedExtent: extent)
        c.expect(centered == CGRect(x: 20, y: 20, width: 120, height: 120)
                 && edge == CGRect(x: 0, y: 0, width: 100, height: 100) && off == nil,
                 "paddedFaceCropRect: 0.25 padding, [0,1] clamp at the edge, off-frame → nil (ND-072 regression)")
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

    // (l) LIVE per-model threshold (ND-040 / ND-076): with the active model's per-model key
    // set on defaults, the recognizer resolves it PER CALL. The recognizer reads `.standard`
    // (EngineCheck's own domain, never com.nodonuts.app); a UNIQUE-version descriptor makes
    // the key guaranteed-fresh, and it is removed afterwards.
    do {
        let desc = FaceEmbeddingModelDescriptor.uniqueFake()
        let key = desc.thresholdOverrideKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: desc.version)
        let partialV: [Float] = [1, 1, 0, 0]  // cos(matchV=[1,0,0,0]) = 1/sqrt(2) ≈ 0.707
        let r = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc), store: store)
        UserDefaults.standard.set(0.5, forKey: key)   // 0.707 >= 0.5 → present
        let below = await r.recognize(CapturedFrame())
        var presentBelow = false
        if case .enrolledUserPresent = below { presentBelow = true }
        UserDefaults.standard.set(0.9, forKey: key)   // 0.707 < 0.9 → stranger (live change applied)
        let above = await r.recognize(CapturedFrame())
        let strangerAbove = above == .strangerOnly
        // An OUT-OF-RANGE 0.95 (above the 0.90 ceiling) is REJECTED → descriptor default 0.6
        // → present. A clamp to 0.90 would have given stranger, so this proves reject-not-clamp.
        UserDefaults.standard.set(0.95, forKey: key)
        let rejectedHigh = await r.recognize(CapturedFrame())
        var presentRejectedHigh = false
        if case .enrolledUserPresent = rejectedHigh { presentRejectedHigh = true }
        c.expect(presentBelow && strangerAbove && presentRejectedHigh,
                 "live threshold: recognizer resolves per-model key per call — 0.5 → present, 0.9 → stranger, 0.95 (out of range) rejected → default, not clamped (ND-040/ND-076)")
    }

    // (l2) NO OVERRIDE → descriptor default (ND-076): a fresh per-model key is absent, so the
    // recognizer must use `descriptor.defaultMatchThreshold` — nothing else (no Config, no
    // init param). 0.707 vs default 0.8 → stranger; vs default 0.7 → present.
    do {
        let partialV: [Float] = [1, 1, 0, 0]
        let strict = FaceEmbeddingModelDescriptor.uniqueFake(defaultMatchThreshold: 0.8)
        let lenient = FaceEmbeddingModelDescriptor.uniqueFake(defaultMatchThreshold: 0.7)
        let s1 = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: strict.version)
        let s2 = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: lenient.version)
        let rStrict = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: strict), store: s1)
        let rLenient = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: lenient), store: s2)
        let strictResult = await rStrict.recognize(CapturedFrame())
        let lenientResult = await rLenient.recognize(CapturedFrame())
        var lenientPresent = false
        if case .enrolledUserPresent = lenientResult { lenientPresent = true }
        c.expect(UserDefaults.standard.object(forKey: strict.thresholdOverrideKey) == nil
                 && strictResult == .strangerOnly && lenientPresent,
                 "identity: no per-model override → descriptor.defaultMatchThreshold is the sole default (0.8 → stranger, 0.7 → present at cos 0.707) (ND-076)")
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

    // resolvedMatchThreshold(for:) validation (cooper, ND-076). Throwaway UserDefaults
    // suite so it never touches real prefs. Reads ONLY the model's per-model key; accepts
    // only a number inside `descriptor.matchThresholdRange`; absent / non-number / out of
    // range → descriptor default (REJECT, never clamp).
    do {
        let suiteName = "com.nodonuts.enginecheck.threshold.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
            let vi = FaceEmbeddingModelDescriptor.visionFeaturePrint
            let key = fn.thresholdOverrideKey
            c.expect(key == "matchThreshold.facenet-vggface2-v2"
                     && vi.thresholdOverrideKey == "matchThreshold.vision-featureprint-v1",
                     "thresholdOverrideKey: per-model \"matchThreshold.<version>\" (ND-076)")
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold,
                     "resolvedMatchThreshold: absent → descriptor default (0.5 FaceNet)")
            suite.set(0.6, forKey: key)
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == 0.6,
                     "resolvedMatchThreshold: in-range 0.6 → 0.6")
            suite.set(0.40, forKey: key)
            let floorOK = resolvedMatchThreshold(for: fn, defaults: suite) == 0.40
            suite.set(0.90, forKey: key)
            let ceilOK = resolvedMatchThreshold(for: fn, defaults: suite) == 0.90
            c.expect(floorOK && ceilOK, "resolvedMatchThreshold: range bounds 0.40 / 0.90 inclusive → accepted")
            suite.set(0.39, forKey: key)
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold,
                     "resolvedMatchThreshold: 0.39 below FaceNet floor → default (rejected, not clamped to 0.40)")
            suite.set(0.01, forKey: key)
            let injectedLow = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(0.0, forKey: key)
            let zero = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(-0.5, forKey: key)
            let negative = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(Double.nan, forKey: key)
            let nan = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(injectedLow && zero && negative && nan,
                     "resolvedMatchThreshold: 0.01 / 0 / negative / NaN → default (fail-open overrides rejected)")
            suite.set(0.95, forKey: key)
            let above = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(1.0, forKey: key)
            let one = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(above && one, "resolvedMatchThreshold: 0.95 above FaceNet ceiling / 1.0 → default (rejected, not clamped)")
            suite.set("0.7", forKey: key)
            let str = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(true, forKey: key)
            let bool = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(str && bool, "resolvedMatchThreshold: non-number (String / Bool) → default")
            // Per-model isolation: a FaceNet override never bleeds into the Vision model,
            // and the legacy global key is ignored by the resolver.
            suite.set(0.8, forKey: key)
            suite.set(0.45, forKey: legacyMatchThresholdKey)
            c.expect(resolvedMatchThreshold(for: vi, defaults: suite) == vi.defaultMatchThreshold
                     && resolvedMatchThreshold(for: fn, defaults: suite) == 0.8,
                     "resolvedMatchThreshold: FaceNet key doesn't affect Vision; legacy global key ignored (ND-076)")
            // Vision accepts up to its own 0.95 ceiling (per-model range).
            suite.set(0.95, forKey: vi.thresholdOverrideKey)
            c.expect(resolvedMatchThreshold(for: vi, defaults: suite) == 0.95,
                     "resolvedMatchThreshold: Vision 0.95 in its own range → accepted (ranges are per-model)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedMatchThreshold: throwaway suite unavailable, skipped")
        }
    }

    // Descriptor ranges contain their defaults (ND-076) — and the FaceNet floor is 0.40.
    do {
        let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
        let vi = FaceEmbeddingModelDescriptor.visionFeaturePrint
        c.expect(fn.matchThresholdRange == 0.40...0.90 && fn.matchThresholdRange.contains(fn.defaultMatchThreshold)
                 && vi.matchThresholdRange == 0.40...0.95 && vi.matchThresholdRange.contains(vi.defaultMatchThreshold)
                 && vi.defaultMatchThreshold == 0.6,
                 "descriptors: FaceNet 0.40...0.90 ∋ 0.5; Vision 0.40...0.95 ∋ 0.6 (ND-076)")
    }

    // dropLegacyMatchThresholdKey (ND-076): returns the old numeric value and removes the
    // key; absent → nil; non-numeric → nil but still removed. Throwaway suite.
    do {
        let suiteName = "com.nodonuts.enginecheck.legacythreshold.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let absent = dropLegacyMatchThresholdKey(defaults: suite) == nil
            suite.set(0.5, forKey: legacyMatchThresholdKey)
            suite.set(0.7, forKey: FaceEmbeddingModelDescriptor.facenetVGGFace2.thresholdOverrideKey)
            let dropped = dropLegacyMatchThresholdKey(defaults: suite)
            let removed = suite.object(forKey: legacyMatchThresholdKey) == nil
            let perModelKept = suite.double(forKey: FaceEmbeddingModelDescriptor.facenetVGGFace2.thresholdOverrideKey) == 0.7
            let second = dropLegacyMatchThresholdKey(defaults: suite) == nil
            suite.set("junk", forKey: legacyMatchThresholdKey)
            let junk = dropLegacyMatchThresholdKey(defaults: suite) == nil
                && suite.object(forKey: legacyMatchThresholdKey) == nil
            c.expect(absent && dropped == 0.5 && removed && perModelKept && second && junk,
                     "dropLegacyMatchThresholdKey: returns 0.5 + removes key, per-model key kept, idempotent, junk removed → nil (ND-076)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "dropLegacyMatchThresholdKey: throwaway suite unavailable, skipped")
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
        // Deterministic synthetic score sets that clear (or deliberately miss) the
        // ND-094 evidence bar. `spread(n, from:, to:)` = n evenly spaced scores.
        func spread(_ n: Int, from lo: Double, to hi: Double) -> [Double] {
            guard n > 1 else { return n == 1 ? [lo] : [] }
            return (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
        }
        let req = ThresholdStudyRequirements.standard
        c.expect(req.minimumGenuineSamples == 30 && req.minimumImpostorSamples == 30
                 && req.minimumImpostorIdentities == 2 && abs(req.minimumSeparationMargin - 0.05) < 1e-12,
                 "ThresholdStudyRequirements.standard: 30 genuine, 30 impostor, 2 identities, 0.05 margin (ND-094)")

        func shortfalls(_ r: ThresholdRecommendation) -> [ThresholdShortfall] {
            if case let .insufficientData(_, s) = r { return s }
            return []
        }

        // Genuine-only data — the exact state this project was in before FaceScore —
        // must be refused, not turned into a number.
        let genuineOnly = recommendThreshold(
            genuine: ScoreDistribution(spread(40, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution([]),
            impostorIdentityCount: 0
        )
        var refusedGenuineOnly = false
        if case let .insufficientData(reason, _) = genuineOnly {
            refusedGenuineOnly = reason.contains("genuine-only")
        }
        c.expect(refusedGenuineOnly && !genuineOnly.justifiesTunedFlag && genuineOnly.refusalReason != nil,
                 "recommendThreshold: genuine-only data → insufficientData, never a threshold (ND-056)")

        // PASSING case: 30 genuine in [0.80, 0.95], 30 impostor in [0.20, 0.60] from 3
        // people → margin 0.20, midpoint 0.70, and it justifies thresholdIsTuned.
        let separated = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        var separationOK = false
        if case let .cleanSeparation(threshold, margin, impostorMaximum, genuineMinimum) = separated {
            separationOK = abs(threshold - 0.70) < 1e-9 && abs(margin - 0.20) < 1e-9
                && abs(impostorMaximum - 0.60) < 1e-9 && abs(genuineMinimum - 0.80) < 1e-9
        }
        c.expect(separationOK && separated.justifiesTunedFlag && separated.refusalReason == nil,
                 "recommendThreshold: 30+30 samples, 3 impostors, margin 0.20 → gap midpoint, justifies thresholdIsTuned")

        // ND-094 regression: the OLD verdict endorsed "clean separation" from 1+1 samples.
        let tiny = recommendThreshold(
            genuine: ScoreDistribution([0.90]),
            impostor: ScoreDistribution([0.20]),
            impostorIdentityCount: 2
        )
        c.expect(!tiny.justifiesTunedFlag
                 && shortfalls(tiny).contains(.genuineSamples(have: 1, need: 30))
                 && shortfalls(tiny).contains(.impostorSamples(have: 1, need: 30)),
                 "recommendThreshold: 1 genuine + 1 impostor, cleanly apart → REFUSED with both count shortfalls (ND-094)")

        // Each criterion refuses on its own, and names itself with the amount short.
        let fewGenuine = recommendThreshold(
            genuine: ScoreDistribution(spread(29, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        c.expect(shortfalls(fewGenuine) == [.genuineSamples(have: 29, need: 30)] && !fewGenuine.justifiesTunedFlag
                 && (fewGenuine.refusalReason?.contains("need 1 more") ?? false),
                 "recommendThreshold: 29 genuine → refused on genuine count only, 'need 1 more'")

        let fewImpostor = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(10, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        c.expect(shortfalls(fewImpostor) == [.impostorSamples(have: 10, need: 30)] && !fewImpostor.justifiesTunedFlag,
                 "recommendThreshold: 10 impostor → refused on impostor count only (need 20 more)")

        let oneStranger = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 1
        )
        c.expect(shortfalls(oneStranger) == [.impostorIdentities(have: 1, need: 2)] && !oneStranger.justifiesTunedFlag,
                 "recommendThreshold: 30 impostor scores from ONE person → refused on identity count (EC-03)")

        let unknownIdentities = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60))
        )
        c.expect(shortfalls(unknownIdentities) == [.impostorIdentities(have: nil, need: 2)]
                 && !unknownIdentities.justifiesTunedFlag,
                 "recommendThreshold: impostor identity count not supplied → refused, never assumed")

        // Margin 0.03 (< 0.05): cleanly apart on this sample, but too narrow to trust.
        let narrow = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.63, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        var narrowOK = false
        if case let .separationMargin(have, need)? = shortfalls(narrow).first, shortfalls(narrow).count == 1 {
            narrowOK = abs(have - 0.03) < 1e-9 && abs(need - 0.05) < 1e-12
        }
        c.expect(narrowOK && !narrow.justifiesTunedFlag
                 && (narrow.refusalReason?.contains("short by 0.0200") ?? false),
                 "recommendThreshold: margin 0.03 < 0.05 → refused on margin, 'short by 0.0200'")

        // Everything short at once → every shortfall listed, so one run says all to fix.
        let allShort = recommendThreshold(
            genuine: ScoreDistribution([0.62, 0.70]),
            impostor: ScoreDistribution([0.60]),
            impostorIdentityCount: 1
        )
        c.expect(shortfalls(allShort).count == 4 && !allShort.justifiesTunedFlag,
                 "recommendThreshold: all four criteria unmet → all four shortfalls reported")

        // A custom (looser) bar is honored — the bar is a parameter, not magic.
        let loose = recommendThreshold(
            genuine: ScoreDistribution([0.80, 0.90, 0.95]),
            impostor: ScoreDistribution([0.20, 0.40, 0.60]),
            impostorIdentityCount: 2,
            requirements: ThresholdStudyRequirements(minimumGenuineSamples: 3, minimumImpostorSamples: 3)
        )
        c.expect(loose.justifiesTunedFlag,
                 "recommendThreshold: explicit looser requirements are honored")

        // Overlap → report the equal-error point but REFUSE to bless it — even on a
        // small sample (an impostor that matched is a finding, not noise).
        let overlapping = recommendThreshold(
            genuine: ScoreDistribution([0.30, 0.60, 0.90]),
            impostor: ScoreDistribution([0.25, 0.65, 0.85]),
            impostorIdentityCount: 2
        )
        var overlapOK = false
        if case let .overlap(equalError, _, _) = overlapping {
            overlapOK = equalError > 0.0 && equalError < 1.0
        }
        c.expect(overlapOK && !overlapping.justifiesTunedFlag
                 && (overlapping.refusalReason?.contains("overlap") ?? false),
                 "recommendThreshold: overlap → equal-error point reported, tuned flag REFUSED")

        // A single impostor above the genuine floor is enough to deny separation — the
        // conservative direction (one look-alike that matches is the EC-03 failure).
        let oneBadImpostor = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(29, from: 0.10, to: 0.40) + [0.85]),
            impostorIdentityCount: 3
        )
        var oneBadIsOverlap = false
        if case .overlap = oneBadImpostor { oneBadIsOverlap = true }
        c.expect(oneBadIsOverlap && !oneBadImpostor.justifiesTunedFlag,
                 "recommendThreshold: one impostor above the genuine floor denies clean separation (EC-03)")

        // Boundary: impostor max EQUAL to genuine min is overlap (IdentityRecognizer's
        // `>=` would accept that impostor).
        let touching = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.70, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.70)),
            impostorIdentityCount: 3
        )
        var touchingIsOverlap = false
        if case .overlap = touching { touchingIsOverlap = true }
        c.expect(touchingIsOverlap, "recommendThreshold: impostor max == genuine min → overlap (matches >= accept)")
    }

    print("\nScreenLocker self-test + chain checks (fakes only, ND-058/ND-074):")
    do {
        let both: Set<String> = ["SACLockScreenImmediate", "SACSwitchToLoginWindow"]
        c.expect(LockMechanism.allCases == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "LockMechanism chain order: immediate, then switch-to-login-window")
        c.expect(LockMechanism.sacLockScreenImmediate.symbolName == "SACLockScreenImmediate"
                 && LockMechanism.sacSwitchToLoginWindow.symbolName == "SACSwitchToLoginWindow",
                 "LockMechanism.symbolName maps to the login.framework exports")

        let none = ScreenLocker(resolveSymbol: fakeResolver([])).selfTest()
        c.expect(!none.canLock && none.available.isEmpty, "selfTest: nothing resolvable → canLock == false")

        let onlySwitch = ScreenLocker(resolveSymbol: fakeResolver(["SACSwitchToLoginWindow"])).selfTest()
        c.expect(onlySwitch.available == [.sacSwitchToLoginWindow] && onlySwitch.canLock,
                 "selfTest: only switch symbol → [.sacSwitchToLoginWindow]")

        let all = ScreenLocker(resolveSymbol: fakeResolver(both)).selfTest()
        c.expect(all == LockCapability(available: [.sacLockScreenImmediate, .sacSwitchToLoginWindow]),
                 "selfTest: both resolvable → chain order preserved")

        let probeSession = FakeLockSession(locksOn: nil)
        _ = probeSession.locker(resolving: both).selfTest()
        c.expect(probeSession.invoked.isEmpty, "selfTest NEVER invokes a mechanism")

        c.expect(SpyLocker(succeed: true).selfTest().canLock,
                 "ScreenLocking default selfTest() → fake lockers canLock (all mechanisms)")

        // lock() chain behaviour with injected invoke + probe.
        let s1 = FakeLockSession(locksOn: .sacLockScreenImmediate)
        let ok1 = await s1.locker(resolving: both).lock()
        c.expect(ok1 && s1.invoked == [.sacLockScreenImmediate],
                 "lock: immediate confirms → true, fallback NOT invoked")

        let s2 = FakeLockSession(locksOn: .sacSwitchToLoginWindow)
        let started = Date()
        let ok2 = await s2.locker(resolving: both).lock()
        c.expect(ok2 && s2.invoked == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "lock: immediate unconfirmed → falls through to switch-to-login-window → true")
        c.expect(Date().timeIntervalSince(started) < 1.0,
                 "lock: fallback confirmed within the shared deadline")

        let s3 = FakeLockSession(locksOn: nil)
        let started3 = Date()
        let ok3 = await s3.locker(resolving: both).lock()
        let elapsed3 = Date().timeIntervalSince(started3)
        c.expect(!ok3 && s3.invoked == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "lock: nothing confirms → both tried in order, returns false (never fail open)")
        c.expect(elapsed3 < 0.3 + 0.5, "lock: whole chain bounded by ONE shared deadline")

        let s4 = FakeLockSession(locksOn: .sacSwitchToLoginWindow)
        let ok4 = await s4.locker(resolving: ["SACSwitchToLoginWindow"]).lock()
        c.expect(ok4 && s4.invoked == [.sacSwitchToLoginWindow],
                 "lock: only switch resolvable → invokes switch only → true")

        let s5 = FakeLockSession(locksOn: .sacLockScreenImmediate)
        let ok5 = await s5.locker(resolving: []).lock()
        c.expect(!ok5 && s5.invoked.isEmpty, "lock: nothing resolvable → false, nothing invoked")
    }

    // ND-055: stale-frame guard (pure policy; host-clock seconds).
    print("\nFrameFreshness checks (ND-055):")
    do {
        let maxAge = FrameFreshness.maxAge
        let now: TimeInterval = 1_000
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.5, now: now, notBefore: nil),
                 "freshness: a 0.5s-old frame is fresh")
        c.expect(FrameFreshness.isFresh(frameTime: now - maxAge, now: now, notBefore: nil),
                 "freshness: a frame exactly maxAge old is fresh (inclusive boundary)")
        c.expect(!FrameFreshness.isFresh(frameTime: now - maxAge - 0.01, now: now, notBefore: nil),
                 "freshness: a frame just past maxAge is stale (never served)")
        c.expect(!FrameFreshness.isFresh(frameTime: now - 60, now: now, notBefore: nil),
                 "freshness: a long-stale frame (camera stopped delivering) is stale")
        c.expect(!FrameFreshness.isFresh(frameTime: now - 1, now: now, notBefore: now - 0.5),
                 "freshness: a frame before notBefore (queued pre-suspend) is rejected even if young")
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.2, now: now, notBefore: now - 0.5),
                 "freshness: a frame after notBefore is fresh")
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.5, now: now, notBefore: now - 0.5),
                 "freshness: a frame exactly at notBefore is accepted")
        c.expect(!FrameFreshness.isFresh(frameTime: now + FrameFreshness.futureTolerance + 5, now: now, notBefore: nil),
                 "freshness: an implausibly future-stamped frame is rejected")

        let wedged = FrameFreshness.wedgedAfter
        c.expect(!FrameFreshness.isWedged(lastFrameTime: nil, runningSince: now - wedged + 1, now: now),
                 "wedged: running too briefly with no frame → not wedged yet")
        c.expect(!FrameFreshness.isWedged(lastFrameTime: now - 1, runningSince: now - 100, now: now),
                 "wedged: a recent frame → not wedged")
        c.expect(FrameFreshness.isWedged(lastFrameTime: now - wedged - 1, runningSince: now - 100, now: now),
                 "wedged: no frame for > wedgedAfter while running → wedged")
        c.expect(FrameFreshness.isWedged(lastFrameTime: nil, runningSince: now - wedged, now: now),
                 "wedged: never delivered since start, exactly wedgedAfter → wedged")
        c.expect(!FrameFreshness.isWedged(lastFrameTime: now - 100, runningSince: now - 2, now: now),
                 "wedged: just resumed (old last frame predates restart) → not wedged yet")

        // Tear-down decision (ADR-0003: never reconfigure-churn during a call).
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: false, deviceInUseByAnotherApp: false,
                                                      interruptedSince: nil, now: now),
                 "wedged tear-down: not wedged → no tear-down")
        c.expect(FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                     interruptedSince: nil, now: now),
                 "wedged tear-down: wedged, no call, no interruption → tear down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: true,
                                                      interruptedSince: nil, now: now),
                 "wedged tear-down: device in use by another app (call) → never tear down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: true,
                                                      interruptedSince: now - 1_000, now: now),
                 "wedged tear-down: call + old interruption → still no tear-down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                      interruptedSince: now - 1, now: now),
                 "wedged tear-down: recent interruption → deferred")
        c.expect(FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                     interruptedSince: now - wedged, now: now),
                 "wedged tear-down: stale interruption flag (no interruptionEnded) can't block recovery forever")
    }

    print("\nCameraTrustPolicy checks (ND-075):")
    do {
        c.expect(CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: true, transportIsBuiltIn: true),
                 "trust: built-in type + built-in transport → trusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: true, transportIsBuiltIn: false),
                 "trust: built-in type on a non-built-in transport (spoofing virtual device) → untrusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: false, transportIsBuiltIn: true),
                 "trust: built-in transport but not a built-in wide-angle type (e.g. Desk View) → untrusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: false, transportIsBuiltIn: false),
                 "trust: external/virtual camera → untrusted")
        c.expect(CameraTrustPolicy.builtInTransportType == Int32(kIOAudioDeviceTransportTypeBuiltIn),
                 "trust: policy built-in transport matches kIOAudioDeviceTransportTypeBuiltIn")
        c.expect(CameraTrustPolicy.fourCC(CameraTrustPolicy.builtInTransportType) == "bltn",
                 "trust: built-in transport renders as 'bltn'")
    }

    print("\nProtectionAudit checks (ND-077):")
    do {
        let suiteName = "com.nodonuts.enginecheck.protectionaudit"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        if let d = UserDefaults(suiteName: suiteName) {
            let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
            let key = fn.thresholdOverrideKey
            func reset() { d.removePersistentDomain(forName: suiteName) }

            reset()
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: all defaults → no reasons")

            reset(); d.set(0.45, forKey: key)
            let lowT = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(lowT.count == 1 && lowT[0].contains("match threshold"),
                     "audit: in-range threshold below default → flagged")

            reset(); d.set(0.01, forKey: key)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: out-of-range threshold (rejected → default) → not flagged")

            reset(); d.set(0.7, forKey: key)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: stricter threshold → not flagged")

            reset(); d.set(false, forKey: "antiSpoofEnabled")
            let off = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(off == ["anti-spoof off"], "audit: anti-spoof disabled → flagged")

            reset(); d.set(true, forKey: "antiSpoofEnabled")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: anti-spoof explicitly enabled → not flagged")

            reset(); d.set(0.0001, forKey: "spoofTextureFloor")
            let lowF = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(lowF.count == 1 && lowF[0].contains("floor"),
                     "audit: tiny positive spoof floor → flagged")

            reset(); d.set(0.0, forKey: "spoofTextureFloor")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: invalid 0 floor (rejected → default) → not flagged")

            reset(); d.set(40.0, forKey: "spoofTextureFloor")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: stricter spoof floor → not flagged")

            reset(); d.set(0.45, forKey: key); d.set(false, forKey: "antiSpoofEnabled")
            d.set(0.0001, forKey: "spoofTextureFloor")
            let all = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(all.count == 2 && all.contains("anti-spoof off"),
                     "audit: threshold + anti-spoof off → both; floor folded into anti-spoof off")

            reset(); d.set(0.55, forKey: FaceEmbeddingModelDescriptor.visionFeaturePrint.thresholdOverrideKey)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: another model's lowered override doesn't flag the active model")
            c.expect(reducedProtectionReasons(descriptor: .visionFeaturePrint, defaults: d).count == 1,
                     "audit: lowered override flags its own model")
            reset()
        } else {
            c.expect(false, "audit: could not create isolated UserDefaults suite")
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }


    // MARK: ND-085 face quality gate + square crop (cooper)
    do {
        let hd = CGRect(x: 0, y: 0, width: 1280, height: 720)
        // 12% of the 720 px shorter side = 86.4 px.
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.08),
                                    orientedExtent: hd),
                 "ND-085 min size: tiny face (64×58 px in 720p) → too small (embedders return .noFace)")
        c.expect(faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.35, y: 0.3, width: 0.2, height: 0.4),
                                   orientedExtent: hd),
                 "ND-085 min size: seated-distance face (256×288 px) → large enough")
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.0671, height: 0.2),
                                    orientedExtent: hd)
                 && faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.0676, height: 0.2),
                                      orientedExtent: hd),
                 "ND-085 min size: the SHORTER face side decides, at 12% of the frame's shorter side (86.4 px)")
        let portrait = CGRect(x: 0, y: 0, width: 720, height: 1280)
        c.expect(faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.125, height: 0.0703),
                                   orientedExtent: portrait)
                 == faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.0703, height: 0.125),
                                      orientedExtent: hd),
                 "ND-085 min size: same verdict for the same pixel face under a portrait orientation")
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3),
                                    orientedExtent: .zero)
                 && !faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0, height: 0.3),
                                       orientedExtent: hd),
                 "ND-085 min size: degenerate frame or box → too small (never toward a match)")
        c.expect(abs(Double(minimumFaceSideFraction) - 0.12) < 1e-9, "ND-085 min size: documented default is 12%")

        // Square crop inside the frame: 200×200 face, 0.25 padding → 300 square, centered.
        let inside = squareFaceCrop(faceBoundingBox: CGRect(x: 500.0 / 1280, y: 260.0 / 720,
                                                            width: 200.0 / 1280, height: 200.0 / 720),
                                    paddingFraction: 0.25, orientedExtent: hd)
        c.expect(inside?.square == CGRect(x: 450, y: 210, width: 300, height: 300)
                 && inside?.visible == inside?.square && inside?.needsPadding == false,
                 "ND-085 square crop: face well inside → 300×300 square centered on the face, no padding")

        // Non-square face box: the LONGER padded side wins, the crop stays square.
        let tall = squareFaceCrop(faceBoundingBox: CGRect(x: 600.0 / 1280, y: 200.0 / 720,
                                                          width: 100.0 / 1280, height: 200.0 / 720),
                                  paddingFraction: 0.25, orientedExtent: hd)
        c.expect(tall?.square == CGRect(x: 500, y: 150, width: 300, height: 300),
                 "ND-085 square crop: 100×200 face → 300×300 square (longer side), never a 150×300 rect")

        // Near the left/bottom edge: square keeps its full size and center, visible part is clipped.
        let edge = squareFaceCrop(faceBoundingBox: CGRect(x: 0, y: 0, width: 200.0 / 1280, height: 200.0 / 720),
                                  paddingFraction: 0.25, orientedExtent: hd)
        c.expect(edge?.square == CGRect(x: -50, y: -50, width: 300, height: 300)
                 && edge?.visible == CGRect(x: 0, y: 0, width: 250, height: 250)
                 && edge?.needsPadding == true,
                 "ND-085 square crop: face at the corner → square extends past the frame, padded not stretched")
        c.expect(squareFaceCrop(faceBoundingBox: CGRect(x: 3, y: 3, width: 0.1, height: 0.1),
                                paddingFraction: 0.25, orientedExtent: hd) == nil
                 && squareFaceCrop(faceBoundingBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.1),
                                   paddingFraction: 0.25, orientedExtent: hd) == nil,
                 "ND-085 square crop: off-frame or degenerate box → nil (caller maps to .failure)")

        // Render the edge crop: the out-of-frame part is BLACK, the in-frame part is the
        // frame's pixels, and the scale is uniform (no stretch).
        if let frame = makeGrayBGRAFrame(width: 320, height: 180, luma: { _, _ in 200 }) {
            let ci = CIImage(cvPixelBuffer: frame)
            let crop = squareFaceCrop(faceBoundingBox: CGRect(x: 0, y: 0.2, width: 0.25, height: 80.0 / 180),
                                      paddingFraction: 0.25, orientedExtent: ci.extent)
            var out: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                          kCVPixelBufferCGBitmapContextCompatibilityKey: true]
            if let crop, CVPixelBufferCreate(kCFAllocatorDefault, 40, 40, kCVPixelFormatType_32BGRA,
                                             attrs as CFDictionary, &out) == kCVReturnSuccess, let out {
                CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                    .render(squareFaceInputImage(from: ci, crop: crop, side: 40), to: out)
                CVPixelBufferLockBaseAddress(out, .readOnly)
                let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(out)
                // The square is 120 px wide starting at x = -20, so the left 1/6 (≈6.7 of
                // 40 px) is padding; take columns 1 and 30 on the middle row.
                let mid = 20 * row
                let padded = base[mid + 1 * 4 + 1]
                let inFrame = base[mid + 30 * 4 + 1]
                CVPixelBufferUnlockBaseAddress(out, .readOnly)
                c.expect(crop.square.width == crop.square.height && crop.square.minX == -20,
                         "ND-085 square crop render: square geometry near the left edge (x = -20, 120×120)")
                c.expect(padded < 10 && abs(Int(inFrame) - 200) <= 3,
                         "ND-085 square crop render: out-of-frame columns are black, in-frame keep the pixels (\(padded), \(inFrame))")
            } else {
                c.expect(false, "ND-085 square crop render: could not build the test buffers")
            }
        } else {
            c.expect(false, "ND-085 square crop render: could not build the test frame")
        }
    }

    // MARK: ND-085 version bump (cooper)
    do {
        let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
        c.expect(fn.version == "facenet-vggface2-v2",
                 "ND-085 version bump: FaceNet descriptor is facenet-vggface2-v2 (square crop changed embeddings)")
        let v1 = identityStatus(for: .enrolled([[1, 0, 0, 0]], modelVersion: "facenet-vggface2-v1"),
                                activeVersion: fn.version, markerVersion: "facenet-vggface2-v1")
        c.expect(v1 == .off(.modelMismatch(stored: "facenet-vggface2-v1", active: "facenet-vggface2-v2")),
                 "ND-085 version bump: a v1 enrollment reads as identity off (model mismatch) → re-enroll")
        let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: "fake-test-v0-precrop")
        let r = IdentityRecognizer(embedder: FakeEmbedder([0, 1, 0, 0]), store: store)
        _ = await r.recognize(CapturedFrame())
        c.expect(r.lastIdentityStatus.isOff,
                 "ND-085 version bump: recognizer never compares vectors from the old crop (identity off)")
        c.expect(fn.enrollmentOutlierFloor == 0.5 && fn.enrollmentConsistencyFloor == 0.6
                 && FaceEmbeddingModelDescriptor.visionFeaturePrint.enrollmentOutlierFloor == 0.6
                 && FaceEmbeddingModelDescriptor.visionFeaturePrint.enrollmentConsistencyFloor == 0.7
                 && FaceEmbeddingModelDescriptor.fakeTest.enrollmentOutlierFloor == 0.6
                 && abs(FaceEmbeddingModelDescriptor.fakeTest.enrollmentConsistencyFloor - 0.7) < 1e-9,
                 "ND-063 floors: FaceNet 0.5/0.6, Vision 0.6/0.7, default = threshold / threshold+0.1")
    }

    // MARK: ND-063 enrollment quality (cooper)
    do {
        // Dedupe.
        var d = EnrollmentFrameDeduper()
        let a = d.isNew(CapturedFrame(captureTime: 10))
        let aAgain = d.isNew(CapturedFrame(captureTime: 10))
        let b = d.isNew(CapturedFrame(captureTime: 11))
        let n1 = d.isNew(CapturedFrame())
        let n2 = d.isNew(CapturedFrame())
        c.expect(a && !aAgain && b && n1 && n2,
                 "ND-063 dedupe: same captureTime counted once; new time is new; no time (fakes) → distinct")
        if let buf = makeGrayBGRAFrame(width: 4, height: 4, luma: { _, _ in 1 }) {
            var d2 = EnrollmentFrameDeduper()
            let first = d2.isNew(CapturedFrame(pixelBuffer: buf, captureTime: 20))
            let sameBufNewTime = d2.isNew(CapturedFrame(pixelBuffer: buf, captureTime: 21))
            c.expect(first && !sameBufNewTime,
                     "ND-063 dedupe: the same pixel buffer object again is a repeat even with a different time")
        }

        // Consistency gate (pure).
        let user: [[Float]] = [[1, 0.02, 0, 0], [1, 0, 0.03, 0], [0.98, 0.01, 0, 0.02],
                               [1, 0.03, 0.01, 0], [0.99, 0, 0, 0.01]]
        let stranger: [Float] = [0, 1, 0.1, 0]
        let withPhotobomb = [user[0], user[1], stranger, user[2], user[3], user[4]]
        let r1 = evaluateEnrollmentConsistency(withPhotobomb, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(r1.droppedIndices == [2] && r1.kept.count == 5 && r1.isConsistent && r1.medianPairwise > 0.99,
                 "ND-063 consistency: one photobomb vector dropped as an outlier, the rest kept → consistent")

        let r2 = evaluateEnrollmentConsistency(Array(user.prefix(4)) + [stranger], requiredVectors: 5,
                                               outlierFloor: 0.6, consistencyFloor: 0.7,
                                               maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r2.isConsistent && r2.droppedIndices == [4] && r2.kept.count == 4,
                 "ND-063 consistency: outlier dropped leaves fewer than N → not consistent (keep sampling)")

        let alternating = (0..<10).map { $0 % 2 == 0 ? user[$0 / 2] : stranger }
        let r3 = evaluateEnrollmentConsistency(alternating, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r3.isConsistent && r3.droppedIndices.count > 3,
                 "ND-063 consistency: two faces taking turns → too many outliers → inconsistent (never enrolls either)")

        // All pairs at cos 0.65: above the outlier floor (none dropped), below the median floor.
        let aa = Float(0.65).squareRoot(), bb = Float(0.35).squareRoot()
        let mushy: [[Float]] = (1...5).map { i in (0..<6).map { $0 == 0 ? aa : ($0 == i ? bb : 0) } }
        let r4 = evaluateEnrollmentConsistency(mushy, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r4.isConsistent && r4.droppedIndices.isEmpty && abs(r4.medianPairwise - 0.65) < 1e-3,
                 "ND-063 consistency: median pairwise 0.65 < floor 0.7 → inconsistent")

        // End to end: distinct frames. Each frame served 3× (≈ 1 fps polled at 200 ms).
        do {
            let clock = FakeClock()
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(100 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(100 + $0), user[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames, repeats: 3), embedder: embedder,
                                                 store: store, now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .success(count: 5) && embedder.callCount == 5,
                     "ND-063 capture: 5 distinct frames, each served 3× → each embedded once → success(5)")
            c.expect(store.enrolledEmbeddings().count == 5
                     && identityStatus(for: store.enrollmentState(), activeVersion: FaceEmbeddingModelDescriptor.fakeTest.version,
                                       markerVersion: nil) == .active,
                     "ND-063 capture: stored 5 vectors stamped with the active model version")
        }

        // One frame repeated forever (frozen camera) never becomes 5 references.
        do {
            let clock = FakeClock()
            let embedder = TimeKeyedEmbedder([7: user[0]])
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera([CapturedFrame(captureTime: 7)]),
                                                 embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .notEnoughFaces && embedder.callCount == 1 && !store.isEnrolled,
                     "ND-063 capture: one frame served for 10 s is embedded once → notEnoughFaces, nothing stored")
        }

        // Photobombed capture recovers: an outlier is replaced by a later good frame.
        do {
            let clock = FakeClock()
            let seq: [[Float]] = [user[0], stranger, user[1], user[2], user[3], user[4]]
            let frames = seq.indices.map { CapturedFrame(captureTime: TimeInterval(200 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: seq.indices.map {
                (TimeInterval(200 + $0), seq[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            let stored = store.enrolledEmbeddings()
            c.expect(out == .success(count: 5) && stored.count == 5 && !stored.contains(stranger),
                     "ND-063 capture: photobomb vector dropped, capture continues, the stranger is never stored")
        }

        // Inconsistent capture: existing enrollment untouched.
        do {
            let clock = FakeClock()
            let frames = (0..<12).map { CapturedFrame(captureTime: TimeInterval(300 + $0)) }
            var altMap: [TimeInterval: [Float]] = [:]
            for i in 0..<12 { altMap[TimeInterval(300 + i)] = i % 2 == 0 ? user[(i / 2) % 5] : stranger }
            let embedder = TimeKeyedEmbedder(altMap)
            let original: [[Float]] = [[0, 0, 1, 0]]
            let store = InMemoryEnrollmentStore(embeddings: original, modelVersion: "fake-test-v1")
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .inconsistent, "ND-063 capture: two faces alternating → .inconsistent")
            c.expect(store.enrolledEmbeddings() == original
                     && identityStatus(for: store.enrollmentState(), activeVersion: "fake-test-v1", markerVersion: nil) == .active,
                     "ND-063 capture: .inconsistent leaves the existing enrollment and its version untouched")
            c.expect(embedder.callCount == 10, "ND-063 capture: stops at the 10-vector cap")
        }

        // Median below floor end to end → .inconsistent, store untouched.
        do {
            let clock = FakeClock()
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(400 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(400 + $0), mushy[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .inconsistent && !store.isEnrolled && clock.now - 1_000 >= 10,
                     "ND-063 capture: low median pairwise → keeps trying to the 10 s timeout → .inconsistent, nothing stored")
        }

        // No camera → .cameraUnavailable at the short no-frame timeout, not the full 10 s.
        do {
            let clock = FakeClock()
            let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: "fake-test-v1")
            let out = await runEnrollmentCapture(camera: SequenceCamera([]), embedder: TimeKeyedEmbedder([:]),
                                                 store: store, now: { clock.now }, sleep: { clock.advance($0) })
            let waited = clock.now - 1_000
            c.expect(out == .cameraUnavailable && waited >= 4 && waited < 5 && store.enrolledEmbeddings().count == 1,
                     "ND-063 capture: no frames → .cameraUnavailable after ~4 s, store untouched")
        }

        // Policy defaults.
        let p = EnrollmentCapturePolicy(descriptor: .facenetVGGFace2)
        c.expect(p.requiredVectors == 5 && p.maxCollectedVectors == 10 && p.timeout == 10
                 && p.outlierFloor == 0.5 && p.consistencyFloor == 0.6,
                 "ND-063 policy: 5 distinct vectors, cap 10, 10 s timeout, FaceNet floors from the descriptor")
    }

    print("\nND-093 / ND-110 — enrollment input validation + blob decode")
    do {
        func rejects(_ e: [[Float]], _ dim: Int?, _ reason: InvalidEmbeddingsReason) -> Bool {
            let store = InMemoryEnrollmentStore(embeddings: [[0, 0, 1, 0]], modelVersion: "fake-test-v1")
            do {
                try store.enroll(embeddings: e, modelVersion: "fake-test-v2", expectedDimension: dim)
                return false
            } catch let err as EnrollmentStoreError {
                // Rejected AND the existing enrollment (vectors + version) is untouched.
                return err == .invalidEmbeddings(reason)
                    && store.enrolledEmbeddings() == [[0, 0, 1, 0]]
                    && identityStatus(for: store.enrollmentState(), activeVersion: "fake-test-v1",
                                      markerVersion: nil) == .active
            } catch { return false }
        }
        c.expect(rejects([], 4, .emptySet),
                 "ND-093 enroll: empty set throws .emptySet, existing enrollment untouched")
        c.expect(rejects([[1, 0, 0, 0], []], nil, .emptyVector(index: 1)),
                 "ND-093 enroll: an empty vector throws .emptyVector")
        c.expect(rejects([[1, 0, 0, 0], [1, 0, 0]], nil, .mixedDimensions(index: 1, expected: 4, found: 3)),
                 "ND-093 enroll: mixed vector lengths throw .mixedDimensions")
        c.expect(rejects([[1, 0, 0, 0], [1, .nan, 0, 0]], nil, .nonFinite(index: 1)),
                 "ND-093 enroll: a NaN component throws .nonFinite")
        c.expect(rejects([[.infinity, 0, 0, 0]], nil, .nonFinite(index: 0)),
                 "ND-093 enroll: an infinite component throws .nonFinite")
        c.expect(rejects([[1, 0, 0]], 4, .wrongDimension(expected: 4, found: 3)),
                 "ND-093 enroll: vectors not matching the model's dimension throw .wrongDimension")

        let ok = InMemoryEnrollmentStore()
        let accepted = (try? ok.enroll(embeddings: [[1, 0, 0, 0], [0.9, 0.1, 0, 0]],
                                       modelVersion: "fake-test-v1", expectedDimension: 4)) != nil
        let acceptedUnknownDim = (try? InMemoryEnrollmentStore()
            .enroll(embeddings: [[1, 0, 0]], modelVersion: "vision", expectedDimension: nil)) != nil
        let acceptedZeroDim = (try? InMemoryEnrollmentStore()
            .enroll(embeddings: [[1, 0, 0]], modelVersion: "vision", expectedDimension: 0)) != nil
        c.expect(accepted && ok.enrolledEmbeddings().count == 2 && acceptedUnknownDim && acceptedZeroDim,
                 "ND-093 enroll: a valid set is stored; nil/0 expected dimension (Vision fallback) skips only the dimension check")

        // runEnrollmentCapture passes the descriptor's dimension through: 3-d vectors from
        // a 4-d model → .saveFailed, nothing stored.
        do {
            let clock = FakeClock()
            let v3: [[Float]] = [[1, 0.02, 0], [1, 0, 0.03], [0.98, 0.01, 0], [1, 0.03, 0.01], [0.99, 0, 0.01]]
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(500 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(500 + $0), v3[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(embedder.descriptor.outputDimension == 4 && out == .saveFailed && !store.isEnrolled,
                     "ND-093 capture: vectors of the wrong dimension for the model → .saveFailed, nothing stored")
        }

        // Blob decode (ND-110 coverage). Blobs are hand-written JSON, as the Keychain holds.
        func decode(_ json: String) -> EnrollmentState { EnrollmentStore.decodeEnrollment(Data(json.utf8)) }
        func isUnavailable(_ s: EnrollmentState) -> Bool { if case .unavailable = s { return true }; return false }
        if case .enrolled(let e, let v) = decode(#"{"modelVersion":"m1","embeddings":[[1,0],[0,1]]}"#) {
            c.expect(e == [[1, 0], [0, 1]] && v == "m1", "ND-110 decode: versioned blob → .enrolled with its version")
        } else { c.expect(false, "ND-110 decode: versioned blob → .enrolled with its version") }
        if case .enrolled(let e, let v) = decode("[[1,0,0],[0,1,0]]") {
            c.expect(e.count == 2 && v == nil, "ND-110 decode: legacy bare array → .enrolled, version nil (stale)")
        } else { c.expect(false, "ND-110 decode: legacy bare array → .enrolled, version nil (stale)") }
        c.expect(isNotEnrolled(decode(#"{"modelVersion":"m1","embeddings":[]}"#)) && isNotEnrolled(decode("[]")),
                 "ND-110 decode: empty set (versioned or legacy) → .notEnrolled")
        c.expect(isUnavailable(decode("not json")) && isUnavailable(decode(#"{"embeddings":"x"}"#))
                 && isUnavailable(decode("")),
                 "ND-110 decode: corrupt / undecodable blob → .unavailable (fail-safe)")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1,0,0],[1,0]]}"#))
                 && isUnavailable(decode("[[1,0,0],[1,0]]")),
                 "ND-093 decode: mixed vector lengths (versioned or legacy) → .unavailable, never presence-only")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1,0],[]]}"#)),
                 "ND-093 decode: an empty vector inside the set → .unavailable")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1e39,0]]}"#)),
                 "ND-093 decode: an out-of-range (non-finite as Float) component → .unavailable")
    }

    print("\nND-080 / ND-082 — pause + liveness policy")
    do {
        c.expect(PausePolicy.endsOnSessionSuspend(.indefinite),
                 "ND-080: an indefinite pause ENDS when the session suspends (user returns protected)")
        c.expect(!PausePolicy.endsOnSessionSuspend(.timed),
                 "ND-080: a timed pause survives a session suspend (bounded; expires on its own)")
        c.expect(PausePolicy.remindsWhilePaused(.indefinite) && !PausePolicy.remindsWhilePaused(.timed),
                 "ND-080: only indefinite pauses get the periodic reminder")
        c.expect(PausePolicy.pausedReminderInterval == 30 * 60,
                 "ND-080: paused reminder every 30 min")
        c.expect(DeadManPolicy.heartbeatKeepsAhead(),
                 "ND-082: shipped heartbeat (60 s) re-arms the dead-man (10 min) with >= 3 beats of slack")
        c.expect(!DeadManPolicy.heartbeatKeepsAhead(heartbeat: 300, fireDelay: 600)
                 && !DeadManPolicy.heartbeatKeepsAhead(heartbeat: 0, fireDelay: 600),
                 "ND-082: a heartbeat too slow (or zero) for the fire delay is rejected")
        c.expect(DeadManPolicy.quitReminderDelay == 30 * 60 && DeadManPolicy.fireDelay == 10 * 60,
                 "ND-082: not-running fires <= 10 min after death; after a menu Quit, +30 min")
    }

    print("\nND-082 — launcher handover (ADR-0018)")
    do {
        typealias H = LauncherHandoverPolicy
        let running = """
        gui/503/com.nodonuts.app.agent = {
        	active count = 1
        	path = /Applications/NoDonuts.app/Contents/Library/LaunchAgents/com.nodonuts.app.agent.plist
        	type = LaunchAgent
        	state = running

        	program identifier = Contents/MacOS/NoDonuts (mode: 2)
        	pid = 28408
        	immediate reason = inefficient
        	last exit code = 0
        }
        """
        c.expect(H.parsePID(fromLaunchctlPrint: running) == 28408,
                 "ND-082: parses `pid = N` from launchctl print of a running job")
        let loadedNotRunning = """
        gui/503/com.nodonuts.app.agent = {
        	active count = 0
        	state = not running
        	last exit code = 0
        }
        """
        c.expect(H.parsePID(fromLaunchctlPrint: loadedNotRunning) == nil,
                 "ND-082: a loaded-but-not-running job has no pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "Could not find service \"com.nodonuts.app.agent\" in domain for user gui: 503") == nil
                 && H.parsePID(fromLaunchctlPrint: "") == nil,
                 "ND-082: 'not found' / empty output → no pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "\tpid = 0\n") == nil
                 && H.parsePID(fromLaunchctlPrint: "\tpid = abc\n") == nil
                 && H.parsePID(fromLaunchctlPrint: "\tpid = -4\n") == nil,
                 "ND-082: pid 0 / garbage / negative is not a live pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "\tparent pid = 1\n\tpid = 77\n") == 77,
                 "ND-082: `parent pid` lines don't count; the job's own `pid =` does")

        let label = "com.nodonuts.app.agent"
        c.expect(H.isAgentManaged(serviceNameEnv: label, label: label, jobPID: nil, ownPID: 10),
                 "ND-082: XPC_SERVICE_NAME == label → managed (even if launchctl can't be read)")
        c.expect(H.isAgentManaged(serviceNameEnv: "0", label: label, jobPID: 10, ownPID: 10),
                 "ND-082: launchd's job pid == ours → managed")
        c.expect(!H.isAgentManaged(serviceNameEnv: "application.com.nodonuts.app.1.2", label: label, jobPID: nil, ownPID: 10)
                 && !H.isAgentManaged(serviceNameEnv: nil, label: label, jobPID: 11, ownPID: 10)
                 && !H.isAgentManaged(serviceNameEnv: "com.nodonuts.agent", label: label, jobPID: nil, ownPID: 10),
                 "ND-082: `open` / other pid / legacy agent label → NOT managed")

        c.expect(H.shouldHandOver(agentEnabled: true, isAgentManaged: false),
                 "ND-082: enabled agent + unmanaged copy → hand over")
        c.expect(!H.shouldHandOver(agentEnabled: true, isAgentManaged: true),
                 "ND-082: the managed copy never hands over (loop guard)")
        c.expect(!H.shouldHandOver(agentEnabled: false, isAgentManaged: false),
                 "ND-082: agent not enabled (off / needs approval) → keep running")

        c.expect(H.handoverConfirmed(jobPID: 11, ownPID: 10),
                 "ND-082: a live job pid that isn't ours confirms the handover")
        c.expect(!H.handoverConfirmed(jobPID: nil, ownPID: 10)
                 && !H.handoverConfirmed(jobPID: 10, ownPID: 10)
                 && !H.handoverConfirmed(jobPID: 0, ownPID: 10),
                 "ND-082: no pid / our own pid / 0 never confirms (don't exit into nothing)")
    }

    // ND-090 + ND-064: session suspend policy + shared CGSession reader.
    print("\nSession suspend policy + CGSession reader (ND-090, ND-064):")
    do {
        typealias P = SessionSuspendPolicy
        c.expect(!P.shouldSuspend(locked: false, onConsole: true, displayAsleep: true, systemSleeping: false),
                 "ND-090: display asleep but session UNLOCKED → keep running (walk-away still locks)")
        c.expect(!P.shouldSuspend(locked: false, onConsole: true, displayAsleep: false, systemSleeping: false),
                 "ND-090: unlocked, on console, awake → active")
        c.expect(P.shouldSuspend(locked: true, onConsole: true, displayAsleep: false, systemSleeping: false)
                 && P.shouldSuspend(locked: true, onConsole: true, displayAsleep: true, systemSleeping: false),
                 "ND-090: screen locked → suspend (display on or off)")
        c.expect(P.shouldSuspend(locked: false, onConsole: false, displayAsleep: false, systemSleeping: false),
                 "ND-090: off console (FUS / login window) → suspend (EC-14)")
        c.expect(P.shouldSuspend(locked: false, onConsole: true, displayAsleep: true, systemSleeping: true)
                 && P.shouldSuspend(locked: false, onConsole: true, displayAsleep: false, systemSleeping: true),
                 "ND-090: system sleep → suspend (EC-13)")

        // Snapshot convenience: unreadable session → active; off-console only when explicit.
        c.expect(!P.shouldSuspend(session: nil, displayAsleep: true, systemSleeping: false),
                 "ND-064: unreadable CGSession → active (never wedge the loop off)")
        c.expect(!P.shouldSuspend(session: CGSessionState(screenLocked: false, onConsole: nil),
                                  displayAsleep: false, systemSleeping: false),
                 "ND-064: on-console unknown → treated as on console")
        c.expect(P.shouldSuspend(session: CGSessionState(screenLocked: false, onConsole: false),
                                 displayAsleep: false, systemSleeping: false),
                 "ND-064: explicit off-console snapshot → suspend")

        // Parsing: Bool AND NSNumber bridging, absent / junk keys.
        let K = CGSessionState.self
        let boolLocked = K.parse([K.screenLockedKey: true, K.onConsoleKey: true])
        c.expect(boolLocked == CGSessionState(screenLocked: true, onConsole: true) && boolLocked?.isLockedOrOffConsole == true,
                 "ND-064: Bool flags parse (locked, on console) → locked")
        let numOff = K.parse([K.screenLockedKey: NSNumber(value: 0), K.onConsoleKey: NSNumber(value: 0)])
        c.expect(numOff == CGSessionState(screenLocked: false, onConsole: false) && numOff?.isLockedOrOffConsole == true,
                 "ND-064: NSNumber flags bridge (0/0) → off console counts as locked")
        let numUnlocked = K.parse([K.screenLockedKey: NSNumber(value: 0), K.onConsoleKey: NSNumber(value: 1)])
        c.expect(numUnlocked?.isLockedOrOffConsole == false,
                 "ND-064: NSNumber unlocked + on console → NOT locked")
        let empty = K.parse([:])
        c.expect(empty == CGSessionState(screenLocked: false, onConsole: nil) && empty?.isLockedOrOffConsole == false,
                 "ND-064: absent keys → not locked, on-console unknown (absent key never claims locked)")
        let junk = K.parse([K.screenLockedKey: "yes", K.onConsoleKey: "no"])
        c.expect(junk?.screenLocked == false && junk?.onConsole == nil && junk?.isLockedOrOffConsole == false,
                 "ND-064: non-Bool/NSNumber values ignored (no claimed lock, no suspend)")
        c.expect(K.parse(nil) == nil, "ND-064: nil dictionary → nil (caller picks safe default)")
        c.expect(K.flag(true) == true && K.flag(NSNumber(value: 1)) == true && K.flag(NSNumber(value: false)) == false
                 && K.flag(nil) == nil && K.flag("1") == nil,
                 "ND-064: flag() bridges Bool + NSNumber only")

        // Stale willSleep flag (cancelled sleep / missed didWake) — uptime excludes sleep.
        c.expect(!P.sleepFlagIsStale(willSleepUptime: 100, nowUptime: 100 + P.staleSleepFlagAfter - 1),
                 "ND-090: sleep flag fresh shortly after willSleep")
        c.expect(P.sleepFlagIsStale(willSleepUptime: 100, nowUptime: 100 + P.staleSleepFlagAfter),
                 "ND-090: awake ≥30s after willSleep with no didWake → stale, cleared")
    }

    print("\nND-060/062/091/092 engine hardening checks:")

    // ND-062: Config.validated() clamps every tunable into Config.Bounds.
    do {
        let d = Config()
        c.expect(d.validated() == d, "ND-062: shipped defaults are inside Bounds (validated() is a no-op)")
        var bad = Config()
        bad.tickIntervalSeconds = 0
        bad.graceSeconds = 100_000
        bad.consecutiveAbsentTicksToLock = 0
        bad.maxConsecutiveErrorsBeforeAbsent = -5
        bad.maxCallAssumedPresentSeconds = 1e9
        bad.maxCameraUnavailableSeconds = 0
        bad.consecutiveStrangerTicksToLock = 0
        bad.strangerGraceSeconds = -3
        let v = bad.validated()
        let B = Config.Bounds.self
        c.expect(v.tickIntervalSeconds == B.tickIntervalSeconds.lowerBound && v.tickIntervalSeconds == 0.5,
                 "ND-062: 0s tick → clamped to 0.5s (no CPU spin)")
        c.expect(v.graceSeconds == 60, "ND-062: huge grace → clamped to 60s (no fail-open)")
        c.expect(v.consecutiveAbsentTicksToLock == 2, "ND-062: 0 consensus → clamped to 2 ticks")
        c.expect(v.maxConsecutiveErrorsBeforeAbsent == 1, "ND-062: negative error cap → clamped to 1")
        c.expect(v.maxCallAssumedPresentSeconds == 3600, "ND-062: huge call cap → clamped to 3600s")
        c.expect(v.maxCameraUnavailableSeconds == 30, "ND-062: 0 unavailable cap → clamped to 30s")
        c.expect(v.consecutiveStrangerTicksToLock == 1, "ND-062: 0 stranger ticks → clamped to 1")
        c.expect(v.strangerGraceSeconds == 0, "ND-062: negative stranger grace → clamped to 0")
        c.expect(v.validated() == v, "ND-062: validated() is idempotent")
        var high = Config()
        high.tickIntervalSeconds = 99
        high.consecutiveAbsentTicksToLock = 1_000
        high.maxConsecutiveErrorsBeforeAbsent = 1_000
        high.consecutiveStrangerTicksToLock = 1_000
        high.strangerGraceSeconds = 99
        high.graceSeconds = 0
        high.maxCameraUnavailableSeconds = 1e9
        high.maxCallAssumedPresentSeconds = 0
        let hv = high.validated()
        c.expect(hv.tickIntervalSeconds == 10 && hv.consecutiveAbsentTicksToLock == 20
                 && hv.maxConsecutiveErrorsBeforeAbsent == 20 && hv.consecutiveStrangerTicksToLock == 10
                 && hv.strangerGraceSeconds == 10 && hv.graceSeconds == 2
                 && hv.maxCameraUnavailableSeconds == 600 && hv.maxCallAssumedPresentSeconds == 60,
                 "ND-062: every tunable clamps at the other end of its range too")
        var nan = Config()
        nan.tickIntervalSeconds = .nan
        nan.graceSeconds = .infinity
        nan.maxCallAssumedPresentSeconds = -.infinity
        nan.strangerGraceSeconds = .nan
        let nv = nan.validated()
        c.expect(nv.tickIntervalSeconds == d.tickIntervalSeconds && nv.graceSeconds == d.graceSeconds
                 && nv.maxCallAssumedPresentSeconds == d.maxCallAssumedPresentSeconds
                 && nv.strangerGraceSeconds == d.strangerGraceSeconds,
                 "ND-062: non-finite values fall back to the shipped default (not clamped)")
    }

    // ND-062: the engine validates at init AND on updateConfig — a 0-tick / 0-grace /
    // 0-consensus config cannot make a single no-face tick lock.
    do {
        var bad = Config()
        bad.graceSeconds = 0
        bad.consecutiveAbsentTicksToLock = 0
        bad.tickIntervalSeconds = 0
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, bad)
        await e.tick(now: t0)
        c.expect(locker.lockCallCount == 0 && e.effectiveConfig == bad.validated()
                 && e.effectiveConfig.tickIntervalSeconds == 0.5,
                 "ND-062: init validates → 0 consensus/grace config can't lock on one no-face tick")
        let e2 = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        e2.updateConfig(bad)
        await e2.tick(now: t0)
        c.expect(locker.lockCallCount == 0 && e2.effectiveConfig.consecutiveAbsentTicksToLock == 2
                 && e2.effectiveConfig.graceSeconds == 2,
                 "ND-062: updateConfig validates → unsafe live update clamped, no instant lock")
    }

    // ND-062: Config.resolved(from:) — the UserDefaults resolver (mirrors resolvedMatchThreshold).
    do {
        let suiteName = "nd062.check.\(UUID().uuidString)"
        if let ud = UserDefaults(suiteName: suiteName) {
            defer { ud.removePersistentDomain(forName: suiteName) }
            let K = Config.DefaultsKey.self
            let d = Config()
            c.expect(Config.resolved(from: ud) == d, "ND-062: resolver — absent keys → defaults")
            ud.set(3.0, forKey: K.tickIntervalSeconds); ud.set(12.0, forKey: K.graceSeconds)
            let ok = Config.resolved(from: ud)
            c.expect(ok.tickIntervalSeconds == 3 && ok.graceSeconds == 12, "ND-062: resolver — in-range values accepted")
            ud.set(0.0, forKey: K.tickIntervalSeconds); ud.set(100_000.0, forKey: K.graceSeconds)
            let out = Config.resolved(from: ud)
            c.expect(out.tickIntervalSeconds == d.tickIntervalSeconds && out.graceSeconds == d.graceSeconds,
                     "ND-062: resolver — out-of-range rejected → default (not clamped to the floor)")
            ud.set("fast", forKey: K.tickIntervalSeconds); ud.set(true, forKey: K.graceSeconds)
            let junk = Config.resolved(from: ud)
            c.expect(junk.tickIntervalSeconds == d.tickIntervalSeconds && junk.graceSeconds == d.graceSeconds,
                     "ND-062: resolver — String / Bool values rejected → default")
            ud.set(Double.nan, forKey: K.tickIntervalSeconds)
            c.expect(Config.resolved(from: ud).tickIntervalSeconds == d.tickIntervalSeconds,
                     "ND-062: resolver — NaN rejected → default")
            var base = Config(); base.graceSeconds = 0
            ud.removeObject(forKey: K.graceSeconds)
            c.expect(Config.resolved(from: ud, base: base).graceSeconds == 2,
                     "ND-062: resolver output is validated (an unsafe base can't leak through)")
        } else {
            c.expect(false, "ND-062: could not create a throwaway UserDefaults suite")
        }
    }

    // ND-091: pause() while a tick is suspended in capture() → the stale tick must not
    // overwrite .paused nor count an absence tick into the fresh episode.
    do {
        let config = Config()
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        let held = camera.isHeld
        e.pause()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        let stayedPaused = e.state == .paused
        // Resume: if the stale tick had counted, consensus would be reached one tick
        // early (4 fresh ticks) and a tick at +grace would lock.
        let resumed = makeFeeder(camera)
        for n in 0..<(config.consecutiveAbsentTicksToLock - 1) {
            await resumed(e, t0.addingTimeInterval(10 + Double(n)), .frame(CapturedFrame()))
        }
        await resumed(e, t0.addingTimeInterval(10 + Double(config.consecutiveAbsentTicksToLock - 2) + config.graceSeconds + 0.5),
                      .frame(CapturedFrame()))
        c.expect(held && stayedPaused && locker.lockCallCount == 0,
                 "ND-091: pause during in-flight capture → stays .paused, stale tick counts no absence")
    }

    // ND-091: pause() while a tick is suspended in recognize() → same guarantee.
    do {
        let recognizer = GatedRecognizer()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !recognizer.isHeld { await Task.yield() }
        let held = recognizer.isHeld
        e.pause()
        recognizer.release(.enrolledUserPresent(confidence: 1))
        await inFlight.value
        c.expect(held && e.state == .paused && locker.lockCallCount == 0,
                 "ND-091: pause during in-flight recognize → stays .paused (not flipped to .present)")
    }

    // ND-091: sessionSuspended() during an in-flight capture that then returns a
    // stranger frame → stays .suspended, no stranger streak leaked.
    do {
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(camera, StubRecognizer(.strangerOnly), locker)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        e.sessionSuspended()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        let stayed = e.state == .suspended
        // Two fresh stranger ticks must NOT fast-lock (would if the stale one counted).
        let feed = makeFeeder(camera)
        await feed(e, t0.addingTimeInterval(1), .frame(CapturedFrame()))
        await feed(e, t0.addingTimeInterval(2), .frame(CapturedFrame()))
        c.expect(stayed && locker.lockCallCount == 0,
                 "ND-091: session suspend during in-flight tick → stays .suspended, stale stranger tick not counted")
    }

    // ND-091: the loop Task cancelled (stopLoop) mid-capture, with no reset → nothing mutates.
    do {
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(camera, recognizer, locker)
        let first = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        camera.release(.frame(CapturedFrame()))
        await first.value
        let present = e.state == .present
        recognizer.result = .noFace
        let inFlight = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(1)) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        inFlight.cancel()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        c.expect(present && e.state == .present && locker.lockCallCount == 0,
                 "ND-091: cancelled in-flight tick → state untouched (no stale .absent)")
    }

    // ND-091: cancelled auto-lock whose lock() then FAILS → no .lockFailed, no failure count.
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        let autoTick = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(graceAt)) }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        autoTick.cancel()
        locker.release(false)
        await autoTick.value
        c.expect(e.state == .absent && e.lockFailureCount == 0,
                 "ND-091: cancelled auto-lock that fails → no stale .lockFailed / failure recorded")
    }

    // ND-092: a successful lock clears the EC-10 error streak. Two held errors, a manual
    // lockNow() that succeeds, then ONE error tick: must be held (stay .suspended), not
    // escalate on the half-finished pre-lock streak to .absent.
    do {
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        await e.tick(now: t0)
        recognizer.result = .error("glitch")
        await e.tick(now: t0.addingTimeInterval(1))
        await e.tick(now: t0.addingTimeInterval(2))
        await e.lockNow()
        let locked = e.state == .suspended
        await e.tick(now: t0.addingTimeInterval(3))
        c.expect(locked && e.state == .suspended && locker.lockCallCount == 1,
                 "ND-092: successful lock clears the error streak → next lone error is held, no .absent")
    }

    // ND-092: after an AUTO lock reached via EC-10 escalation, further errors neither
    // re-lock nor clobber .suspended (lockSucceeded preserved, streaks cleared).
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.error("wedged")), locker)
        for n in 0..<40 { await e.tick(now: t0.addingTimeInterval(Double(n))) }
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "ND-092: post-auto-lock error ticks → no re-lock, state stays .suspended")
    }

    // ND-087: the Core ML output-dimension check refuses a model whose declared
    // output isn't exactly one multi-array of `expected` elements.
    do {
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 512]], expected: 512),
                 "ND-087: output [1, 512] matches a 512-d descriptor")
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[512]], expected: 512),
                 "ND-087: output [512] matches a 512-d descriptor")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 128]], expected: 512),
                 "ND-087: a 128-d model under a 512-d descriptor is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [], expected: 512),
                 "ND-087: no multi-array output is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[]], expected: 512),
                 "ND-087: an undeclared (flexible) output shape is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 512], [1, 512]], expected: 512),
                 "ND-087: two multi-array outputs (ambiguous) are refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, -1]], expected: 512),
                 "ND-087: a non-positive dimension is refused")
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 128]], expected: 0),
                 "ND-087: expected 0 (no fixed size) always passes")
    }

    // ND-065: the Keychain service is fixed and independent of the bundle id.
    c.expect(AppIdentity.keychainService == "com.nodonuts.app",
             "ND-065: Keychain service stays com.nodonuts.app (never tracks the bundle id)")
    c.expect(Log.subsystem == AppIdentity.bundleID && AppIdentity.defaultsDomain == AppIdentity.bundleID,
             "ND-065: log subsystem and defaults domain follow the bundle id")

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
