import Foundation

// Owner: blart — camera capture, camera-in-use monitoring, display/session state.
// Backlog: ND-011, ND-012, ND-013, ND-031, ND-032.

/// Captures frames for the presence loop. Pulls a single frame per tick (not a
/// continuous stream) to save power, and reports when the camera is busy or the
/// session is suspended.
public protocol CameraCapturing {
    /// Attempt to obtain a frame for this tick. See CaptureOutcome for the cases.
    func capture() async -> CaptureOutcome
}

/// AVFoundation-backed implementation. Stub.
public final class CameraController: CameraCapturing {
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
