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
    private(set) var lastSelection: FaceSelection?
    func embeddingWithLiveness(for frame: CapturedFrame, selecting selection: FaceSelection) async -> FaceEmbeddingResult {
        lastSelection = selection
        return result
    }
}

/// ND-059 multi-face fake: a frame with several faces (box + vector, `nil` vector =
/// that face's embedding FAILS). It runs the PRODUCTION ranking (`rankedFaceCandidates`,
/// on a 640×480 frame) and the PRODUCTION selection loop (`selectFace`), so checks cover
/// the shipped logic, and counts embed / texture calls to prove laziness.
final class MultiFaceFakeEmbedder: FaceEmbedding, @unchecked Sendable {
    struct Face {
        var box: CGRect
        var vector: [Float]?
        var texture: Double = 10_000
    }
    private let lock = NSLock()
    private var _faces: [Face]
    private var _embeds = 0, _textures = 0
    private var _lastSelection: FaceSelection?
    let descriptor: FaceEmbeddingModelDescriptor
    static let extent = CGRect(x: 0, y: 0, width: 640, height: 480)
    init(_ faces: [Face], descriptor: FaceEmbeddingModelDescriptor = .fakeTest) {
        _faces = faces; self.descriptor = descriptor
    }
    var faces: [Face] {
        get { lock.withLock { _faces } }
        set { lock.withLock { _faces = newValue } }
    }
    var embedCalls: Int { lock.withLock { _embeds } }
    var textureCalls: Int { lock.withLock { _textures } }
    var lastSelection: FaceSelection? { lock.withLock { _lastSelection } }
    func resetCounts() { lock.withLock { _embeds = 0; _textures = 0 } }

    func embeddingWithLiveness(for frame: CapturedFrame, selecting selection: FaceSelection) async -> FaceEmbeddingResult {
        let faces = self.faces
        lock.withLock { _lastSelection = selection }
        guard !faces.isEmpty else { return .noFace }
        let ranked = rankedFaceCandidates(boxes: faces.map(\.box), orientedExtent: Self.extent,
                                          maxFaces: selection.maxFaces)
        return selectFace(facesDetected: faces.count, candidateCount: ranked.count, selection: selection,
                          embed: { rank in
                              self.lock.withLock { self._embeds += 1 }
                              let f = faces[ranked[rank]]
                              guard let v = f.vector else { return .failure }
                              return .embedding(v, textureScore: .infinity, faceBox: f.box)
                          },
                          texture: { rank in
                              self.lock.withLock { self._textures += 1 }
                              return faces[ranked[rank]].texture
                          })
    }
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
    func embeddingWithLiveness(for frame: CapturedFrame, selecting selection: FaceSelection) async -> FaceEmbeddingResult {
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

// ND-061: hoisted from runAll() (was a function-local class).
/// Scripted recognizer: returns results in order (last one repeats).
final class SeqRecognizer: FaceRecognizing, @unchecked Sendable {
    var script: [RecognitionResult]; var i = 0
    init(_ s: [RecognitionResult]) { script = s }
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        defer { i += 1 }; return script[min(i, script.count - 1)]
    }
}
