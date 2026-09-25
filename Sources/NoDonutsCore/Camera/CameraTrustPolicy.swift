import Foundation

// Owner: blart — ND-075 camera trust (built-in only).
//
// Pure, AVFoundation-free policy so it is checkable by EngineCheck.
//
// Decision (user, ND-075): only the Mac's own built-in camera is trusted.
// External USB, Continuity, and virtual (OBS / CMIO extension) cameras are
// never used — a virtual camera can feed a recording of the enrolled user,
// and an external one can be pointed anywhere. With no trusted device the
// controller reports `.unavailable(CameraTrustPolicy.noTrustedCameraReason)`;
// it never fails open onto an untrusted camera.

/// Decides whether a capture device may be used for presence decisions.
public enum CameraTrustPolicy {
    /// `.unavailable` reason when no trusted camera exists. The UI (krusty)
    /// matches on this exact string, so change both together.
    public static let noTrustedCameraReason =
        "no trusted built-in camera (external/virtual cameras are not trusted)"

    /// `'bltn'` — the transport type AVFoundation reports for the built-in
    /// camera (`AVCaptureDevice.transportType`). Same value as
    /// `kIOAudioDeviceTransportTypeBuiltIn` from IOKit/audio/IOAudioTypes.h;
    /// the controller cross-checks against that constant. Verified on
    /// macOS 27 (Darwin 27): the MacBook Pro Camera reports 0x626C746E ('bltn'),
    /// a USB webcam reports 'usb '.
    public static let builtInTransportType: Int32 = 0x626C_746E // 'bltn'

    /// Trusted iff the device is BOTH of built-in type
    /// (`.builtInWideAngleCamera`) AND on the built-in transport. Requiring
    /// both is defense in depth: a virtual/DAL device could claim a built-in
    /// device type, but would also have to fake the transport.
    public static func isTrusted(deviceTypeIsBuiltIn: Bool, transportIsBuiltIn: Bool) -> Bool {
        deviceTypeIsBuiltIn && transportIsBuiltIn
    }

    /// Render a transport type as its four-character code (e.g. "bltn",
    /// "usb "), for logs. Non-printable bytes fall back to hex.
    public static func fourCC(_ value: Int32) -> String {
        let u = UInt32(bitPattern: value)
        let bytes = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return s
        }
        return String(format: "0x%08X", u)
    }
}
