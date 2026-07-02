import Foundation

/// Persists the set of user-trusted Wi-Fi SSIDs (ND-036). Pure, testable Core
/// logic: no AppKit, no CoreWLAN — the App layer reads the current SSID and asks
/// this store whether it's trusted.
///
/// Fail-safe: a nil or empty SSID is NEVER trusted (`isTrusted` returns false),
/// so if the App layer can't read the SSID (Location denied, hardware, etc.)
/// enforcement stays ON — we never stop protecting because the check failed.
///
/// Privacy: SSIDs are stored locally in UserDefaults only, never transmitted.
/// See docs/SECURITY_PRIVACY.md.
public final class TrustedNetworksStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "trustedWiFiSSIDs") {
        self.defaults = defaults
        self.key = key
    }

    /// All trusted SSIDs, sorted (stable order for menu display).
    public func all() -> [String] {
        (defaults.array(forKey: key) as? [String] ?? []).sorted()
    }

    /// Whether the given SSID is in the trusted set.
    public func contains(_ ssid: String) -> Bool {
        all().contains(ssid)
    }

    /// Add an SSID to the trusted set (no-op for empty/duplicate).
    public func add(_ ssid: String) {
        guard !ssid.isEmpty else { return }
        var set = Set(all())
        set.insert(ssid)
        persist(set)
    }

    /// Remove an SSID from the trusted set.
    public func remove(_ ssid: String) {
        var set = Set(all())
        set.remove(ssid)
        persist(set)
    }

    /// Fail-safe trust check: nil or empty SSID → NOT trusted → enforcement
    /// stays on. Only a known, non-empty, explicitly-trusted SSID returns true.
    public func isTrusted(_ ssid: String?) -> Bool {
        guard let ssid, !ssid.isEmpty else { return false }
        return contains(ssid)
    }

    private func persist(_ set: Set<String>) {
        defaults.set(set.sorted(), forKey: key)
    }
}
