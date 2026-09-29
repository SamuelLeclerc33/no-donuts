import Foundation

// Owner: cooper — ND-119 enrollment drift warning (EC-04/EC-05 appearance change).
//
// When the enrolled user's appearance changes (beard shaved, new glasses, haircut),
// genuine scores slide toward the match threshold and the ADR-0017 stranger fast
// path starts locking the real user. This monitor detects that drift so the app can
// SUGGEST a re-enroll. It is advisory only:
//   - it never changes the lock policy, and
//   - it never adapts the enrollment templates from live scores. Auto-adaptation
//     would let a patient spoof "teach" the template (poisoning), so re-enrolling
//     stays an explicit user action.
//
// Pure value type: every method takes `now`; no clock is read here. Scores and lock
// times live in memory only. They are never persisted, logged, or sent anywhere.

/// Why the monitor thinks the enrollment is stale (ND-119).
public enum EnrollmentDriftReason: Equatable, Sendable {
    /// The mean of (score − threshold-at-sample) over the rolling window is below
    /// `Config.driftMarginThreshold`. The user is recognized, but only barely.
    case lowMargin(meanMargin: Double)
    /// At least `Config.driftStrangerLockCount` stranger-driven auto-locks, each
    /// within `Config.driftStrangerLockAfterUnlockSeconds` of an unlock, inside
    /// `Config.driftStrangerLockWindowSeconds`.
    case repeatedStrangerLocks(count: Int)
}

/// Rolling detector for recognition drift (ND-119). Feed it live-verified
/// `.enrolledUserPresent` scores and stranger-driven auto-locks, then call
/// `evaluate(now:)`. Reset it after a successful re-enroll.
public struct EnrollmentDriftMonitor: Sendable {
    /// Hard cap on stored match samples, whatever the window and tick cadence.
    /// The window prune alone keeps ~300 at the 1 s default tick; this bounds memory
    /// at the 0.5 s tick floor × 30 min window ceiling (3600) with headroom.
    public static let maxSamples = 4096
    /// Hard cap on stored stranger-lock timestamps.
    public static let maxStrangerLocks = 64

    /// Fraction of the window's maximum possible samples (one per tick) that the
    /// low-margin gate may demand. 40%: at the 1 s default tick × 300 s window that is
    /// exactly the configured 120, and it leaves 60% slack for ticks that yield no
    /// live-verified present score (face turned away, liveness pending, presence-only,
    /// slow Vision ticks) so a slow tick can't make the gate unreachable.
    public static let minSampleFractionOfWindow = 0.4
    /// Noise floor for the gate: never judge a mean over fewer samples than this,
    /// unless the window can't even hold this many ticks (exotic short-window /
    /// slow-tick configs), in which case the gate is every tick in the window.
    public static let minSampleFloor = 10

    public let windowSeconds: TimeInterval
    /// EFFECTIVE low-margin gate: `Config.driftMinSamples`, lowered when the tick
    /// interval means the window can't collect that many (see
    /// `effectiveMinSamples(configured:windowSeconds:tickIntervalSeconds:)`).
    public let minSamples: Int
    /// `Config.driftMinSamples` as configured (clamped), before the tick adjustment.
    public let configuredMinSamples: Int
    /// The (clamped) tick interval the gate was sized for. The app must rebuild the
    /// monitor when the tick interval changes.
    public let tickIntervalSeconds: TimeInterval
    public let marginThreshold: Double
    public let strangerLockCount: Int
    public let strangerLockAfterUnlockSeconds: TimeInterval
    public let strangerLockWindowSeconds: TimeInterval
    public let renotifySeconds: TimeInterval

    private struct Sample: Sendable {
        let at: Date
        let margin: Double
    }

    private var samples: [Sample] = []
    private var strangerLocks: [Date] = []

    /// Takes the ND-119 constants from `config`, clamped into `Config.Bounds`
    /// (ADR-0019), so a bad value can't disable or spam the warning.
    public init(config: Config = Config()) {
        let c = config.validated()
        windowSeconds = c.driftWindowSeconds
        configuredMinSamples = c.driftMinSamples
        tickIntervalSeconds = c.tickIntervalSeconds
        minSamples = Self.effectiveMinSamples(configured: c.driftMinSamples,
                                              windowSeconds: c.driftWindowSeconds,
                                              tickIntervalSeconds: c.tickIntervalSeconds)
        marginThreshold = c.driftMarginThreshold
        strangerLockCount = c.driftStrangerLockCount
        strangerLockAfterUnlockSeconds = c.driftStrangerLockAfterUnlockSeconds
        strangerLockWindowSeconds = c.driftStrangerLockWindowSeconds
        renotifySeconds = c.driftRenotifySeconds
    }

    /// Most samples one window can hold at one sample per tick: ticks at ages
    /// 0, tick, 2·tick, … strictly below `windowSeconds` (rounded down, so jitter that
    /// stretches ticks can't push the count below this). Always ≥ 1.
    public static func maxSamplesPerWindow(windowSeconds: TimeInterval,
                                           tickIntervalSeconds: TimeInterval) -> Int {
        guard windowSeconds.isFinite, tickIntervalSeconds.isFinite,
              windowSeconds > 0, tickIntervalSeconds > 0 else { return 1 }
        // The epsilon keeps 300 / 1 from landing on 299.999… and losing a sample.
        let ratio = (windowSeconds / tickIntervalSeconds + 1e-9).rounded(.down)
        return max(1, min(Int(ratio), maxSamples))
    }

    /// The low-margin gate actually applied (ND-119 code review): the configured
    /// minimum, capped at `minSampleFractionOfWindow` of what the window can hold at
    /// this tick interval, but never below `minSampleFloor` unless the window holds
    /// fewer ticks than that. Without the cap, a tick > 2.5 s made 120 samples in
    /// 300 s impossible and the warning silently never fired.
    public static func effectiveMinSamples(configured: Int, windowSeconds: TimeInterval,
                                           tickIntervalSeconds: TimeInterval) -> Int {
        let capacity = maxSamplesPerWindow(windowSeconds: windowSeconds,
                                           tickIntervalSeconds: tickIntervalSeconds)
        // The epsilon keeps 300 × 0.4 from landing on 119.999… and rounding to 119.
        let fractionCap = Int((Double(capacity) * minSampleFractionOfWindow + 1e-9).rounded(.down))
        let floor = min(minSampleFloor, capacity)
        return max(1, min(configured, max(fractionCap, floor)))
    }

    /// Match samples currently held (diagnostics; a count only, no scores).
    public var sampleCount: Int { samples.count }
    /// Qualifying stranger locks currently held (diagnostics).
    public var strangerLockSampleCount: Int { strangerLocks.count }

    /// Record one live-verified `.enrolledUserPresent` score. The margin is taken
    /// against the threshold IN FORCE for this sample, so a threshold slider change
    /// mid-window doesn't skew the older samples. Non-finite inputs are ignored.
    public mutating func recordMatch(score: Double, threshold: Double, now: Date) {
        guard score.isFinite, threshold.isFinite else { return }
        samples.append(Sample(at: now, margin: score - threshold))
        pruneSamples(now: now)
    }

    /// Record a SUCCESSFUL stranger-driven auto-lock. It counts toward the burst only
    /// when it came at most `strangerLockAfterUnlockSeconds` after an unlock; a nil
    /// (no unlock seen) or negative (clock went backwards) interval doesn't count.
    public mutating func recordStrangerLock(now: Date, secondsSinceUnlock: TimeInterval?) {
        pruneStrangerLocks(now: now)
        guard let s = secondsSinceUnlock, s.isFinite, s >= 0,
              s <= strangerLockAfterUnlockSeconds else { return }
        strangerLocks.append(now)
        if strangerLocks.count > Self.maxStrangerLocks {
            strangerLocks.removeFirst(strangerLocks.count - Self.maxStrangerLocks)
        }
    }

    /// Current drift verdict. Pure: only samples inside the windows ending at `now`
    /// count, so stale data never triggers it even without a prune. The stranger
    /// burst takes priority (it is the stronger, already-hurting signal).
    public func evaluate(now: Date) -> EnrollmentDriftReason? {
        let locks = strangerLocks.reduce(0) { n, t in
            Self.inWindow(t, now: now, window: strangerLockWindowSeconds) ? n + 1 : n
        }
        if locks >= strangerLockCount { return .repeatedStrangerLocks(count: locks) }

        var n = 0
        var sum = 0.0
        for s in samples where Self.inWindow(s.at, now: now, window: windowSeconds) {
            n += 1
            sum += s.margin
        }
        guard n >= minSamples, n > 0 else { return nil }
        let mean = sum / Double(n)
        return mean < marginThreshold ? .lowMargin(meanMargin: mean) : nil
    }

    /// Whether to post the drift notification again: never posted yet, or at least
    /// `renotifySeconds` since the last one. A last-notified time in the future
    /// (clock went backwards) counts as "not yet": no notification spam.
    public func shouldNotify(lastNotifiedAt: Date?, now: Date) -> Bool {
        guard let last = lastNotifiedAt else { return true }
        return now.timeIntervalSince(last) >= renotifySeconds
    }

    /// Drop all history (call after a successful re-enroll).
    public mutating func reset() {
        samples.removeAll()
        strangerLocks.removeAll()
    }

    // MARK: - Private

    /// `t` is in (now − window, now]. A sample from the future (clock went
    /// backwards) is excluded; it is pruned on the next record.
    private static func inWindow(_ t: Date, now: Date, window: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(t)
        return age >= 0 && age < window
    }

    private mutating func pruneSamples(now: Date) {
        samples.removeAll { !Self.inWindow($0.at, now: now, window: windowSeconds) }
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    private mutating func pruneStrangerLocks(now: Date) {
        strangerLocks.removeAll { !Self.inWindow($0, now: now, window: strangerLockWindowSeconds) }
    }
}
