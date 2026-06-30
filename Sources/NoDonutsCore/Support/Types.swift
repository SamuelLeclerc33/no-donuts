import Foundation

// Shared types used across modules. Owner: shared (keep dependency-light).

/// High-level presence state produced by the Presence engine (owner: homer).
public enum PresenceState: Equatable {
    case unknown                // startup, no reading yet
    case present                // enrolled user matched
    case absent                 // no enrolled user (no face, or stranger only)
    case paused                 // user paused the app
    case callAssumedPresent     // camera busy, no frames -> assume present (ADR-0003)
    case suspended              // screen locked / display asleep / session inactive
    case lockFailed             // lock was attempted but failed (e.g. Accessibility not granted) — honest status, EC-19
}

/// Result of one recognition pass on a captured frame (owner: cooper).
public enum RecognitionResult: Equatable, Sendable {
    case enrolledUserPresent(confidence: Double)
    case strangerOnly           // face(s) detected, none match the enrolled user
    case noFace
    case error(String)
}

/// What the camera layer could obtain this tick (owner: blart).
public enum CaptureOutcome: Sendable {
    case frame(CapturedFrame)
    case cameraBusyNoFrames     // another app holds the device, no shared frames (ADR-0003)
    case suspended              // screen locked/asleep/inactive — skip work
    case unavailable(String)    // no camera / permission denied / hardware error (EC-08/09)
}

/// Opaque wrapper around a single captured frame. TODO(blart): back with CVPixelBuffer.
/// `Sendable` because it crosses the main-actor boundary (engine awaits camera/recognizer,
/// ADR-0005). When backed by a CVPixelBuffer/CMSampleBuffer, preserve this via an immutable
/// wrapper or `@unchecked Sendable` with a defensive copy.
public struct CapturedFrame: Sendable {
    // Placeholder. Real implementation wraps a CVPixelBuffer / CMSampleBuffer.
    public init() {}
}
