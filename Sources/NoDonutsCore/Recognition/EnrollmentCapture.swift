import Foundation
import CoreVideo
import os

// Owner: cooper — enrollment capture quality (ND-063): distinct frames + consistency gate.
// Privacy: frames are embedded in memory and dropped; only embedding vectors reach the
// store, which keeps them encrypted at rest. No I/O here beyond that store call. No network.

/// Outcome of one enrollment attempt (ND-022, ND-063). The App shows each case in an
/// alert. Every case except `.success` leaves the stored enrollment untouched.
public enum EnrollmentCaptureOutcome: Sendable, Equatable {
    /// Enrolled with `count` reference embeddings.
    case success(count: Int)
    /// Frames arrived, but fewer than the required number of distinct frames had a
    /// usable face (none, too small, or embedding failed).
    case notEnoughFaces
    /// Enough faces, but they did not agree with each other (ND-063). Usually a second
    /// person in view, heavy blur, or a lighting change mid-capture.
    case inconsistent
    /// The camera never delivered a frame.
    case cameraUnavailable
    /// The capture was fine but the store write failed (e.g. a Keychain error).
    case saveFailed
    /// Cancelled mid-capture (session suspended / app terminating).
    case cancelled
}

/// Tunables for one enrollment capture (ND-063). Defaults come from the model
/// descriptor (consistency floors) and from the camera's ~1 fps delivery rate.
public struct EnrollmentCapturePolicy: Sendable, Equatable {
    /// Distinct, consistent face vectors needed to enroll. 5 frames at ~1 fps is about
    /// 5 s. That is enough for a median-pairwise check to mean something (10 pairs)
    /// and short enough to hold still for.
    public var requiredVectors: Int = 5
    /// Stop collecting after this many usable vectors even if the set is not yet
    /// consistent. Twice `requiredVectors` leaves room to replace a few outliers.
    public var maxCollectedVectors: Int = 10
    /// Give up after this long (seconds). About 5 s of frames plus slack for a slow
    /// camera start and for replacing outliers.
    public var timeout: TimeInterval = 10
    /// If no frame at all arrives within this many seconds, report `.cameraUnavailable`
    /// without waiting for the full timeout (the old capture failed after about 2 s).
    public var noFrameTimeout: TimeInterval = 4
    /// Poll spacing (seconds). Faster than the camera, so no frame is missed; repeats of
    /// the same frame are skipped before they are embedded (`EnrollmentFrameDeduper`).
    public var pollSpacing: TimeInterval = 0.2
    /// See `FaceEmbeddingModelDescriptor.enrollmentOutlierFloor`.
    public var outlierFloor: Double
    /// See `FaceEmbeddingModelDescriptor.enrollmentConsistencyFloor`.
    public var consistencyFloor: Double
    /// If more than this fraction of the collected vectors are outliers, the capture is
    /// rejected even when enough vectors remain. If two faces keep swapping as the
    /// largest, dropping "the outliers" could otherwise enroll the wrong person.
    public var maxOutlierFraction: Double = 1.0 / 3.0

    public init(descriptor: FaceEmbeddingModelDescriptor) {
        self.outlierFloor = descriptor.enrollmentOutlierFloor
        self.consistencyFloor = descriptor.enrollmentConsistencyFloor
    }
}

/// Tells distinct camera frames apart during enrollment (ND-063a). The camera delivers
/// ~1 fps while enrollment polls every 200 ms, so `capture()` often returns the same
/// cached frame again. Without this, one image embedded several times would count as
/// several references.
///
/// Key: `CapturedFrame.captureTime` (the camera's host-clock stamp). As a backup, the
/// same pixel buffer object as the previous frame also counts as a repeat. The camera
/// reads the buffer and its time under separate locks, so in rare cases one buffer could
/// get a later frame's time. Frames with no `captureTime` (fakes) are distinct unless
/// they share a buffer object.
public struct EnrollmentFrameDeduper {
    private var seenTimes: Set<TimeInterval> = []
    private var lastBuffer: CVPixelBuffer?

    public init() {}

    /// True the first time a frame is seen; false for a repeat. Records the frame.
    public mutating func isNew(_ frame: CapturedFrame) -> Bool {
        if let buffer = frame.pixelBuffer, let last = lastBuffer, buffer === last { return false }
        if let time = frame.captureTime {
            guard seenTimes.insert(time).inserted else { return false }
        }
        if let buffer = frame.pixelBuffer { lastBuffer = buffer }
        return true
    }
}

/// Result of `evaluateEnrollmentConsistency` (ND-063b).
public struct EnrollmentConsistencyReport: Sendable, Equatable {
    /// The vectors that passed the outlier check, in their original order.
    public let kept: [[Float]]
    /// Indices (into the input) of the vectors dropped as outliers.
    public let droppedIndices: [Int]
    /// Median pairwise cosine of `kept`; 0 when fewer than 2 are kept.
    public let medianPairwise: Double
    /// All checks passed: enough kept, median at or above the floor, and not too many
    /// outliers.
    public let isConsistent: Bool
}

/// Consistency gate for enrollment vectors (ND-063b).
///
/// 1. Outliers: repeatedly drop the single vector with the lowest mean cosine to the
///    other remaining vectors, while that mean is below `outlierFloor` and more than two
///    remain. One vector is dropped at a time so a stranger's vectors do not pull down
///    the real user's means before the stranger is removed.
/// 2. The capture is consistent when at least `requiredVectors` remain, their median
///    pairwise cosine is at least `consistencyFloor`, and no more than
///    `maxOutlierFraction` of the input was dropped.
public func evaluateEnrollmentConsistency(
    _ vectors: [[Float]],
    requiredVectors: Int,
    outlierFloor: Double,
    consistencyFloor: Double,
    maxOutlierFraction: Double
) -> EnrollmentConsistencyReport {
    let n = vectors.count
    var sim = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n {
        for j in (i + 1)..<max(i + 1, n) {
            let s = cosineSimilarity(vectors[i], vectors[j])
            sim[i][j] = s
            sim[j][i] = s
        }
    }

    var active = Array(0..<n)
    var dropped: [Int] = []
    while active.count > 2 {
        var worst = -1
        var worstMean = Double.infinity
        for i in active {
            let others = active.filter { $0 != i }
            let mean = others.reduce(0.0) { $0 + sim[i][$1] } / Double(others.count)
            if mean < worstMean { worstMean = mean; worst = i }
        }
        guard worst >= 0, worstMean < outlierFloor else { break }
        active.removeAll { $0 == worst }
        dropped.append(worst)
    }

    var pairs: [Double] = []
    for a in 0..<active.count {
        for b in (a + 1)..<max(a + 1, active.count) { pairs.append(sim[active[a]][active[b]]) }
    }
    pairs.sort()
    let median: Double
    if pairs.isEmpty {
        median = 0
    } else if pairs.count % 2 == 1 {
        median = pairs[pairs.count / 2]
    } else {
        median = (pairs[pairs.count / 2 - 1] + pairs[pairs.count / 2]) / 2
    }

    let tooManyOutliers = n > 0 && Double(dropped.count) > maxOutlierFraction * Double(n)
    let consistent = requiredVectors > 0
        && active.count >= requiredVectors
        && median >= consistencyFloor
        && !tooManyOutliers
    return EnrollmentConsistencyReport(kept: active.map { vectors[$0] },
                                       droppedIndices: dropped.sorted(),
                                       medianPairwise: median,
                                       isConsistent: consistent)
}

private let enrollmentLog = Logger(subsystem: "com.nodonuts.app", category: "recognition")

/// Run one enrollment capture (ND-022 + ND-063): sample the camera, embed each DISTINCT
/// frame's face, stop once enough consistent vectors are in hand (or at the timeout),
/// and write them to `store` only when the set passes the consistency gate.
///
/// The caller must have stopped the presence loop (exclusive use of `capture()`) and
/// resumed the camera. The store is written only on `.success`. Every other outcome
/// leaves an existing enrollment as it was.
///
/// `now` and `sleep` are injected so EngineCheck can drive the timeout without waiting.
public func runEnrollmentCapture(
    camera: CameraCapturing,
    embedder: FaceEmbedding,
    store: EnrollmentStoring,
    policy: EnrollmentCapturePolicy? = nil,
    now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
) async -> EnrollmentCaptureOutcome {
    let policy = policy ?? EnrollmentCapturePolicy(descriptor: embedder.descriptor)
    let start = now()
    var deduper = EnrollmentFrameDeduper()
    var vectors: [[Float]] = []
    var frames = 0
    var distinctFrames = 0

    while true {
        if Task.isCancelled { return .cancelled }

        if case .frame(let frame) = await camera.capture() {
            frames += 1
            // Skip repeats BEFORE embedding: no wasted work, and one image can never
            // count as several references.
            if deduper.isNew(frame) {
                distinctFrames += 1
                // `.noFace` (including a face too small, ND-085) and `.failure` just mean
                // "try the next frame".
                if case .embedding(let v) = await embedder.embedding(for: frame) {
                    vectors.append(v)
                }
            }
        }
        // `.cameraBusyNoFrames` / `.suspended` / `.unavailable`: keep trying until the
        // no-frame or overall timeout.

        if Task.isCancelled { return .cancelled }

        if vectors.count >= policy.requiredVectors {
            let report = evaluateEnrollmentConsistency(vectors,
                                                       requiredVectors: policy.requiredVectors,
                                                       outlierFloor: policy.outlierFloor,
                                                       consistencyFloor: policy.consistencyFloor,
                                                       maxOutlierFraction: policy.maxOutlierFraction)
            if report.isConsistent { break }
        }
        if vectors.count >= policy.maxCollectedVectors { break }
        let elapsed = now() - start
        if elapsed >= policy.timeout { break }
        if frames == 0, elapsed >= policy.noFrameTimeout { break }

        await sleep(policy.pollSpacing)
    }

    if Task.isCancelled { return .cancelled }
    guard frames > 0 else { return .cameraUnavailable }
    guard vectors.count >= policy.requiredVectors else {
        enrollmentLog.notice("enrollment: \(vectors.count, privacy: .public) usable faces from \(distinctFrames, privacy: .public) distinct frames (need \(policy.requiredVectors, privacy: .public))")
        return .notEnoughFaces
    }

    let report = evaluateEnrollmentConsistency(vectors,
                                               requiredVectors: policy.requiredVectors,
                                               outlierFloor: policy.outlierFloor,
                                               consistencyFloor: policy.consistencyFloor,
                                               maxOutlierFraction: policy.maxOutlierFraction)
    guard report.isConsistent else {
        enrollmentLog.notice("enrollment rejected as inconsistent: \(vectors.count, privacy: .public) vectors, \(report.droppedIndices.count, privacy: .public) outliers, median pairwise \(report.medianPairwise, format: .fixed(precision: 3), privacy: .public) (floor \(policy.consistencyFloor, privacy: .public))")
        return .inconsistent
    }

    // ADR-0014: stamp with the active model's version. ND-102: the Keychain write can
    // block on an ACL prompt, so it runs detached (never on the main actor).
    let toStore = report.kept
    let version = embedder.descriptor.version
    // ND-093: validate the vector length against the model; 0 = unknown (Vision fallback).
    let dim = embedder.descriptor.outputDimension
    let expectedDimension: Int? = dim > 0 ? dim : nil
    do {
        try await Task.detached(priority: .userInitiated) {
            try store.enroll(embeddings: toStore, modelVersion: version, expectedDimension: expectedDimension)
        }.value
    } catch {
        return .saveFailed
    }
    enrollmentLog.notice("enrolled \(toStore.count, privacy: .public) vectors (\(report.droppedIndices.count, privacy: .public) outliers dropped, median pairwise \(report.medianPairwise, format: .fixed(precision: 3), privacy: .public))")
    return .success(count: toStore.count)
}
