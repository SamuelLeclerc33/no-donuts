import Foundation

/// Freshness + negative-cache rules for the trusted-Wi-Fi router read (ND-081).
/// Pure (injected `now`) so the security-relevant part is EngineCheck-covered; the
/// App's WiFiMonitor owns the actual reads.
///
/// Rules:
///   - A successful read counts toward TRUST only if it was started in the current
///     generation (no invalidation since: poll / wake / Wi-Fi event / Trust click),
///     for the same key, and is at most `freshnessLimit` old. A key match alone never
///     reuses an old MAC: an evil twin can clone SSID + BSSID + gateway IP.
///   - A failed read is remembered per key for `negativeLifetime`, so repeated menu
///     opens don't re-spawn arp(8). `invalidate(clearFailures: true)` forgets them.
public struct RouterReadCache: Sendable {
    public enum Lookup: Equatable, Sendable {
        case fresh(String)
        case recentlyFailed
        case none
    }

    public let freshnessLimit: TimeInterval
    public let negativeLifetime: TimeInterval
    public private(set) var generation = 0

    private var verified: (key: String, generation: Int, at: Date, mac: String)?
    private var failedAt: [String: Date] = [:]

    public init(freshnessLimit: TimeInterval = 25, negativeLifetime: TimeInterval = 30) {
        self.freshnessLimit = freshnessLimit
        self.negativeLifetime = negativeLifetime
    }

    /// Start a new generation: every earlier read stops counting toward trust.
    public mutating func invalidate(clearFailures: Bool) {
        generation += 1
        if clearFailures { failedAt.removeAll() }
    }

    /// Forget a failure for one key (retry after DHCP/ARP settle).
    public mutating func clearFailure(for key: String) {
        failedAt[key] = nil
    }

    /// Record a read that was STARTED in `generation`. Returns false (and records
    /// nothing) when it's stale: started before the last invalidation.
    @discardableResult
    public mutating func record(key: String, generation readGeneration: Int, mac: String?, now: Date) -> Bool {
        guard readGeneration == generation else { return false }
        if let mac {
            verified = (key, readGeneration, now, mac)
            failedAt[key] = nil
        } else {
            failedAt[key] = now
            if verified?.key == key { verified = nil }
        }
        return true
    }

    public func lookup(key: String, now: Date) -> Lookup {
        if let v = verified, v.key == key, v.generation == generation,
           now.timeIntervalSince(v.at) <= freshnessLimit, now >= v.at {
            return .fresh(v.mac)
        }
        if let t = failedAt[key], now.timeIntervalSince(t) < negativeLifetime, now >= t {
            return .recentlyFailed
        }
        return .none
    }
}
