import Foundation
import NoDonutsCore

// Owner: krusty — localized display of user-visible strings that NoDonutsCore produces
// in English (ND-101 follow-up).
//
// Core stays English on purpose: EngineCheck asserts its exact strings, and diagnostics
// (DiagnosticsReporter) and logs keep the English originals. The UI maps the KNOWN Core
// values to localized strings here. An unrecognized value (a new or reworded Core
// string) is shown as-is, so the user is never shown a blank or a wrong message. If you
// change a string in Core, update the matching case here.
enum CoreStrings {

    // MARK: - Protection audit (ND-077, `reducedProtectionReasons`)

    /// One reason from `reducedProtectionReasons(descriptor:defaults:)`, localized.
    static func protectionReason(_ reason: String) -> String {
        if reason == "anti-spoof off" {
            return String(localized: "photo rejection (anti-spoofing) off")
        }
        if let (value, fallback) = lowered(reason, prefix: "match threshold lowered") {
            return String(localized: "lock sensitivity lowered (\(value), default \(fallback))")
        }
        if let (value, fallback) = lowered(reason, prefix: "anti-spoof floor lowered") {
            return String(localized: "photo-rejection floor lowered (\(value), default \(fallback))")
        }
        return reason
    }

    /// Parses "<prefix> (<value> < default <default>)" and re-formats both numbers for
    /// the user's locale. nil when the reason doesn't have that exact shape.
    private static func lowered(_ reason: String, prefix: String) -> (String, String)? {
        let head = prefix + " ("
        guard reason.hasPrefix(head), reason.hasSuffix(")") else { return nil }
        let inner = reason.dropFirst(head.count).dropLast()
        let parts = inner.components(separatedBy: " < default ")
        guard parts.count == 2,
              let value = Double(parts[0]), let fallback = Double(parts[1]) else { return nil }
        return (localizedNumber(value), localizedNumber(fallback))
    }

    /// Up to 4 decimals, in the user's locale ("0,35" in French). Core's POSIX
    /// formatting uses the same precision.
    private static func localizedNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }

    // MARK: - Camera unavailable reasons (`CameraController.lastUnavailableReason`)

    /// A camera `.unavailable` / configure-failure reason, localized.
    static func cameraUnavailableReason(_ reason: String) -> String {
        switch reason {
        case CameraTrustPolicy.noTrustedCameraReason:
            return String(localized: "no trusted built-in camera (external and virtual cameras aren\u{2019}t trusted)")
        case "camera permission not yet granted":
            return String(localized: "camera permission not granted yet")
        case "camera access denied/restricted":
            return String(localized: "camera access denied or restricted")
        case "camera access in unknown state":
            return String(localized: "camera access state unknown")
        case "no fresh frame":
            return String(localized: "no new image from the camera")
        case "cannot open camera input":
            return String(localized: "can\u{2019}t open the camera")
        case "cannot add camera output":
            return String(localized: "can\u{2019}t read images from the camera")
        case "cannot start camera session":
            return String(localized: "can\u{2019}t start the camera")
        default:
            return reason
        }
    }
}
