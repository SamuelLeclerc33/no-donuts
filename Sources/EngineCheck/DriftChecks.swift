import Foundation
import NoDonutsCore

// Owner: cooper — ND-119 enrollment drift warning. Pure checks on the
// `EnrollmentDriftMonitor` value type (time injected) and on the clamping of its
// `Config` constants (ADR-0019 pattern).

@MainActor
func runEnrollmentDriftChecks(_ c: Checks) async {
    print("\nND-119 enrollment drift checks:")

    let d = Config()
    c.expect(d.driftWindowSeconds == 300 && d.driftMinSamples == 120 && d.driftMarginThreshold == 0.10
             && d.driftStrangerLockCount == 3 && d.driftStrangerLockAfterUnlockSeconds == 60
             && d.driftStrangerLockWindowSeconds == 900 && d.driftRenotifySeconds == 14_400,
             "ND-119: shipped drift defaults (5 min / 120 / 0.10 / 3 locks ≤60s in 15 min / 4h)")

    /// Feed `n` samples at 1 Hz starting at `start`; returns the time of the last one.
    @discardableResult
    func feed(_ m: inout EnrollmentDriftMonitor, _ n: Int, score: Double, threshold: Double = 0.5,
              from start: Date) -> Date {
        var last = start
        for i in 0..<n {
            last = start.addingTimeInterval(Double(i))
            m.recordMatch(score: score, threshold: threshold, now: last)
        }
        return last
    }

    // Min-sample gate: 119 low-margin samples → nothing; the 120th → lowMargin.
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 119, score: 0.55, from: t0)
        c.expect(m.evaluate(now: last) == nil, "ND-119: 119 low-margin samples < min 120 → no warning")
        let t = last.addingTimeInterval(1)
        m.recordMatch(score: 0.55, threshold: 0.5, now: t)
        if case .lowMargin(let mean)? = m.evaluate(now: t) {
            c.expect(abs(mean - 0.05) < 1e-9, "ND-119: 120 samples at margin 0.05 → lowMargin(0.05)")
        } else {
            c.expect(false, "ND-119: 120 samples at margin 0.05 → lowMargin(0.05)")
        }
    }

    // Healthy margin never warns; boundary: mean exactly at threshold is not "below".
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 300, score: 0.85, from: t0)
        c.expect(m.evaluate(now: last) == nil, "ND-119: margin 0.35 (pre-shave) → no warning")
        var b = EnrollmentDriftMonitor()
        let lb = feed(&b, 200, score: 0.625, threshold: 0.5, from: t0)
        c.expect(b.evaluate(now: lb) == nil, "ND-119: mean margin 0.125 ≥ 0.10 → no warning")
    }

    // Window pruning: samples older than 5 min drop out, both in evaluate (pure) and
    // on the next record; memory stays at ~one window of samples.
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 200, score: 0.55, from: t0)
        c.expect(m.evaluate(now: last) != nil, "ND-119: 200 low-margin samples → warning")
        c.expect(m.evaluate(now: last.addingTimeInterval(300)) == nil,
                 "ND-119: evaluate 5 min after the last sample → stale samples don't count")
        // 130 s later: the first 30 s of samples (age ≥ 300) are out; 170 + 1 remain.
        let later = last.addingTimeInterval(130)
        m.recordMatch(score: 0.55, threshold: 0.5, now: later)
        c.expect(m.sampleCount == 171 && m.evaluate(now: later) != nil,
                 "ND-119: record prunes samples older than the window (171 kept, still ≥ 120)")
        var big = EnrollmentDriftMonitor()
        feed(&big, 2_000, score: 0.9, from: t0)
        c.expect(big.sampleCount == 300, "ND-119: 1 Hz for 2000s keeps one 300s window of samples")
        var burst = EnrollmentDriftMonitor()
        for _ in 0..<(EnrollmentDriftMonitor.maxSamples + 500) {
            burst.recordMatch(score: 0.9, threshold: 0.5, now: t0)
        }
        c.expect(burst.sampleCount == EnrollmentDriftMonitor.maxSamples,
                 "ND-119: hard cap bounds samples even when all share one timestamp")
    }

    // A future-dated sample (clock went backwards) doesn't count toward `evaluate`.
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 150, score: 0.55, from: t0.addingTimeInterval(1_000))
        c.expect(m.evaluate(now: t0) == nil && m.evaluate(now: last) != nil,
                 "ND-119: samples dated after `now` are ignored by evaluate")
        m.recordMatch(score: .nan, threshold: 0.5, now: last)
        m.recordMatch(score: 0.9, threshold: .infinity, now: last)
        c.expect(m.sampleCount == 150, "ND-119: non-finite score/threshold is ignored")
    }

    // Per-sample threshold: a slider change mid-window keeps each sample's own margin.
    do {
        var m = EnrollmentDriftMonitor()
        // 150 samples score 0.85 @ 0.50 (margin 0.35), then threshold raised to 0.80:
        // 150 samples score 0.85 @ 0.80 (margin 0.05). Mean = 0.20 → no warning.
        let mid = feed(&m, 150, score: 0.85, threshold: 0.50, from: t0)
        let last = feed(&m, 150, score: 0.85, threshold: 0.80, from: mid.addingTimeInterval(1))
        c.expect(m.evaluate(now: last) == nil,
                 "ND-119: margin uses the threshold at sample time (mean 0.20 after slider change)")
        // Once the old-threshold samples age out, only margin-0.05 samples remain → warn.
        let later = last.addingTimeInterval(150)
        m.recordMatch(score: 0.85, threshold: 0.80, now: later)
        if case .lowMargin(let mean)? = m.evaluate(now: later) {
            c.expect(abs(mean - 0.05) < 1e-9, "ND-119: after old samples age out → lowMargin(0.05)")
        } else {
            c.expect(false, "ND-119: after old samples age out → lowMargin(0.05)")
        }
    }

    // Stranger-lock burst: 3 qualifying locks in 15 min; 60 s after-unlock rule; expiry.
    do {
        var m = EnrollmentDriftMonitor()
        m.recordStrangerLock(now: t0, secondsSinceUnlock: 10)
        m.recordStrangerLock(now: t0.addingTimeInterval(60), secondsSinceUnlock: 30)
        c.expect(m.evaluate(now: t0.addingTimeInterval(60)) == nil, "ND-119: 2 stranger locks → no warning")
        m.recordStrangerLock(now: t0.addingTimeInterval(120), secondsSinceUnlock: 61)
        m.recordStrangerLock(now: t0.addingTimeInterval(130), secondsSinceUnlock: nil)
        m.recordStrangerLock(now: t0.addingTimeInterval(140), secondsSinceUnlock: -5)
        c.expect(m.evaluate(now: t0.addingTimeInterval(140)) == nil,
                 "ND-119: locks >60s after unlock / with no unlock / negative interval don't count")
        m.recordStrangerLock(now: t0.addingTimeInterval(180), secondsSinceUnlock: 60)
        c.expect(m.evaluate(now: t0.addingTimeInterval(180)) == .repeatedStrangerLocks(count: 3),
                 "ND-119: 3rd qualifying lock (60s exactly) within 15 min → repeatedStrangerLocks(3)")
        c.expect(m.evaluate(now: t0.addingTimeInterval(900)) == nil,
                 "ND-119: 15 min after the first lock it expires → burst over")
        var spread = EnrollmentDriftMonitor()
        for i in 0..<3 {
            spread.recordStrangerLock(now: t0.addingTimeInterval(Double(i) * 500), secondsSinceUnlock: 5)
        }
        c.expect(spread.evaluate(now: t0.addingTimeInterval(1_000)) == nil && spread.strangerLockSampleCount == 2,
                 "ND-119: 3 locks spread over 16+ min → not a burst (oldest pruned)")
    }

    // Stranger burst takes priority over the low-margin trigger.
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 150, score: 0.52, from: t0)
        for i in 0..<4 {
            m.recordStrangerLock(now: last.addingTimeInterval(Double(i)), secondsSinceUnlock: 5)
        }
        c.expect(m.evaluate(now: last.addingTimeInterval(3)) == .repeatedStrangerLocks(count: 4),
                 "ND-119: both triggers active → stranger burst wins")
    }

    // Reset clears both histories.
    do {
        var m = EnrollmentDriftMonitor()
        let last = feed(&m, 150, score: 0.55, from: t0)
        for i in 0..<3 { m.recordStrangerLock(now: last.addingTimeInterval(Double(i)), secondsSinceUnlock: 5) }
        m.reset()
        c.expect(m.sampleCount == 0 && m.strangerLockSampleCount == 0
                 && m.evaluate(now: last.addingTimeInterval(3)) == nil,
                 "ND-119: reset() (after re-enroll) clears samples and stranger locks")
    }

    // Tick-aware min-sample gate (code review): the low-margin gate must be reachable
    // at ONE sample per tick inside the window for every tick interval the user can
    // set, across the window / min-samples Bounds. At a >2.5 s tick the raw 120-in-300s
    // gate was unreachable and the warning silently never fired.
    do {
        let B = Config.Bounds.self
        func span<T>(_ r: ClosedRange<T>, _ mid: T) -> [T] { [r.lowerBound, mid, r.upperBound] }
        var allReachable = true
        var failures: [String] = []
        for tick in span(B.tickIntervalSeconds, d.tickIntervalSeconds) {
            for window in span(B.driftWindowSeconds, d.driftWindowSeconds) {
                for minS in span(B.driftMinSamples, d.driftMinSamples) {
                    var cfg = Config()
                    cfg.tickIntervalSeconds = tick
                    cfg.driftWindowSeconds = window
                    cfg.driftMinSamples = minS
                    var m = EnrollmentDriftMonitor(config: cfg)
                    let gate = m.minSamples
                    // `gate` samples, one per tick, all inside one window.
                    var ok = gate >= 1 && gate <= minS && Double(gate - 1) * tick < window
                    var last = t0
                    for i in 0..<gate {
                        last = t0.addingTimeInterval(Double(i) * tick)
                        if i == gate - 1, gate > 1, m.evaluate(now: last) != nil { ok = false }
                        m.recordMatch(score: 0.55, threshold: 0.5, now: last)
                    }
                    if m.evaluate(now: last) == nil { ok = false }
                    // Steady state: one sample per tick for two windows still warns.
                    var s = EnrollmentDriftMonitor(config: cfg)
                    let n = Int((2 * window / tick).rounded(.up))
                    for i in 0..<n { s.recordMatch(score: 0.55, threshold: 0.5, now: t0.addingTimeInterval(Double(i) * tick)) }
                    if s.evaluate(now: t0.addingTimeInterval(Double(n - 1) * tick)) == nil { ok = false }
                    if !ok { allReachable = false; failures.append("tick \(tick) window \(window) min \(minS) gate \(gate)") }
                }
            }
        }
        c.expect(allReachable, "ND-119: low-margin gate reachable at 1 sample/tick for tick/window/min-samples Bounds (min, default, max)"
                 + (failures.isEmpty ? "" : " — " + failures.joined(separator: "; ")))

        c.expect(EnrollmentDriftMonitor().minSamples == 120
                 && EnrollmentDriftMonitor(config: d).configuredMinSamples == 120,
                 "ND-119: at the 1 s default tick the effective gate stays 120")
        var slow = Config()
        slow.tickIntervalSeconds = B.tickIntervalSeconds.upperBound   // 10 s → 30 ticks / 300 s
        let sm = EnrollmentDriftMonitor(config: slow)
        c.expect(sm.minSamples == 12 && sm.configuredMinSamples == 120 && sm.tickIntervalSeconds == 10,
                 "ND-119: 10 s tick → gate lowered to 40% of 30 ticks (12), configured 120 kept")
        var fast = Config()
        fast.tickIntervalSeconds = B.tickIntervalSeconds.lowerBound   // 0.5 s → 600 ticks
        c.expect(EnrollmentDriftMonitor(config: fast).minSamples == 120,
                 "ND-119: 0.5 s tick → gate never RAISED above the configured 120")
        var exotic = Config()
        exotic.tickIntervalSeconds = 10
        exotic.driftWindowSeconds = 60                                // only 6 ticks fit
        c.expect(EnrollmentDriftMonitor(config: exotic).minSamples == 6,
                 "ND-119: window holding < 10 ticks → gate is every tick in the window (still reachable)")
        c.expect(EnrollmentDriftMonitor.effectiveMinSamples(configured: 120, windowSeconds: 300,
                                                            tickIntervalSeconds: 2.5) == 48
                 && EnrollmentDriftMonitor.effectiveMinSamples(configured: 120, windowSeconds: 300,
                                                               tickIntervalSeconds: 2) == 60,
                 "ND-119: effective gate = 40% of window capacity (2.5 s → 48, 2 s → 60)")
        var raw = Config()
        raw.tickIntervalSeconds = 1_000                               // out of Bounds → clamped to 10
        c.expect(EnrollmentDriftMonitor(config: raw).tickIntervalSeconds == 10,
                 "ND-119: the monitor sizes the gate from the CLAMPED tick interval")
    }

    // Renotify rate limit.
    do {
        let m = EnrollmentDriftMonitor()
        c.expect(m.shouldNotify(lastNotifiedAt: nil, now: t0), "ND-119: first drift notification is allowed")
        c.expect(!m.shouldNotify(lastNotifiedAt: t0, now: t0.addingTimeInterval(14_399))
                 && m.shouldNotify(lastNotifiedAt: t0, now: t0.addingTimeInterval(14_400)),
                 "ND-119: re-notify at most once per 4 h")
        c.expect(!m.shouldNotify(lastNotifiedAt: t0.addingTimeInterval(100), now: t0),
                 "ND-119: last-notified in the future (clock skew) → no re-notify")
    }

    // Config clamping of the drift constants (ADR-0019 / ND-062 pattern).
    do {
        c.expect(d.validated() == d, "ND-119: drift defaults are inside Bounds")
        var low = Config()
        low.driftWindowSeconds = 0
        low.driftMinSamples = 0
        low.driftMarginThreshold = -1
        low.driftStrangerLockCount = 1
        low.driftStrangerLockAfterUnlockSeconds = 0
        low.driftStrangerLockWindowSeconds = 0
        low.driftRenotifySeconds = 0
        let lv = low.validated()
        let B = Config.Bounds.self
        c.expect(lv.driftWindowSeconds == 60 && lv.driftMinSamples == 10 && lv.driftMarginThreshold == 0.01
                 && lv.driftStrangerLockCount == 2 && lv.driftStrangerLockAfterUnlockSeconds == 10
                 && lv.driftStrangerLockWindowSeconds == 120 && lv.driftRenotifySeconds == 900,
                 "ND-119: drift constants clamp up to their floors (no disabled / spamming warning)")
        var high = Config()
        high.driftWindowSeconds = 1e9
        high.driftMinSamples = 1_000_000
        high.driftMarginThreshold = 5
        high.driftStrangerLockCount = 100
        high.driftStrangerLockAfterUnlockSeconds = 1e9
        high.driftStrangerLockWindowSeconds = 1e9
        high.driftRenotifySeconds = 1e9
        let hv = high.validated()
        c.expect(hv.driftWindowSeconds == B.driftWindowSeconds.upperBound
                 && hv.driftMinSamples == B.driftMinSamples.upperBound
                 && hv.driftMarginThreshold == B.driftMarginThreshold.upperBound
                 && hv.driftStrangerLockCount == B.driftStrangerLockCount.upperBound
                 && hv.driftStrangerLockAfterUnlockSeconds == B.driftStrangerLockAfterUnlockSeconds.upperBound
                 && hv.driftStrangerLockWindowSeconds == B.driftStrangerLockWindowSeconds.upperBound
                 && hv.driftRenotifySeconds == B.driftRenotifySeconds.upperBound,
                 "ND-119: drift constants clamp down to their ceilings")
        c.expect(B.driftMinSamples.upperBound <= EnrollmentDriftMonitor.maxSamples,
                 "ND-119: max min-samples is under the hard sample cap")
        var nan = Config()
        nan.driftWindowSeconds = .nan
        nan.driftMarginThreshold = .infinity
        nan.driftRenotifySeconds = -.infinity
        let nv = nan.validated()
        c.expect(nv.driftWindowSeconds == d.driftWindowSeconds && nv.driftMarginThreshold == d.driftMarginThreshold
                 && nv.driftRenotifySeconds == d.driftRenotifySeconds,
                 "ND-119: non-finite drift constants fall back to the shipped default")
        let mon = EnrollmentDriftMonitor(config: low)
        c.expect(mon.minSamples == 10 && mon.windowSeconds == 60 && mon.strangerLockCount == 2,
                 "ND-119: the monitor uses the clamped config, not the raw one")
    }
}
