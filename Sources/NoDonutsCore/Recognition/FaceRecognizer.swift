import Foundation

// Owner: cooper — Vision detection + Core ML embeddings + matching.
// Backlog: ND-020, ND-021, ND-024. ADR-0002. Privacy: all on-device, no network.

/// Detects faces and decides whether the enrolled user is present in a frame.
public protocol FaceRecognizing: Sendable {
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult
}

/// Identity recognizer (ND-021/ND-024, ADR-0012): decides whether the *enrolled*
/// user — not just any face — is present, using a `FaceEmbedding` + cosine matching.
///
/// Fully dependency-injected so it is unit-testable **without** Vision, a camera, or
/// the Keychain: pass a fake `FaceEmbedding` and an `InMemoryEnrollmentStore`.
///
/// The embedder returns a tri-state `FaceEmbeddingOutcome`: `.embedding` (a face was
/// found + embedded), `.noFace` (Vision ran, no face), or `.failure` (detection / crop /
/// feature-print error). The recognizer must NOT collapse `.failure` into `.noFace`: a
/// `.failure` maps to `RecognitionResult.error`, which the presence engine holds
/// conservatively (EC-10) rather than counting toward the absence consensus — so a
/// transient Vision glitch can't lock a present user.
///
/// The store returns a tri-state `EnrollmentState`: `.enrolled`, `.notEnrolled`, or
/// `.unavailable` (Keychain read failed). `.unavailable` maps to `.error` (fail-safe) —
/// it must NEVER downgrade to the presence-only fallback (that would let any face pass
/// on an enrolled machine, S1 / EC-03).
///
/// Decision table (one `enrollmentState()` read + one embed per call):
/// - store `.unavailable`                          → `.error` (fail-safe; engine holds, sustained → lock)
/// - embed `.failure`                              → `.error` (EC-10 hold)
/// - embed `.noFace`                               → `.noFace`
/// - embed `.embedding`, store `.notEnrolled`      → `.enrolledUserPresent(1.0)` (presence-only, only when GENUINELY not enrolled)
/// - embed `.embedding`, store `.enrolled(refs)`   → max cosine vs refs; `>= threshold`
///     → `.enrolledUserPresent(max)`, else `.strangerOnly` (EC-03: non-match never present)
///
/// `Sendable`: the presence engine (ADR-0005, `@MainActor`) awaits `recognize()` from
/// the main actor. No main-actor work happens here — the heavy lifting is inside the
/// injected `FaceEmbedding`, which offloads to its own queue.
public final class IdentityRecognizer: FaceRecognizing, Sendable {
    private let embedder: FaceEmbedding
    private let store: EnrollmentStoring
    private let matchThreshold: Double

    public init(embedder: FaceEmbedding, store: EnrollmentStoring, matchThreshold: Double) {
        self.embedder = embedder
        self.store = store
        self.matchThreshold = matchThreshold
    }

    public func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        // ONE Keychain read per tick. A read failure is fail-safe: .error (never
        // presence-only), so a stranger can't pass on an enrolled machine (S1/EC-03).
        let state = store.enrollmentState()
        if case .unavailable = state {
            return .error("enrollment store unavailable")
        }

        switch await embedder.embedding(for: frame) {
        case .failure:
            // Transient detection/embedding failure → conservative HOLD (EC-10), not absence.
            return .error("face embedding failed")
        case .noFace:
            return .noFace
        case .embedding(let vector):
            switch state {
            case .notEnrolled:
                // Presence-only fallback — only when GENUINELY not enrolled (non-breaking).
                return .enrolledUserPresent(confidence: 1.0)
            case .enrolled(let references):
                // Defensive: enrolled-but-empty shouldn't happen; presence-only rather
                // than lock out the real user.
                guard !references.isEmpty else { return .enrolledUserPresent(confidence: 1.0) }
                let maxSim = references.reduce(0.0) { best, ref in
                    max(best, cosineSimilarity(vector, ref))
                }
                // EC-03: a detected face that doesn't clear the threshold is NEVER present.
                return maxSim >= matchThreshold
                    ? .enrolledUserPresent(confidence: maxSim)
                    : .strangerOnly
            case .unavailable:
                return .error("enrollment store unavailable")   // already handled above; exhaustive
            }
        }
    }
}
