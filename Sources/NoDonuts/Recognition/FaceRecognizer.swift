import Foundation

// Owner: cooper — Vision detection + Core ML embeddings + matching.
// Backlog: ND-020, ND-021, ND-024. ADR-0002. Privacy: all on-device, no network.

/// Detects faces and decides whether the enrolled user is present in a frame.
public protocol FaceRecognizing {
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult
}

/// Vision (detection) + Core ML (embedding) implementation. Stub.
public final class VisionCoreMLRecognizer: FaceRecognizing {
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
