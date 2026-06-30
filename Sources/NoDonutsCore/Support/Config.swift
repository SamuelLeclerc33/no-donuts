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
    /// Consecutive ABSENT ticks required to begin the grace countdown (debounce).
    public var consecutiveAbsentTicksToLock: Int = 2
    /// Slow the tick on battery to save power (EC-18). TODO(blart/homer).
    public var throttleOnBattery: Bool = true

    public init() {}
}
