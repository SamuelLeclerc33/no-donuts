import Foundation

// Owner: cooper — pure vector math for identity matching. Backlog: ND-024.
// Privacy: pure computation, no I/O, no network.

/// Cosine similarity between two embedding vectors, as a `Double` in roughly `[-1, 1]`
/// (`1` = identical direction, `0` = orthogonal / undefined).
///
/// Used to score a freshly computed face embedding against the enrolled reference
/// embeddings (see `IdentityRecognizer`). A score at or above the model's resolved
/// threshold (`resolvedMatchThreshold(for:)`) counts as the enrolled user.
///
/// Defensive by design — returns `0` (treated as "no match", never a false positive)
/// when the inputs are unusable:
/// - the two vectors have different lengths,
/// - either vector is empty,
/// - either vector has zero magnitude (all-zero embedding),
/// - any input component is non-finite (NaN/±Inf) — a corrupt feature-print blob
///   could contain non-finite floats,
/// - the computed result is non-finite.
///
/// Otherwise returns `dot(a, b) / (‖a‖ · ‖b‖)`.
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }

    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for i in 0..<a.count {
        let x = Double(a[i])
        let y = Double(b[i])
        // Fail-safe: a corrupt embedding with NaN/±Inf must never produce a match.
        guard x.isFinite, y.isFinite else { return 0 }
        dot += x * y
        normA += x * x
        normB += y * y
    }

    guard normA > 0, normB > 0 else { return 0 }
    let result = dot / (normA.squareRoot() * normB.squareRoot())
    // Guard against a non-finite result (overflow / NaN) → no match.
    return result.isFinite ? result : 0
}
