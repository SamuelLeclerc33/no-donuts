import Foundation

/// One trusted-Wi-Fi entry (ND-081): the SSID plus the MAC address of the default
/// gateway (router) that was seen when the user clicked Trust. A network with several
/// routers (mesh, office floors) gets one entry per router the user trusted on.
///
/// `gatewayMAC == nil` is a LEGACY entry migrated from the SSID-only list (ND-036).
/// It never makes a network trusted; the menu asks the user to re-confirm on the
/// real router (`needsReTrust`).
public struct TrustedNetwork: Hashable, Sendable, Identifiable {
    public let ssid: String
    /// Canonical MAC (`MACAddress` form), or nil for a legacy SSID-only entry.
    public let gatewayMAC: String?

    public init(ssid: String, gatewayMAC: String?) {
        self.ssid = ssid
        self.gatewayMAC = gatewayMAC
    }

    /// Legacy SSID-only entry: must be re-confirmed before it trusts anything.
    public var needsReTrust: Bool { gatewayMAC == nil }

    public var id: String { "\(ssid)|\(gatewayMAC ?? "legacy")" }
}

/// Where the current network stands relative to the trusted list. Drives the menu
/// label only; enforcement uses `isTrusted(ssid:gatewayMAC:)` alone.
public enum TrustedNetworkStatus: Equatable, Sendable {
    /// SSID and router MAC both match an entry → enforcement paused.
    case trusted
    /// Only a legacy SSID-only entry exists for this SSID → enforcement ON until the
    /// user re-confirms on this router.
    case needsReTrust
    /// The SSID is trusted on other router(s), not this one (or this router can't be
    /// read) → enforcement ON. Could be a second router, or a hotspot copying the SSID.
    case otherRouter
    /// Not in the list at all.
    case notTrusted
}

/// Persists user-trusted Wi-Fi networks as {SSID, gateway MAC} pairs (ND-036 → ND-081).
/// Pure, testable Core logic: no AppKit, no CoreWLAN. The App layer reads the SSID
/// and the router's MAC and asks this store.
///
/// Fail-safe: trusted only when BOTH a non-empty SSID and a readable gateway MAC match
/// one entry. nil/empty SSID, nil/invalid MAC, a legacy SSID-only entry, or a
/// different router → NOT trusted → enforcement stays ON.
///
/// Migration (ND-081): the pre-ND-081 list (`trustedWiFiSSIDs`, [String]) is folded in
/// on first read as legacy entries (`gatewayMAC == nil`) and the old key is removed.
/// Legacy entries are deliberately NOT auto-bound to whatever router is present at
/// upgrade time, since that router could be a hotspot copying the SSID.
///
/// Privacy: SSIDs and router MACs are stored locally in UserDefaults only, never
/// transmitted; diagnostics report counts only. See docs/SECURITY_PRIVACY.md.
public final class TrustedNetworksStore {
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String

    static let ssidField = "ssid"
    static let macField = "gatewayMAC"

    public init(defaults: UserDefaults = .standard,
                key: String = "trustedWiFiNetworks",
                legacyKey: String = "trustedWiFiSSIDs") {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    /// All entries, sorted by SSID then MAC (legacy first). Runs the legacy migration.
    public func all() -> [TrustedNetwork] {
        migrateLegacyIfNeeded()
        return read().sorted {
            ($0.ssid, $0.gatewayMAC ?? "") < ($1.ssid, $1.gatewayMAC ?? "")
        }
    }

    /// Number of entries (diagnostics: a count, never names).
    public var count: Int { all().count }

    /// Number of legacy entries still waiting for a re-confirm (diagnostics).
    public var needsReTrustCount: Int { all().filter(\.needsReTrust).count }

    /// Trust `ssid` on the router `gatewayMAC`. Refuses (returns false) without a
    /// non-empty SSID and a valid MAC, since an entry we can't verify is useless.
    /// Also drops any legacy entry for the SSID: this click IS the re-confirm.
    @discardableResult
    public func trust(ssid: String, gatewayMAC: String?) -> Bool {
        guard !ssid.isEmpty, let mac = gatewayMAC.flatMap(MACAddress.normalize) else { return false }
        var entries = Set(all())
        entries.remove(TrustedNetwork(ssid: ssid, gatewayMAC: nil))
        entries.insert(TrustedNetwork(ssid: ssid, gatewayMAC: mac))
        persist(entries)
        return true
    }

    /// Untrust the current network: removes the entry for this SSID + router and any
    /// legacy entry for the SSID. Other routers of the same SSID stay (Settings can
    /// remove them individually).
    public func untrust(ssid: String, gatewayMAC: String?) {
        var entries = Set(all())
        entries.remove(TrustedNetwork(ssid: ssid, gatewayMAC: nil))
        if let mac = gatewayMAC.flatMap(MACAddress.normalize) {
            entries.remove(TrustedNetwork(ssid: ssid, gatewayMAC: mac))
        }
        persist(entries)
    }

    /// Remove one entry (Settings list).
    public func remove(_ network: TrustedNetwork) {
        var entries = Set(all())
        entries.remove(network)
        persist(entries)
    }

    /// THE trust check (single path used by enforcement). True only when a non-empty
    /// SSID and a valid gateway MAC match one bound entry. Everything else → false.
    public func isTrusted(ssid: String?, gatewayMAC: String?) -> Bool {
        guard let ssid, !ssid.isEmpty,
              let mac = gatewayMAC.flatMap(MACAddress.normalize) else { return false }
        return contains(TrustedNetwork(ssid: ssid, gatewayMAC: mac))
    }

    /// Menu-label status for the current network. `.trusted` comes only from
    /// `isTrusted(ssid:gatewayMAC:)`, so the label can't disagree with enforcement.
    public func status(ssid: String?, gatewayMAC: String?) -> TrustedNetworkStatus {
        guard let ssid, !ssid.isEmpty else { return .notTrusted }
        if isTrusted(ssid: ssid, gatewayMAC: gatewayMAC) { return .trusted }
        let forSSID = all().filter { $0.ssid == ssid }
        if forSSID.contains(where: \.needsReTrust) { return .needsReTrust }
        return forSSID.isEmpty ? .notTrusted : .otherRouter
    }

    /// Exact-entry membership. Internal on purpose: callers go through
    /// `isTrusted(ssid:gatewayMAC:)` so there is one trust path (ND-081 follow-up).
    func contains(_ network: TrustedNetwork) -> Bool {
        all().contains(network)
    }

    // MARK: - Persistence

    /// Fold the pre-ND-081 SSID-only list into the new list as legacy entries, then
    /// delete the old key. An SSID that already has any entry isn't duplicated.
    /// Idempotent: a no-op once the old key is gone.
    func migrateLegacyIfNeeded() {
        guard let legacy = defaults.array(forKey: legacyKey) else { return }
        var entries = Set(read())
        let known = Set(entries.map(\.ssid))
        for case let ssid as String in legacy where !ssid.isEmpty && !known.contains(ssid) {
            entries.insert(TrustedNetwork(ssid: ssid, gatewayMAC: nil))
        }
        persist(entries)
        defaults.removeObject(forKey: legacyKey)
    }

    /// Decode stored entries. Malformed items are skipped; a present-but-invalid MAC
    /// decodes as legacy (never trusted), so a hand-edited value fails safe.
    private func read() -> [TrustedNetwork] {
        guard let raw = defaults.array(forKey: key) else { return [] }
        return raw.compactMap { item in
            guard let dict = item as? [String: Any],
                  let ssid = dict[Self.ssidField] as? String, !ssid.isEmpty else { return nil }
            let mac = (dict[Self.macField] as? String).flatMap(MACAddress.normalize)
            return TrustedNetwork(ssid: ssid, gatewayMAC: mac)
        }
    }

    private func persist(_ entries: Set<TrustedNetwork>) {
        let sorted = entries.sorted {
            ($0.ssid, $0.gatewayMAC ?? "") < ($1.ssid, $1.gatewayMAC ?? "")
        }
        let plist: [[String: String]] = sorted.map { entry in
            var dict = [Self.ssidField: entry.ssid]
            if let mac = entry.gatewayMAC { dict[Self.macField] = mac }
            return dict
        }
        defaults.set(plist, forKey: key)
    }
}
