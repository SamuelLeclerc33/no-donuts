import Foundation

// Owner: blart + homer — presence-loop cadence (ND-042a).
// Pure arithmetic; no clocks, no I/O. The App loop feeds it monotonic seconds.

/// Fixed-cadence (deadline-based) scheduling for the presence loop (ND-042a).
///
/// The old loop did `tick(); sleep(interval)`, so the real period was
/// `work + interval` — a 1s tick with ~300 ms of capture + recognition ran at
/// ~1.3s, silently stretching the walk-away→lock math (consensus × tick) by the
/// same factor. Here each tick is due at `previousDeadline + interval`, so work
/// time is absorbed by a shorter sleep instead of adding to the period.
///
/// Missed deadlines are SKIPPED, never burst: if a tick overran one or more
/// whole intervals (a slow first-frame wait, a stalled recognizer), the next
/// deadline is the first grid point still in the future. Running the missed
/// ticks back-to-back would feed the engine several readings from the same
/// instant and count them as consensus — absence would reach the lock threshold
/// faster than the configured seconds imply.
///
/// All times are seconds on one monotonic clock (the App uses
/// `ProcessInfo.systemUptime`), so wall-clock changes can't warp the cadence.
public enum TickSchedule {
    /// The next deadline and how many grid points were skipped to reach it.
    public struct Next: Equatable, Sendable {
        /// When the next tick is due (same clock as the inputs).
        public let deadline: TimeInterval
        /// Deadlines that had already passed at `now` and were dropped (0 when
        /// the tick finished inside its interval).
        public let skipped: Int
    }

    /// Floor for a degenerate interval so a zero/negative/NaN value can't make
    /// the loop spin. `Config.validated()` already clamps the real tunable to
    /// ≥ 0.5s; this is only a last guard.
    public static let minimumInterval: TimeInterval = 0.1

    /// Next deadline after the tick scheduled at `previousDeadline` finished at
    /// `now`: the smallest `previousDeadline + k × interval` (k ≥ 1) that is
    /// ≥ `now`. `skipped` = k − 1.
    ///
    /// A non-finite `previousDeadline` or `now` re-anchors to `now + interval`
    /// (fail toward a normal cadence, never toward a spin).
    public static func next(after previousDeadline: TimeInterval,
                            interval: TimeInterval,
                            now: TimeInterval) -> Next {
        let step = (interval.isFinite && interval >= minimumInterval) ? interval : minimumInterval
        guard previousDeadline.isFinite, now.isFinite else {
            let base = now.isFinite ? now : 0
            return Next(deadline: base + step, skipped: 0)
        }
        let first = previousDeadline + step
        guard now > first else { return Next(deadline: first, skipped: 0) }
        // k = ceil((now - previousDeadline) / step), at least 1.
        let k = max(1, Int(((now - previousDeadline) / step).rounded(.up)))
        var deadline = previousDeadline + Double(k) * step
        var steps = k
        // Guard floating-point rounding landing a hair before `now`.
        if deadline < now { deadline += step; steps += 1 }
        return Next(deadline: deadline, skipped: steps - 1)
    }

    /// Seconds to sleep from `now` until `deadline` (never negative).
    public static func delay(until deadline: TimeInterval, now: TimeInterval) -> TimeInterval {
        guard deadline.isFinite, now.isFinite else { return 0 }
        return max(0, deadline - now)
    }
}
