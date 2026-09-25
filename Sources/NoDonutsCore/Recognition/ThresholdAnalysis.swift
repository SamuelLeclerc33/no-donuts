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

/// The evidence bar a threshold study must clear before `recommendThreshold` will endorse
/// a tuned number (ND-094).
///
/// Why a bar at all: "every impostor scored below every genuine score" is trivially true
/// of ONE genuine and ONE impostor sample, and says nothing about the next face through
/// the door. A tuned `matchThreshold` is a security parameter, so the recommendation
/// refuses — and says exactly why — unless the study is big enough, covers more than one
/// stranger, and shows a real gap rather than a hair's-breadth one.
public struct ThresholdStudyRequirements: Sendable, Equatable {
    /// Default minimum GENUINE scores. 30 is the conventional floor below which a
    /// sample minimum is dominated by luck; with 30 clean genuine scores the observed
    /// false-reject rate is bounded at roughly 10% (rule of three, 95%) — a floor, not a
    /// target. More is better; real use spans lighting, glasses, angle, distance.
    public static let defaultMinimumGenuineSamples = 30
    /// Default minimum IMPOSTOR scores — same reasoning, for the false-accept side.
    public static let defaultMinimumImpostorSamples = 30
    /// Default minimum DISTINCT impostor identities. Thirty photos of ONE stranger
    /// measure how far that one face is from you, not how far strangers are in general;
    /// the closest look-alike (EC-03) is only findable across several people.
    public static let defaultMinimumImpostorIdentities = 2
    /// Default minimum gap `genuine minimum − impostor maximum` (cosine units). Below
    /// this the classes merely touch-don't-overlap on THIS sample: the next lighting
    /// change moves a score by more than that, so the "clean" gap is not evidence.
    public static let defaultMinimumSeparationMargin = 0.05

    public let minimumGenuineSamples: Int
    public let minimumImpostorSamples: Int
    public let minimumImpostorIdentities: Int
    public let minimumSeparationMargin: Double

    public init(
        minimumGenuineSamples: Int = defaultMinimumGenuineSamples,
        minimumImpostorSamples: Int = defaultMinimumImpostorSamples,
        minimumImpostorIdentities: Int = defaultMinimumImpostorIdentities,
        minimumSeparationMargin: Double = defaultMinimumSeparationMargin
    ) {
        self.minimumGenuineSamples = minimumGenuineSamples
        self.minimumImpostorSamples = minimumImpostorSamples
        self.minimumImpostorIdentities = minimumImpostorIdentities
        self.minimumSeparationMargin = minimumSeparationMargin
    }

    /// The shipped bar. Tests may pass a looser one; FaceScore always uses this.
    public static let standard = ThresholdStudyRequirements()
}

/// One unmet criterion, with how far short the study fell.
public enum ThresholdShortfall: Sendable, Equatable, CustomStringConvertible {
    case genuineSamples(have: Int, need: Int)
    case impostorSamples(have: Int, need: Int)
    /// `have == nil` means the caller did not say how many distinct people the impostor
    /// scores came from. Unknown is treated as unmet — a refusal, never a guess.
    case impostorIdentities(have: Int?, need: Int)
    case separationMargin(have: Double, need: Double)

    public var description: String {
        switch self {
        case let .genuineSamples(have, need):
            return "genuine samples \(have) < \(need) required (need \(need - have) more)"
        case let .impostorSamples(have, need):
            return "impostor samples \(have) < \(need) required (need \(need - have) more)"
        case let .impostorIdentities(have?, need):
            return "distinct impostor identities \(have) < \(need) required (need \(need - have) more people)"
        case let .impostorIdentities(nil, need):
            return "distinct impostor identities unknown (\(need) required) — caller did not report them"
        case let .separationMargin(have, need):
            return String(format: "separation margin %.4f < %.4f required (short by %.4f)", have, need, need - have)
        }
    }
}

/// What the measured data can (or cannot) justify as a `matchThreshold`.
public enum ThresholdRecommendation: Sendable, Equatable {
    /// The study does not clear `ThresholdStudyRequirements`: a class is missing, too
    /// few samples, too few distinct impostors, or the gap is too narrow. `shortfalls`
    /// lists EVERY unmet criterion and by how much; `reason` is the same, human-readable.
    ///
    /// Notably this is the verdict for GENUINE-ONLY data — the state the project was in
    /// before this harness existed. Genuine scores bound the false-reject rate and carry
    /// no information about false-accept, so they cannot support a threshold no matter
    /// how many samples there are.
    case insufficientData(reason: String, shortfalls: [ThresholdShortfall])

    /// Every impostor scored below every genuine score, by at least the required margin,
    /// on a study that meets every count requirement. A threshold in the gap has zero
    /// measured error in both directions; the midpoint maximizes the margin against
    /// future samples drifting either way.
    case cleanSeparation(threshold: Double, margin: Double, impostorMaximum: Double, genuineMinimum: Double)

    /// The distributions overlap: at least one impostor scored at or above at least one
    /// genuine sample. NO scalar threshold separates them — every choice trades a false
    /// lock against a stranger accepted. Reported regardless of sample size (more data
    /// cannot un-observe an impostor that matched). The equal-error point is for
    /// information and is explicitly NOT an endorsement to ship.
    case overlap(equalErrorThreshold: Double, falseRejectRate: Double, falseAcceptRate: Double)

    /// Whether this result justifies flipping a descriptor's `thresholdIsTuned` to true.
    /// Only clean separation does. This is the guard that keeps an un-earned "tuned"
    /// claim out of a security-relevant descriptor.
    public var justifiesTunedFlag: Bool {
        if case .cleanSeparation = self { return true }
        return false
    }

    /// Why the recommendation REFUSED to endorse a threshold; `nil` only for clean separation.
    public var refusalReason: String? {
        switch self {
        case let .insufficientData(reason, _):
            return reason
        case .cleanSeparation:
            return nil
        case let .overlap(t, frr, far):
            return String(format: "distributions overlap — an impostor scored at or above a genuine sample "
                          + "(equal-error ~%.2f: FRR %.2f%%, FAR %.2f%%)", t, frr * 100, far * 100)
        }
    }
}

/// Derive a threshold recommendation from measured genuine and impostor scores.
///
/// Order of verdicts:
/// 1. Overlap (both classes present, impostor max ≥ genuine min) → `.overlap`, whatever
///    the sample size: an impostor that matched is a finding, not noise.
/// 2. Any unmet `requirements` criterion → `.insufficientData`, listing ALL shortfalls.
/// 3. Otherwise → `.cleanSeparation` at the gap midpoint.
///
/// - Parameters:
///   - genuine: scores of the enrolled user against their own references.
///   - impostor: scores of OTHER people against those same references.
///   - impostorIdentityCount: how many DISTINCT people the impostor scores came from.
///     `nil` (unknown) never satisfies the identity requirement — pass it.
///   - requirements: the evidence bar; `.standard` unless a test says otherwise.
///   - searchStep: granularity of the equal-error search in the overlap case.
public func recommendThreshold(
    genuine: ScoreDistribution,
    impostor: ScoreDistribution,
    impostorIdentityCount: Int? = nil,
    requirements: ThresholdStudyRequirements = .standard,
    searchStep: Double = 0.01
) -> ThresholdRecommendation {
    // 1) Overlap is decisive on any sample size.
    if let genuineMinimum = genuine.minimum, let impostorMaximum = impostor.maximum,
       impostorMaximum >= genuineMinimum {
        return equalErrorOverlap(genuine: genuine, impostor: impostor, searchStep: searchStep)
    }

    // 2) Collect every unmet criterion, so one run tells you everything to fix.
    var shortfalls: [ThresholdShortfall] = []
    if genuine.count < requirements.minimumGenuineSamples {
        shortfalls.append(.genuineSamples(have: genuine.count, need: requirements.minimumGenuineSamples))
    }
    if impostor.count < requirements.minimumImpostorSamples {
        shortfalls.append(.impostorSamples(have: impostor.count, need: requirements.minimumImpostorSamples))
    }
    if let identities = impostorIdentityCount {
        if identities < requirements.minimumImpostorIdentities {
            shortfalls.append(.impostorIdentities(have: identities, need: requirements.minimumImpostorIdentities))
        }
    } else {
        shortfalls.append(.impostorIdentities(have: nil, need: requirements.minimumImpostorIdentities))
    }

    guard let genuineMinimum = genuine.minimum, let impostorMaximum = impostor.maximum else {
        var reasons: [String] = []
        if genuine.isEmpty { reasons.append("no genuine scores") }
        if impostor.isEmpty { reasons.append("no impostor scores — genuine-only data cannot justify a threshold") }
        reasons += shortfalls.map(\.description)
        return .insufficientData(reason: reasons.joined(separator: "; "), shortfalls: shortfalls)
    }

    let margin = genuineMinimum - impostorMaximum
    if margin < requirements.minimumSeparationMargin {
        shortfalls.append(.separationMargin(have: margin, need: requirements.minimumSeparationMargin))
    }

    guard shortfalls.isEmpty else {
        return .insufficientData(reason: shortfalls.map(\.description).joined(separator: "; "),
                                 shortfalls: shortfalls)
    }

    return .cleanSeparation(
        threshold: (impostorMaximum + genuineMinimum) / 2,
        margin: margin,
        impostorMaximum: impostorMaximum,
        genuineMinimum: genuineMinimum
    )
}

/// Sweep for the point where false-reject and false-accept are closest (the equal-error
/// rate), the conventional summary of an inseparable pair.
private func equalErrorOverlap(
    genuine: ScoreDistribution,
    impostor: ScoreDistribution,
    searchStep: Double
) -> ThresholdRecommendation {
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
