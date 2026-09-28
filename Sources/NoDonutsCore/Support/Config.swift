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
    /// forever (EC-10, no indefinite fail-open).
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
    /// Slow the tick on battery to save power (EC-18). TODO(blart/homer).
    public var throttleOnBattery: Bool = true

    public init() {}
}
