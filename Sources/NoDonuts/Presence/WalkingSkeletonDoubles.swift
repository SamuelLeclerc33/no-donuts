import Foundation

// Owner: homer — walking-skeleton fakes (ND-015).
// Temporary test doubles that let the app build and run end-to-end before the
// real camera and recognizer exist. They always report a present enrolled user.
// TODO: replace at ND-012 (real camera) / ND-025 (real recognizer).

/// Always yields a (placeholder) frame. TODO: replace at ND-012 (real camera).
public final class AlwaysPresentCamera: CameraCapturing, Sendable {
    public init() {}

    public func capture() async -> CaptureOutcome {
        .frame(CapturedFrame())
    }
}

/// Always reports the enrolled user as present. TODO: replace at ND-025 (real recognizer).
public final class AlwaysPresentRecognizer: FaceRecognizing, Sendable {
    public init() {}

    public func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        .enrolledUserPresent(confidence: 1)
    }
}
