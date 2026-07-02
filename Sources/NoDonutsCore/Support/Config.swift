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
    /// Minimum cosine similarity for a face embedding to count as the enrolled user
    /// (see `IdentityRecognizer` / `cosineSimilarity`). A score below this → the face
    /// is a stranger, never present (EC-03).
    ///
    /// This default is tuned for the current embedder (`VisionFeaturePrintEmbedder`,
    /// ADR-0012), which uses Apple's `VNGenerateImageFeaturePrint`. That is a
    /// **general** image feature print, NOT a face-optimized embedding, so its
    /// same-person vs different-person separation is weaker than a dedicated face
    /// model — absolute scores here are not comparable to FaceNet-style thresholds and
    /// MUST be tuned on real device data (ND-024).
    ///
    /// The default is deliberately **lenient** (biased toward NOT locking out the real
    /// user): a false lock of the enrolled user is far more annoying than briefly
    /// treating a lookalike as present, and the presence engine's 5-tick consensus +
    /// grace already debounces occasional misreads. `0.6` is a defensible lenient
    /// starting point for the general feature print; it is user-tunable (ND-040) and
    /// should be raised once on-device tuning data exists (ND-024).
    public var matchThreshold: Double = 0.6
    /// Consecutive no-face/stranger ticks required to begin the grace countdown
    /// (the absence "consensus"). Debounces single-frame glitches: a lone bad
    /// reading can't start the lock clock; it takes 5 in a row (≈5s of consensus
    /// at the 1s default tick). Effective walk-away→lock ≈ consensus (5 × tick) +
    /// grace ≈ 5 + 5 = ~10s.
    public var consecutiveAbsentTicksToLock: Int = 5
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
    public var maxCallAssumedPresentSeconds: Double = 1800
    /// Slow the tick on battery to save power (EC-18). TODO(blart/homer).
    public var throttleOnBattery: Bool = true

    public init() {}
}
