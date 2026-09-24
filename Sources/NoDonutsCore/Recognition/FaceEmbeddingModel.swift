import Foundation

// Owner: cooper — model-agnostic descriptor for a face-embedding model. Backlog: ND-021.
// ADR-0014 (amends ADR-0012). Privacy: pure value type, no I/O, no network.

/// Static, model-driven description of *which* embedding model an embedder implements —
/// the seam that makes swapping the embedder (Vision feature print → Core ML FaceNet →
/// a later permissive ArcFace, etc.) a low-friction change (ADR-0014 / ND-021).
///
/// Every `FaceEmbedding` carries a descriptor so matching, thresholds, preprocessing,
/// and — critically — **embedding versioning** are driven by the model, not hardcoded at
/// the call site. Two things depend on it directly:
///
/// 1. **Threshold source of truth.** `defaultMatchThreshold` is the model's own tuned (or,
///    for an un-tuned model, provisional) cosine cutoff — the SOLE default that
///    `resolvedMatchThreshold(for:)` falls back to, overridable only via the model's own
///    per-model key (`thresholdOverrideKey`) and only within `matchThresholdRange`
///    (ND-076). Absolute cosine scores are NOT comparable across
///    models (a general image feature print and a face-optimized FaceNet embedding live on
///    different scales), so the threshold MUST travel with the model.
///
/// 2. **Forced re-enrollment on model change.** `version` is a stable id/version tag stamped
///    onto every stored enrollment (`EnrollmentStore`). On load, if the stored tag differs
///    from the active embedder's `version`, the enrollment is treated as NOT the current
///    model's and re-enrollment is forced — we NEVER cross-compare vectors produced by
///    different models (their coordinate spaces are unrelated; a stale compare is garbage
///    that could false-accept or false-reject). See `IdentityRecognizer`.
///
/// A pure `Sendable` value type: no I/O, no framework imports — testable in any toolchain
/// (ADR-0007), and safe to pass across actors.
public struct FaceEmbeddingModelDescriptor: Sendable, Equatable {
    /// Stable model id + version tag, e.g. `"vision-featureprint-v1"` or
    /// `"facenet-vggface2-v1"`. Stamped onto stored enrollments and compared on load to
    /// force re-enrollment when the model changes. BUMP this whenever the produced
    /// embedding space changes in a way that invalidates existing enrollments (new model,
    /// new preprocessing, new output layout) — a bump is the trigger for re-enroll.
    public let version: String

    /// Human-readable model name for logs / diagnostics (never a secret; safe to log).
    public let displayName: String

    /// Expected square input side in pixels the model consumes (e.g. `160` for FaceNet
    /// 160×160). `0` means "no fixed input size" (e.g. the Vision feature print, which
    /// accepts the arbitrary-sized face crop directly). Informational for the Core ML
    /// preprocessing path; not enforced by the pure-math matcher.
    public let inputSize: Int

    /// Dimension of the produced embedding vector (e.g. `512` for FaceNet / ArcFace,
    /// or the Vision feature print's own element count). Informational + a sanity anchor;
    /// `cosineSimilarity` already fails safe (→ 0, no match) on any length mismatch.
    public let outputDimension: Int

    /// The model's default cosine match threshold — the sole default the recognizer uses
    /// (overridable live via the per-model `thresholdOverrideKey` UserDefaults key, within
    /// `matchThresholdRange`). Because score scales differ per model, this is a per-model
    /// value, not a global constant (ND-076).
    public let defaultMatchThreshold: Double

    /// The ONLY range a user/`defaults write` override of this model's threshold is
    /// accepted in (ND-076). An override outside it is REJECTED (→ `defaultMatchThreshold`),
    /// never clamped, so an injected `0.01` can't land on the floor. The floor is the
    /// security-relevant bound: below it, near-any face would clear identity on this
    /// model's score scale (fail-open, EC-03). The ceiling guards against a permanent
    /// lockout of the real user. Always contains `defaultMatchThreshold` (asserted in init).
    public let matchThresholdRange: ClosedRange<Double>

    /// True when `defaultMatchThreshold` is a provisional guess that has NOT yet been tuned
    /// against real device data (false-accept vs false-reject, incl. the EC-03 look-alike).
    /// Surfaced so diagnostics/logs can be honest that identity separation is not yet
    /// validated for this model.
    public let thresholdIsTuned: Bool

    public init(
        version: String,
        displayName: String,
        inputSize: Int,
        outputDimension: Int,
        defaultMatchThreshold: Double,
        matchThresholdRange: ClosedRange<Double>,
        thresholdIsTuned: Bool
    ) {
        precondition(matchThresholdRange.contains(defaultMatchThreshold),
                     "defaultMatchThreshold \(defaultMatchThreshold) outside matchThresholdRange \(matchThresholdRange)")
        self.version = version
        self.displayName = displayName
        self.inputSize = inputSize
        self.outputDimension = outputDimension
        self.defaultMatchThreshold = defaultMatchThreshold
        self.matchThresholdRange = matchThresholdRange
        self.thresholdIsTuned = thresholdIsTuned
    }

    /// Per-model UserDefaults key for a threshold override (ND-076), e.g.
    /// `"matchThreshold.facenet-vggface2-v1"`. Keyed on `version` so a value tuned for one
    /// model never carries over to another (their score scales are unrelated).
    public var thresholdOverrideKey: String { "matchThreshold.\(version)" }
}

public extension FaceEmbeddingModelDescriptor {
    /// Descriptor for the `VisionFeaturePrintEmbedder` (ADR-0012). Threshold `0.6`, a
    /// lenient general-feature-print default; override range `0.40...0.95` (ND-076).
    /// `inputSize = 0` (Vision accepts the arbitrary-sized crop);
    /// `outputDimension = 0` (the feature print's element count is model-internal and not
    /// asserted). Marked un-tuned — it has never been tuned against real data.
    ///
    /// Version tag `"vision-featureprint-v1"` is the tag legacy (untagged) enrollments are
    /// treated as belonging to (see `EnrollmentStore`), so shipping this descriptor does
    /// NOT force a re-enroll of users already enrolled under the Vision embedder — only a
    /// genuine model SWAP (e.g. to FaceNet) does.
    static let visionFeaturePrint = FaceEmbeddingModelDescriptor(
        version: "vision-featureprint-v1",
        displayName: "Apple Vision feature print",
        inputSize: 0,
        outputDimension: 0,
        defaultMatchThreshold: 0.6,
        matchThresholdRange: 0.40...0.95,
        thresholdIsTuned: false
    )

    /// Descriptor for the internal-use FaceNet model (ADR-0014): `facenet-pytorch`
    /// InceptionResnetV1 pretrained on VGGFace2, converted to Core ML locally. Input
    /// 160×160 RGB (normalization `(x-127.5)/128` folded into the Core ML `ImageType`);
    /// output a 512-dim vector the model L2-normalizes (we re-normalize defensively).
    ///
    /// `defaultMatchThreshold = 0.5` is a PROVISIONAL, UN-TUNED starting guess (mirroring
    /// how the Vision `0.6` is documented as needing tuning): FaceNet/VGGFace2 cosine
    /// scores for same-person pairs typically sit well above different-person pairs, but
    /// the real cutoff — especially the EC-03 look-alike ("Marco") margin — MUST be tuned
    /// on device captures before this model is trusted for distribution. `thresholdIsTuned`
    /// is therefore `false`. Override range `0.40...0.90` (ND-076): the measured genuine
    /// p5 is ~0.66, and below 0.40 near-any face would clear on this scale.
    ///
    /// Version tag `"facenet-vggface2-v1"` — distinct from the Vision tag, so activating
    /// this embedder forces a one-time re-enroll (stored Vision vectors are never
    /// cross-compared against FaceNet's space).
    static let facenetVGGFace2 = FaceEmbeddingModelDescriptor(
        version: "facenet-vggface2-v1",
        displayName: "FaceNet (InceptionResnetV1, VGGFace2)",
        inputSize: 160,
        outputDimension: 512,
        defaultMatchThreshold: 0.5,
        matchThresholdRange: 0.40...0.90,
        thresholdIsTuned: false
    )
}
