import Foundation

// Owner: cooper — Vision detection + Core ML embeddings + matching.
// Backlog: ND-020, ND-021, ND-024. ADR-0002. Privacy: all on-device, no network.

/// Detects faces and decides whether the enrolled user is present in a frame.
public protocol FaceRecognizing: Sendable {
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult
}

/// Vision (detection) + Core ML (embedding) implementation. Stub.
///
/// `Sendable`: the presence engine (ADR-0005, `@MainActor`) awaits `recognize()`
/// from the main actor, so this type must be safe to hand across actors. Current
/// stored props are immutable. The real Vision/CoreML implementation (ND-020/ND-021)
/// MUST keep this thread-safe / `Sendable` and offload heavy detection/inference work
/// off the main actor (e.g. a detached task or dedicated queue) so the loop never blocks.
public final class VisionCoreMLRecognizer: FaceRecognizing, Sendable {
    private let store: EnrollmentStoring
    private let matchThreshold: Double

    public init(store: EnrollmentStoring, matchThreshold: Double) {
        self.store = store
        self.matchThreshold = matchThreshold
    }

    public func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        // TODO(cooper):
        //  1. VNDetectFaceRectanglesRequest -> face bounding boxes. None -> .noFace.
        //  2. For each face: Core ML embedding (128/512-d).
        //  3. Cosine similarity vs enrolled embeddings (store).
        //  4. max similarity >= matchThreshold -> .enrolledUserPresent; else .strangerOnly.
        //     (A non-matching face must NEVER count as present — EC-03.)
        return .error("VisionCoreMLRecognizer not implemented")
    }
}
