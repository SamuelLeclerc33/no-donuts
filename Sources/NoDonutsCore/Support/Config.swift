import Foundation

/// Tunable behavior. Persisted with settings (owner: krusty for UI, homer for defaults).
/// Privacy: no field here is ever transmitted. See docs/SECURITY_PRIVACY.md.
public struct Config: Codable, Equatable {
    /// How often the presence loop runs.
    public var tickIntervalSeconds: Double = 4
    /// Continuous absence required before locking (absorbs brief turn-aways).
    public var graceSeconds: Double = 25
    /// Cosine-similarity threshold for an embedding to count as the enrolled user.
    public var matchThreshold: Double = 0.6
    /// Consecutive no-face/stranger ticks required to begin the grace countdown
    /// (the absence "consensus"). Debounces single-frame glitches: a lone bad
    /// reading can't start the lock clock; it takes 3 in a row.
    public var consecutiveAbsentTicksToLock: Int = 3
    /// A transient recognition error is held (presence unchanged), but after this
    /// many CONSECUTIVE errors the engine escalates to treating the tick as
    /// absence — so a wedged recognizer still locks rather than holding unlocked
    /// forever (EC-10, no indefinite fail-open).
    public var maxConsecutiveErrorsBeforeAbsent: Int = 3
    /// Slow the tick on battery to save power (EC-18). TODO(blart/homer).
    public var throttleOnBattery: Bool = true

    public init() {}
}
