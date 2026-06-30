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
}

/// Result of one recognition pass on a captured frame (owner: cooper).
public enum RecognitionResult: Equatable {
    case enrolledUserPresent(confidence: Double)
    case strangerOnly           // face(s) detected, none match the enrolled user
    case noFace
    case error(String)
}

/// What the camera layer could obtain this tick (owner: blart).
public enum CaptureOutcome {
    case frame(CapturedFrame)
    case cameraBusyNoFrames     // another app holds the device, no shared frames (ADR-0003)
    case suspended              // screen locked/asleep/inactive — skip work
    case unavailable(String)    // no camera / permission denied / hardware error (EC-08/09)
}

/// Opaque wrapper around a single captured frame. TODO(blart): back with CVPixelBuffer.
public struct CapturedFrame {
    // Placeholder. Real implementation wraps a CVPixelBuffer / CMSampleBuffer.
}
