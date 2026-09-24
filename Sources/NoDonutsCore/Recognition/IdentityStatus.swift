import Foundation

// Owner: cooper — identity-status surfacing (ND-073, ADR-0014).
// Privacy: this file handles ONLY model version strings — never embeddings or images.

/// Why identity recognition is OFF even though the user has (or had) an enrollment.
///
/// In both cases the recognizer deliberately stays in the presence-only fallback (any
/// face keeps the Mac unlocked — no lockout loop), and the App must surface this loudly
/// so the user re-enrolls. See ND-073.
public enum IdentityOffReason: Equatable, Sendable {
    /// The stored enrollment was produced by a different embedding model than the active
    /// one (a model swap, the Core ML model missing → Vision fallback, or a legacy `nil`
    /// pre-versioning record). Vectors from different models are never cross-compared
    /// (ADR-0014).
    case modelMismatch(stored: String?, active: String)
    /// The enrollment marker says the user enrolled under `expected`, but the store reads
    /// back as not enrolled — i.e. the Keychain item was deleted outside the app.
    case enrollmentMissing(expected: String)
}

/// Identity-recognition status as the App should present it (ND-073).
public enum IdentityStatus: Equatable, Sendable {
    /// Genuinely never enrolled (no stored enrollment, no marker) — presence-only is expected.
    case notEnrolled
    /// Enrolled under the active model — identity matching is in effect.
    case active
    /// Identity is OFF (presence-only) for the given reason — surface loudly, prompt re-enroll.
    case off(IdentityOffReason)
    /// Not yet known, or the enrollment store could not be read (`.unavailable`).
    case unknown

    /// `true` when identity is off and the user must re-enroll.
    public var isOff: Bool {
        if case .off = self { return true }
        return false
    }

    /// `true` when a stored enrollment exists (so e.g. a Reset action makes sense):
    /// `.active`, or `.off(.modelMismatch)` (stale vectors still in the store).
    public var hasStoredEnrollment: Bool {
        switch self {
        case .active, .off(.modelMismatch): return true
        case .notEnrolled, .off(.enrollmentMissing), .unknown: return false
        }
    }
}

/// Pure mapping from an enrollment read + active model version + marker to an
/// `IdentityStatus` (ND-073). No I/O — trivially testable.
///
/// - `.enrolled` with `modelVersion == activeVersion` → `.active` (marker irrelevant)
/// - `.enrolled` with a different or `nil` (legacy) version → `.off(.modelMismatch)`
/// - `.notEnrolled`, no marker → `.notEnrolled`
/// - `.notEnrolled`, marker set → `.off(.enrollmentMissing(expected: marker))`
/// - `.unavailable` → `.unknown`
public func identityStatus(for state: EnrollmentState, activeVersion: String, markerVersion: String?) -> IdentityStatus {
    switch state {
    case .enrolled(_, let storedVersion):
        return storedVersion == activeVersion
            ? .active
            : .off(.modelMismatch(stored: storedVersion, active: activeVersion))
    case .notEnrolled:
        if let marker = markerVersion { return .off(.enrollmentMissing(expected: marker)) }
        return .notEnrolled
    case .unavailable:
        return .unknown
    }
}

/// Persists a NON-secret "the user has enrolled" marker (ND-073).
///
/// The marker holds ONLY the model version string the user enrolled under — no
/// biometric data, no embedding, nothing sensitive. It exists so that a Keychain
/// enrollment item deleted outside the app (which reads back as `.notEnrolled`) is
/// distinguishable from a machine that was never enrolled, and can be surfaced as
/// `.off(.enrollmentMissing)` instead of silently degrading to presence-only.
///
/// It is tamperable by design (`defaults delete` clears it): it raises the bar against
/// silent degradation, it is not a security control. Tamper visibility is ND-077.
public protocol EnrollmentMarkerStoring: Sendable {
    /// The model version recorded at the last successful enrollment, or `nil` if none.
    var markerVersion: String? { get }
    /// Record a successful enrollment under `version`.
    func setMarker(_ version: String)
    /// Remove the marker (in-app Reset).
    func clearMarker()
}

/// `UserDefaults`-backed marker (key `enrollmentMarkerModelVersion`). In the bundled app
/// `.standard` resolves to the `com.nodonuts.app` domain.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe and this class holds
/// no other mutable state.
public final class UserDefaultsEnrollmentMarker: EnrollmentMarkerStoring, @unchecked Sendable {
    public static let key = "enrollmentMarkerModelVersion"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var markerVersion: String? { defaults.string(forKey: Self.key) }
    public func setMarker(_ version: String) { defaults.set(version, forKey: Self.key) }
    public func clearMarker() { defaults.removeObject(forKey: Self.key) }
}

/// In-memory marker for tests (EngineCheck). Lock-guarded.
public final class InMemoryEnrollmentMarker: EnrollmentMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var version: String?

    public init(_ version: String? = nil) {
        self.version = version
    }

    public var markerVersion: String? {
        lock.lock(); defer { lock.unlock() }
        return version
    }
    public func setMarker(_ version: String) {
        lock.lock(); defer { lock.unlock() }
        self.version = version
    }
    public func clearMarker() {
        lock.lock(); defer { lock.unlock() }
        version = nil
    }
}
