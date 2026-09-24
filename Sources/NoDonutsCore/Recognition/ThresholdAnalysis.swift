import Foundation

// Owner: cooper — pure statistics for threshold tuning. Backlog: ND-056, ND-021 Phase 2.
// Privacy: pure computation over score arrays. No I/O, no images, no network.

/// Summary statistics for one set of similarity scores.
///
/// Lives in the core (not in the `FaceScore` tool) so the arithmetic that a shipped
/// `matchThreshold` rests on is covered by `EngineCheck`. A tuning number is a security
/// parameter: if the statistics behind it are wrong, the threshold is wrong, and the
/// failure is silent — a stranger who matches, or a real user locked out.
public struct ScoreDistribution: Sendable {
    /// Ascending scores. Sorted once at init so percentiles are plain indexing.
    public let sorted: [Double]

    public init(_ values: [Double]) {
        self.sorted = values.sorted()
    }

    public var count: Int { sorted.count }
    public var isEmpty: Bool { sorted.isEmpty }
    /// `nil` rather than NaN on an empty set — an absent statistic must be impossible
    /// to mistake for a real one when it reaches a decision.
    public var minimum: Double? { sorted.first }
    public var maximum: Double? { sorted.last }

    public var mean: Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted.reduce(0, +) / Double(sorted.count)
    }

    /// Population standard deviation. `nil` for fewer than 2 samples (undefined spread).
    public var standardDeviation: Double? {
        guard sorted.count > 1, let m = mean else { return nil }
        let sumOfSquares = sorted.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return (sumOfSquares / Double(sorted.count)).squareRoot()
    }

    /// Nearest-rank percentile for `fraction` in `[0, 1]`; `nil` when empty.
    ///
    /// Nearest-rank (not interpolated) on purpose: every value it returns is a score
    /// that was actually OBSERVED, so "p5 = 0.66" names a real image that scored 0.66
    /// and can be looked at. An interpolated percentile invents a number between two
    /// samples, which is a poor basis for a security threshold.
    public func percentile(_ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let clamped = Swift.max(0.0, Swift.min(1.0, fraction))
        let index = Int((clamped * Double(sorted.count)).rounded(.down))
        return sorted[Swift.min(index, sorted.count - 1)]
    }
}

/// Fraction of GENUINE scores falling BELOW `threshold` — the enrolled user rejected,
/// which in this app means a false LOCK.
///
/// Uses `<` to mirror `IdentityRecognizer`'s `maxSim >= threshold` accept test exactly:
/// a score equal to the threshold is ACCEPTED there, so it must not count as a reject
/// here. An off-by-one in this comparison would bias every threshold this harness
/// recommends.
public func falseRejectRate(genuine: ScoreDistribution, at threshold: Double) -> Double? {
    guard !genuine.isEmpty else { return nil }
    let rejected = genuine.sorted.reduce(into: 0) { count, score in
        if score < threshold { count += 1 }
    }
    return Double(rejected) / Double(genuine.count)
}

/// Fraction of IMPOSTOR scores at or ABOVE `threshold` — a stranger accepted as the
/// enrolled user. This is the EC-03 failure the identity check exists to prevent.
///
/// Uses `>=`, again mirroring `IdentityRecognizer` exactly.
public func falseAcceptRate(impostor: ScoreDistribution, at threshold: Double) -> Double? {
    guard !impostor.isEmpty else { return nil }
    let accepted = impostor.sorted.reduce(into: 0) { count, score in
        if score >= threshold { count += 1 }
    }
    return Double(accepted) / Double(impostor.count)
}

/// What the measured data can (or cannot) justify as a `matchThreshold`.
public enum ThresholdRecommendation: Sendable, Equatable {
    /// One or both classes are missing. Notably this is the verdict for GENUINE-ONLY
    /// data — the state the project was in before this harness existed. Genuine scores
    /// bound the false-reject rate and carry no information about false-accept, so they
    /// cannot support a threshold no matter how many samples there are.
    case insufficientData(reason: String)

    /// Every impostor scored below every genuine score. The classes are separable, so a
    /// threshold in the gap has zero measured error in both directions; the midpoint
    /// maximizes the margin against future samples drifting either way.
    case cleanSeparation(threshold: Double, margin: Double, impostorMaximum: Double, genuineMinimum: Double)

    /// The distributions overlap: at least one impostor outscored at least one genuine
    /// sample. NO scalar threshold separates them — every choice trades a false lock
    /// against a stranger accepted. The equal-error point is reported for information,
    /// and is explicitly NOT an endorsement to ship.
    case overlap(equalErrorThreshold: Double, falseRejectRate: Double, falseAcceptRate: Double)

    /// Whether this result justifies flipping a descriptor's `thresholdIsTuned` to true.
    /// Only clean separation does. This is the guard that keeps an un-earned "tuned"
    /// claim out of a security-relevant descriptor.
    public var justifiesTunedFlag: Bool {
        if case .cleanSeparation = self { return true }
        return false
    }
}

/// Derive a threshold recommendation from measured genuine and impostor scores.
///
/// - Parameters:
///   - genuine: scores of the enrolled user against their own references.
///   - impostor: scores of OTHER people against those same references.
///   - searchStep: granularity of the equal-error search in the overlap case.
public func recommendThreshold(
    genuine: ScoreDistribution,
    impostor: ScoreDistribution,
    searchStep: Double = 0.01
) -> ThresholdRecommendation {
    guard let genuineMinimum = genuine.minimum else {
        return .insufficientData(reason: "no genuine scores")
    }
    guard let impostorMaximum = impostor.maximum else {
        return .insufficientData(reason: "no impostor scores — genuine-only data cannot justify a threshold")
    }

    if impostorMaximum < genuineMinimum {
        return .cleanSeparation(
            threshold: (impostorMaximum + genuineMinimum) / 2,
            margin: genuineMinimum - impostorMaximum,
            impostorMaximum: impostorMaximum,
            genuineMinimum: genuineMinimum
        )
    }

    // Overlapping. Sweep for the point where false-reject and false-accept are closest
    // (the equal-error rate), which is the conventional summary of an inseparable pair.
    let step = searchStep > 0 ? searchStep : 0.01
    var bestThreshold = 0.5
    var bestGap = Double.infinity
    var bestFalseReject = 0.0
    var bestFalseAccept = 0.0

    var threshold = step
    while threshold < 1.0 {
        if let frr = falseRejectRate(genuine: genuine, at: threshold),
           let far = falseAcceptRate(impostor: impostor, at: threshold) {
            let gap = abs(frr - far)
            if gap < bestGap {
                bestGap = gap
                bestThreshold = threshold
                bestFalseReject = frr
                bestFalseAccept = far
            }
        }
        threshold += step
    }

    return .overlap(
        equalErrorThreshold: bestThreshold,
        falseRejectRate: bestFalseReject,
        falseAcceptRate: bestFalseAccept
    )
}
