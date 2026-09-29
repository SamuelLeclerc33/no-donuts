import Foundation

/// Tunable behavior. Persisted with settings (owner: krusty for UI, homer for defaults).
/// Privacy: no field here is ever transmitted. See docs/SECURITY_PRIVACY.md.
public struct Config: Codable, Equatable {
    /// How often the presence loop runs (seconds). Fast cadence so office
    /// "donuting" (walking away unlocked) is caught in ~10s — see the
    /// walk-away→lock math on `consecutiveAbsentTicksToLock` below.
    public var tickIntervalSeconds: Double = 1
    /// Continuous absence required before locking, in seconds (absorbs brief
    /// turn-aways). Effective walk-away→lock ≈ consensus (`consecutiveAbsentTicksToLock`
    /// × `tickIntervalSeconds`) + `graceSeconds` ≈ 5 + 5 = ~10s at defaults.
    public var graceSeconds: Double = 5
    /// Consecutive no-face/stranger ticks required to begin the grace countdown
    /// (the absence "consensus"). Debounces single-frame glitches: a lone bad
    /// reading can't start the lock clock; it takes 5 in a row (≈5s of consensus
    /// at the 1s default tick). Effective walk-away→lock ≈ consensus (5 × tick) +
    /// grace ≈ 5 + 5 = ~10s.
    public var consecutiveAbsentTicksToLock: Int = 5
    /// ND-061 (ADR-0017): stranger-at-keyboard fast path. A face that does NOT
    /// match the enrolled user (`RecognitionResult.strangerOnly`, incl. an
    /// anti-spoof-flagged match) is the highest-threat observable state, so after
    /// this many CONSECUTIVE stranger ticks the engine locks without waiting for
    /// the normal consensus + grace (≈3s at the 1s default tick, vs ~10s for an
    /// empty desk). Only reachable once enrolled (the recognizer never reports a
    /// stranger in presence-only mode). A no-face / present / busy / escalated
    /// tick breaks the streak; a transient recognizer error or a lid-open
    /// camera-unavailable hold leaves it untouched (EC-10 HOLD). Stranger ticks
    /// also count toward `consecutiveAbsentTicksToLock`, so mixed stranger /
    /// no-face absence still locks on the normal path. Values < 1 behave as 1.
    public var consecutiveStrangerTicksToLock: Int = 3
    /// ND-061 (ADR-0017): grace after the stranger streak reaches
    /// `consecutiveStrangerTicksToLock` before locking. Default 0 = lock on the
    /// threshold tick. Grace exists to absorb the enrolled user turning away (an
    /// empty desk), not to give a stranger time at the keyboard. Negative = 0.
    public var strangerGraceSeconds: Double = 0
    /// A transient recognition error is held (presence unchanged), but after this
    /// many CONSECUTIVE errors the engine escalates to treating the tick as
    /// absence — so a wedged recognizer still locks rather than holding unlocked
    /// forever (EC-10, no indefinite fail-open). ND-060: once escalated, EVERY further
    /// consecutive error tick is an absence tick (the streak is not reset), so a fully
    /// wedged recognizer locks after (this − 1) + consensus ticks + grace ≈ 2 + 5 + 5
    /// ≈ 11s at defaults — plain absence + 2s, not ~3× the consensus. A clean reading
    /// (present / noFace / stranger) ends the streak.
    public var maxConsecutiveErrorsBeforeAbsent: Int = 3
    /// Bounds the busy→assume-present fail-open (ADR-0003) so a call app left
    /// running unattended can't keep the Mac unlocked forever; after this many
    /// continuous seconds of busy-no-frames the engine treats it as absence.
    ///
    /// NOTE: this cap is NOT the wall-clock time to lock. Once the cap expires the
    /// engine merely begins counting absence, so the effective unlock ceiling is
    /// `maxCallAssumedPresentSeconds` + the absence consensus
    /// (`consecutiveAbsentTicksToLock` ticks, ~`* tickIntervalSeconds`) + `graceSeconds`.
    /// A genuinely long call with no obtainable frames WILL be locked at the cap —
    /// an accepted, bounded fail-open tradeoff (tune this value if needed).
    ///
    /// ND-098: 10 min (was 30). Opening any camera app (e.g. Photo Booth) and
    /// walking away buys at most this long unlocked, so keep it short.
    public var maxCallAssumedPresentSeconds: Double = 600
    /// ND-078: bounds the camera-unavailable fail-open (EC-07/08/09). While the lid
    /// is OPEN, after this many continuous seconds of `.unavailable` (permission
    /// revoked, wedged camera, another app blocking it) the engine treats it as
    /// absence, so the normal consensus + grace + lock path runs. With the lid
    /// CLOSED (clamshell) the camera is expected to be unavailable and this never
    /// escalates. Like the call cap, this is NOT the time to lock: effective ceiling
    /// ≈ this + consensus (`consecutiveAbsentTicksToLock` × tick) + `graceSeconds`.
    public var maxCameraUnavailableSeconds: Double = 120
    // MARK: ND-119 enrollment drift warning (advisory only)
    //
    // Fixed code-only constants (no Settings UI, no defaults key) consumed by
    // `EnrollmentDriftMonitor`. They drive a WARN-ONLY "recognition weak —
    // re-enroll" prompt; nothing here changes the lock policy, and enrollment
    // templates are never adapted from live scores (spoof-poisoning risk).
    // Scores and lock times stay in memory only (docs/SECURITY_PRIVACY.md).

    /// ND-119: rolling window (seconds) over which live-verified
    /// `.enrolledUserPresent` match margins are averaged. 5 min at defaults.
    public var driftWindowSeconds: Double = 300
    /// ND-119: minimum match samples inside `driftWindowSeconds` before the
    /// low-margin trigger may fire (≈2 min of recognized presence at the 1s tick),
    /// so a handful of bad-light frames can't raise the warning. This is a CEILING:
    /// the monitor lowers it to 40% of the ticks the window can hold at the current
    /// `tickIntervalSeconds` (floor 10), so a slow tick can't make it unreachable.
    public var driftMinSamples: Int = 120
    /// ND-119: the low-margin trigger fires when the window's mean of
    /// (score − threshold-at-sample) is BELOW this. 0.10 = the user is recognized,
    /// but only just (e.g. a shaved beard: ~0.85 → 0.50–0.60 at threshold 0.50).
    public var driftMarginThreshold: Double = 0.10
    /// ND-119: this many stranger-driven auto-locks (ADR-0017 fast path), each
    /// shortly after an unlock, inside `driftStrangerLockWindowSeconds` → warn.
    public var driftStrangerLockCount: Int = 3
    /// ND-119: a stranger lock counts toward the burst only if it happened at most
    /// this many seconds after the session was unlocked (the user just logged back
    /// in and was immediately "not recognized" again).
    public var driftStrangerLockAfterUnlockSeconds: Double = 60
    /// ND-119: window (seconds) for the stranger-lock burst. 15 min at defaults.
    public var driftStrangerLockWindowSeconds: Double = 900
    /// ND-119: minimum interval (seconds) between two drift notifications while
    /// the warning stays active. 4 h at defaults.
    public var driftRenotifySeconds: Double = 14_400
    // ND-069: there is deliberately NO "throttle on battery" tunable. Slowing the
    // tick on battery multiplies the walk-away→lock time (consensus × tick), so an
    // unplugged laptop — the one most likely to be carried into an open office —
    // would be the least protected. Power is handled at the camera instead (ND-096:
    // 640×480, lowest frame rate) and measured per tick (ND-042e). The old
    // `throttleOnBattery` flag was read by nothing; it was removed, not implemented.
    // (A stored config with that key still decodes: unknown keys are ignored.)

    public init() {}
}

// MARK: - ND-062: validated tunables

extension Config {
    /// ND-062: the SAFE range for every engine tunable. `validated()` clamps into these
    /// and every path that feeds the engine (PresenceEngine.init / updateConfig, the
    /// App's loop cadence) goes through it, so no source — Settings, `defaults write`,
    /// a decoded Config, a future UI — can inject a 0s tick (CPU spin) or a huge grace
    /// / consensus / cap (silent fail-open). Each bound is chosen so the product
    /// promise ("walk away → locked in ~10s; never lock mid-call; bounded fail-opens")
    /// still holds at the extremes:
    public enum Bounds {
        /// 0.5–10s. Below 0.5s = pointless camera/CPU churn (the camera delivers ~1fps);
        /// above 10s makes consensus × tick alone exceed a minute at the top of its range.
        public static let tickIntervalSeconds: ClosedRange<Double> = 0.5...10
        /// 2–60s. Never 0 (a brief look-away must not lock instantly — code-review #3);
        /// never more than a minute (grace is a fail-open window).
        public static let graceSeconds: ClosedRange<Double> = 2...60
        /// 2–20 ticks. 1 would let a single glitchy frame start the lock clock; >20
        /// stretches the consensus into a fail-open.
        public static let consecutiveAbsentTicksToLock: ClosedRange<Int> = 2...20
        /// 1–20 ticks of held recognizer errors before escalating to absence (EC-10).
        public static let maxConsecutiveErrorsBeforeAbsent: ClosedRange<Int> = 1...20
        /// 1–60 min busy-camera assume-present cap (ADR-0003 / ND-033 / ND-098).
        public static let maxCallAssumedPresentSeconds: ClosedRange<Double> = 60...3600
        /// 30s–10 min lid-open camera-unavailable cap (ND-078).
        public static let maxCameraUnavailableSeconds: ClosedRange<Double> = 30...600
        /// 1–10 consecutive stranger ticks for the ND-061 fast path (ADR-0017).
        public static let consecutiveStrangerTicksToLock: ClosedRange<Int> = 1...10
        /// 0–10s grace after the stranger streak (ADR-0017; default 0).
        public static let strangerGraceSeconds: ClosedRange<Double> = 0...10
        /// ND-119: 1–30 min drift window. Shorter reacts to noise; longer delays the
        /// warning past the lock storm it exists to pre-empt.
        public static let driftWindowSeconds: ClosedRange<Double> = 60...1800
        /// ND-119: 10–1800 samples. Never below 10 (one bad-light moment must not warn);
        /// the top stays under `EnrollmentDriftMonitor.maxSamples`. Reachability at the
        /// actual tick cadence is guaranteed by `EnrollmentDriftMonitor.effectiveMinSamples`.
        public static let driftMinSamples: ClosedRange<Int> = 10...1800
        /// ND-119: 0.01–0.5 mean margin. Never 0 (would never fire); never above 0.5
        /// (would warn a perfectly recognized user).
        public static let driftMarginThreshold: ClosedRange<Double> = 0.01...0.5
        /// ND-119: 2–10 stranger locks. 1 would warn on a single real stranger lock.
        public static let driftStrangerLockCount: ClosedRange<Int> = 2...10
        /// ND-119: 10s–10 min after an unlock for a stranger lock to count.
        public static let driftStrangerLockAfterUnlockSeconds: ClosedRange<Double> = 10...600
        /// ND-119: 2 min–1 h stranger-lock burst window.
        public static let driftStrangerLockWindowSeconds: ClosedRange<Double> = 120...3600
        /// ND-119: 15 min–24 h between drift notifications (no notification spam).
        public static let driftRenotifySeconds: ClosedRange<Double> = 900...86_400
    }

    /// UserDefaults keys for the tunables that are user-settable today (ND-040 Settings
    /// writes exactly these). The other tunables are code-only defaults, but still pass
    /// through `validated()`.
    public enum DefaultsKey {
        public static let tickIntervalSeconds = "tickIntervalSeconds"
        public static let graceSeconds = "graceSeconds"
    }

    /// ND-062: this config with every tunable clamped into `Bounds`. A non-finite
    /// Double (NaN / ±inf) falls back to the shipped default rather than clamping
    /// (NaN has no meaningful side of a range). Idempotent.
    public func validated() -> Config {
        let d = Config()
        var c = self
        c.tickIntervalSeconds = Config.clamp(tickIntervalSeconds, Bounds.tickIntervalSeconds, d.tickIntervalSeconds)
        c.graceSeconds = Config.clamp(graceSeconds, Bounds.graceSeconds, d.graceSeconds)
        c.consecutiveAbsentTicksToLock = Config.clamp(consecutiveAbsentTicksToLock, Bounds.consecutiveAbsentTicksToLock)
        c.maxConsecutiveErrorsBeforeAbsent = Config.clamp(maxConsecutiveErrorsBeforeAbsent, Bounds.maxConsecutiveErrorsBeforeAbsent)
        c.maxCallAssumedPresentSeconds = Config.clamp(maxCallAssumedPresentSeconds, Bounds.maxCallAssumedPresentSeconds, d.maxCallAssumedPresentSeconds)
        c.maxCameraUnavailableSeconds = Config.clamp(maxCameraUnavailableSeconds, Bounds.maxCameraUnavailableSeconds, d.maxCameraUnavailableSeconds)
        c.consecutiveStrangerTicksToLock = Config.clamp(consecutiveStrangerTicksToLock, Bounds.consecutiveStrangerTicksToLock)
        c.strangerGraceSeconds = Config.clamp(strangerGraceSeconds, Bounds.strangerGraceSeconds, d.strangerGraceSeconds)
        c.driftWindowSeconds = Config.clamp(driftWindowSeconds, Bounds.driftWindowSeconds, d.driftWindowSeconds)
        c.driftMinSamples = Config.clamp(driftMinSamples, Bounds.driftMinSamples)
        c.driftMarginThreshold = Config.clamp(driftMarginThreshold, Bounds.driftMarginThreshold, d.driftMarginThreshold)
        c.driftStrangerLockCount = Config.clamp(driftStrangerLockCount, Bounds.driftStrangerLockCount)
        c.driftStrangerLockAfterUnlockSeconds = Config.clamp(driftStrangerLockAfterUnlockSeconds,
                                                             Bounds.driftStrangerLockAfterUnlockSeconds,
                                                             d.driftStrangerLockAfterUnlockSeconds)
        c.driftStrangerLockWindowSeconds = Config.clamp(driftStrangerLockWindowSeconds,
                                                        Bounds.driftStrangerLockWindowSeconds,
                                                        d.driftStrangerLockWindowSeconds)
        c.driftRenotifySeconds = Config.clamp(driftRenotifySeconds, Bounds.driftRenotifySeconds, d.driftRenotifySeconds)
        return c
    }

    /// ND-062: build the engine config from UserDefaults (mirrors `resolvedMatchThreshold`).
    /// Reads the user-settable keys (`DefaultsKey`); a stored value is accepted ONLY if
    /// it is a finite number inside its `Bounds` range — absent, non-numeric (incl. a
    /// Bool), non-finite or out-of-range falls back to `base`'s value (rejected, not
    /// clamped: an injected `0` tick lands on the default, not the 0.5s floor). The
    /// result is `validated()`, so `base` itself can't smuggle in a bad value either.
    public static func resolved(from defaults: UserDefaults, base: Config = Config()) -> Config {
        var c = base
        c.tickIntervalSeconds = readDouble(defaults, DefaultsKey.tickIntervalSeconds,
                                           in: Bounds.tickIntervalSeconds) ?? base.tickIntervalSeconds
        c.graceSeconds = readDouble(defaults, DefaultsKey.graceSeconds,
                                    in: Bounds.graceSeconds) ?? base.graceSeconds
        return c.validated()
    }

    private static func readDouble(_ defaults: UserDefaults, _ key: String,
                                   in range: ClosedRange<Double>) -> Double? {
        guard let raw = defaults.object(forKey: key),
              let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        guard v.isFinite, range.contains(v) else { return nil }
        return v
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    private static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int {
        min(max(v, r.lowerBound), r.upperBound)
    }
}
