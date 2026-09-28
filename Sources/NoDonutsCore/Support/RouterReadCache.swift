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
///   - PERIODIC re-verification (`reverify`, the 15 s poll) is the one exception to
///     "pending = not trusted": if the current generation holds a fresh verified read,
///     that MAC is HELD for the same key for at most `holdWindow` while the re-read is
///     pending (`.held`). Without it the gate flips to "not trusted" for the length of
///     every re-read and the camera turns on every 15 s on a trusted network. The hold
///     ends at once when the re-read lands (success → `.fresh` with the NEW MAC, so a
///     mismatch is untrusted immediately; failure → `.recentlyFailed`), on any other
///     invalidation (Wi-Fi event / wake / Trust click never hold), on a key change, or
///     when the window expires (→ `.none`, not trusted). A hold is never chained: the
///     next poll can only hold from a read that actually landed.
public struct RouterReadCache: Sendable {
    public enum Lookup: Equatable, Sendable {
        case fresh(String)
        /// Previous verified MAC held during a periodic re-read (still re-read it).
        case held(String)
        case recentlyFailed
        case none
    }

    public let freshnessLimit: TimeInterval
    public let negativeLifetime: TimeInterval
    public let holdWindow: TimeInterval
    public private(set) var generation = 0

    private var verified: (key: String, generation: Int, at: Date, mac: String)?
    private var hold: (key: String, generation: Int, from: Date, mac: String)?
    private var failedAt: [String: Date] = [:]

    public init(freshnessLimit: TimeInterval = 25, negativeLifetime: TimeInterval = 30,
                holdWindow: TimeInterval = 5) {
        self.freshnessLimit = freshnessLimit
        self.negativeLifetime = negativeLifetime
        self.holdWindow = holdWindow
    }

    /// Start a new generation: every earlier read stops counting toward trust. No hold
    /// (Wi-Fi event, wake, Trust click): fail-safe until a fresh read lands.
    public mutating func invalidate(clearFailures: Bool) {
        generation += 1
        hold = nil
        if clearFailures { failedAt.removeAll() }
    }

    /// Periodic re-verification (15 s poll): new generation, failures kept, and the
    /// current fresh verified read (if any) is held for `holdWindow` while re-reading.
    public mutating func reverify(now: Date) {
        let prior = verified.flatMap { v -> (key: String, generation: Int, from: Date, mac: String)? in
            guard v.generation == generation, now >= v.at,
                  now.timeIntervalSince(v.at) <= freshnessLimit,
                  failedAt[v.key] == nil else { return nil }
            return (v.key, generation + 1, now, v.mac)
        }
        invalidate(clearFailures: false)
        hold = prior
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
        if hold?.key == key { hold = nil }   // the re-read landed: its result decides
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
        if let h = hold, h.key == key, h.generation == generation,
           now >= h.from, now.timeIntervalSince(h.from) < holdWindow {
            return .held(h.mac)
        }
        return .none
    }
}
