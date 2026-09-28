import Foundation

// Owner: blart — capture preset + frame-rate choice (ND-096). Pure policy; the
// AVFoundation calls live in CameraController, which feeds this plain values.

/// Which session preset and frame rate the presence camera asks for (ND-096).
///
/// Preset: the smallest standard preset that is at least 640×480. Recognition
/// needs a face ≥ `minimumFaceSideFraction` (12%) of the frame's shorter side;
/// at 480 px that is ~58 px, which FaceNet upscales ~2.8× to its 160 px input.
/// At a normal seated distance (40–80 cm) the face box is 25–60% of the frame
/// height (≈120–290 px at 480), so the gate and the embedder both have plenty of
/// pixels; only a face near the 2 m gate edge is upscaled heavily, and that face
/// is not at the keyboard anyway. Anything below 480 lines (352×288, 320×240)
/// would push the gate's floor to ~35 px and is not offered.
///
/// On the reference MacBook Pro camera 640×480 is a NATIVE 420v format (4:3, like
/// the sensor), so the preset is a mode switch, not a crop or rescale of 1080p.
///
/// Frame rate: the lowest rate the device supports, never below `targetFPS`.
/// The built-in camera only offers 15–30 fps, so in practice this is 15 fps
/// (the old code aimed at 1 fps and was clamped to 15 by the same range).
public enum CaptureFormatPolicy {
    /// Session presets in preference order (AVCaptureSession.Preset raw values;
    /// the Core target doesn't need AVFoundation types for this).
    public static let presetPreference: [String] = [
        "AVCaptureSessionPreset640x480",   // .vga640x480
        "AVCaptureSessionPreset960x540",   // .qHD960x540
        "AVCaptureSessionPreset1280x720",  // .hd1280x720
    ]

    /// We only sample one frame per tick (≥ 0.5s), so anything above 1 fps is
    /// wasted — but never go below what the device supports.
    public static let targetFPS: Double = 1

    /// First preset in `presetPreference` the session/device accepts, or nil
    /// (leave the session default).
    public static func preferredPreset(isSupported: (String) -> Bool) -> String? {
        presetPreference.first(where: isSupported)
    }

    /// Minimum shorter side (pixels) of a capture format; see the type doc.
    public static let minimumShortSide = 480

    /// Index of the device format to lock in alongside the preset: landscape
    /// (width ≥ height — the built-in camera also lists portrait formats), shorter
    /// side ≥ `minimumShortSide`, smallest pixel count; the first wins a tie.
    /// Nil when nothing qualifies (leave the preset's choice alone).
    public static func preferredFormatIndex(dimensions: [(width: Int, height: Int)]) -> Int? {
        dimensions.enumerated()
            .filter { $0.element.width >= $0.element.height && $0.element.height >= minimumShortSide }
            .min(by: { $0.element.width * $0.element.height < $1.element.width * $1.element.height })?
            .offset
    }

    /// A supported frame-rate range (frames per second).
    public struct RateRange: Equatable, Sendable {
        public let minFrameRate: Double
        public let maxFrameRate: Double
        public init(minFrameRate: Double, maxFrameRate: Double) {
            self.minFrameRate = minFrameRate
            self.maxFrameRate = maxFrameRate
        }
    }

    /// The chosen rate: `targetFPS` clamped into the range with the LOWEST
    /// minimum rate (not just the first range, which may be a fast one).
    /// Returns the index of that range (so the caller can use the device's own
    /// CMTime bounds) and the rate. Nil when no usable range exists — leave the
    /// device default.
    public static func lowestRate(in ranges: [RateRange]) -> (index: Int, fps: Double)? {
        let usable = ranges.enumerated().filter {
            $0.element.minFrameRate.isFinite && $0.element.maxFrameRate.isFinite
                && $0.element.minFrameRate > 0 && $0.element.maxFrameRate >= $0.element.minFrameRate
        }
        guard let best = usable.min(by: { $0.element.minFrameRate < $1.element.minFrameRate }) else {
            return nil
        }
        let fps = min(max(targetFPS, best.element.minFrameRate), best.element.maxFrameRate)
        return (best.offset, fps)
    }

    /// Tolerance (seconds) when comparing frame durations read back from the
    /// device against the pinned target (CMTime → Double rounding).
    public static let durationTolerance: Double = 0.0005

    /// Whether the device is actually pinned to `targetDuration`: BOTH the min
    /// and the max frame duration equal it. A min shorter than the max (e.g.
    /// 1/30…1/15 s) means the session reverted to the format's variable-rate
    /// default and the camera can run at the faster rate — re-pin. Non-finite or
    /// non-positive values (invalid CMTime) are never "pinned".
    public static func isPinned(minDuration: Double, maxDuration: Double, targetDuration: Double) -> Bool {
        guard minDuration.isFinite, maxDuration.isFinite, targetDuration.isFinite,
              minDuration > 0, maxDuration > 0, targetDuration > 0 else { return false }
        return abs(minDuration - targetDuration) <= durationTolerance
            && abs(maxDuration - targetDuration) <= durationTolerance
    }
}
