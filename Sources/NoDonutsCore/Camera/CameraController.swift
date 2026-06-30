import Foundation

// Owner: blart — camera capture, camera-in-use monitoring, display/session state.
// Backlog: ND-011, ND-012, ND-013, ND-031, ND-032.

/// Captures frames for the presence loop. Pulls a single frame per tick (not a
/// continuous stream) to save power, and reports when the camera is busy or the
/// session is suspended.
public protocol CameraCapturing: Sendable {
    /// Attempt to obtain a frame for this tick. See CaptureOutcome for the cases.
    func capture() async -> CaptureOutcome
}

/// AVFoundation-backed implementation. Stub.
///
/// `Sendable` because the engine (a `@MainActor` `PresenceEngine`, ADR-0005)
/// awaits `capture()` across actor isolation. This stub has no stored mutable
/// state, so the conformance is sound today. When the real
/// AVCaptureSession-backed implementation lands (ND-012), it MUST stay
/// thread-safe / `Sendable` — e.g. funnel session access through an internal
/// serial queue, or declare `@unchecked Sendable` and guard mutable state
/// manually — since `capture()` is still invoked from the main actor.
public final class CameraController: CameraCapturing, Sendable {
    public init() {}

    public func capture() async -> CaptureOutcome {
        // TODO(blart):
        //  1. If screen locked / display asleep / session inactive -> .suspended (EC-02, EC-13).
        //  2. If camera permission denied/restricted/no device -> .unavailable (EC-08, EC-09).
        //  3. If another app holds the camera: attempt multi-client capture (ND-032).
        //       got a frame -> .frame; couldn't -> .cameraBusyNoFrames (ADR-0003).
        //  4. Otherwise grab one frame via AVCaptureSession -> .frame.
        return .unavailable("CameraController not implemented")
    }
}
