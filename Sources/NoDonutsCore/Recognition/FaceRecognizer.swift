import Foundation
import os

// Owner: cooper — Vision detection + Core ML embeddings + matching.
// Backlog: ND-020, ND-021, ND-024. ADR-0002. Privacy: all on-device, no network.

/// Detects faces and decides whether the enrolled user is present in a frame.
public protocol FaceRecognizing: Sendable {
    func recognize(_ frame: CapturedFrame) async -> RecognitionResult
}

/// Identity recognizer (ND-021/ND-024, ADR-0012): decides whether the *enrolled*
/// user — not just any face — is present, using a `FaceEmbedding` + cosine matching.
///
/// Fully dependency-injected so it is unit-testable **without** Vision, a camera, or
/// the Keychain: pass a fake `FaceEmbedding` and an `InMemoryEnrollmentStore`.
///
/// The embedder returns a tri-state `FaceEmbeddingOutcome`: `.embedding` (a face was
/// found + embedded), `.noFace` (Vision ran, no face), or `.failure` (detection / crop /
/// feature-print error). The recognizer must NOT collapse `.failure` into `.noFace`: a
/// `.failure` maps to `RecognitionResult.error`, which the presence engine holds
/// conservatively (EC-10) rather than counting toward the absence consensus — so a
/// transient Vision glitch can't lock a present user.
///
/// The store returns a tri-state `EnrollmentState`: `.enrolled`, `.notEnrolled`, or
/// `.unavailable` (Keychain read failed). `.unavailable` maps to `.error` (fail-safe) —
/// it must NEVER downgrade to the presence-only fallback (that would let any face pass
/// on an enrolled machine, S1 / EC-03).
///
/// Decision table (one `enrollmentState()` read + one embed per call):
/// - store `.unavailable`                          → `.error` (fail-safe; engine holds, sustained → lock)
/// - embed `.failure`                              → `.error` (EC-10 hold)
/// - embed `.noFace`                               → `.noFace`
/// - embed `.embedding`, store `.notEnrolled`      → `.enrolledUserPresent(1.0)` (presence-only, only when GENUINELY not enrolled)
/// - embed `.embedding`, store `.enrolled(refs, ver)` where `ver != active model version`
///     → presence-only fallback (STALE / cross-model — force re-enroll; NEVER cross-compare, ADR-0014)
/// - embed `.embedding`, store `.enrolled(refs, ver)` matching version → max cosine vs refs;
///     `>= threshold` → `.enrolledUserPresent(max)`, else `.strangerOnly` (EC-03: non-match never present)
///
/// **Embedding versioning (ADR-0014):** the stored enrollment records the model
/// `version` that produced it. If that differs from the active embedder's descriptor
/// version (a model swap, or a legacy `nil`-version record), the vectors live in an
/// unrelated embedding space — cross-comparing them is garbage that could false-accept or
/// false-reject. So a version mismatch is treated as NOT enrolled for this model → the
/// presence-only fallback (honest: identity re-engages once the user re-enrolls under the
/// new model). We NEVER silently compare cross-model vectors.
///
/// **Identity status (ND-073):** that presence-only fallback must never be SILENT. From
/// the same single `enrollmentState()` read, each `recognize()` also publishes
/// `lastIdentityStatus` (via the pure `identityStatus(for:activeVersion:markerVersion:)`)
/// for the App to surface loudly. Recognition RESULTS are unaffected by it:
/// - store `.enrolled`, version == active           → `.active`
/// - store `.enrolled`, version != active (or nil)  → `.off(.modelMismatch)` (presence-only above)
/// - store `.notEnrolled`, no marker                → `.notEnrolled`
/// - store `.notEnrolled`, marker set               → `.off(.enrollmentMissing)` (Keychain item
///     deleted outside the app; still presence-only — no lockout loop)
/// - store `.unavailable`                           → status NOT overwritten (keeps the previous
///     value, so a flaky Keychain read can't flap the UI/notifier). Initial value `.unknown`.
///
/// `Sendable`: the presence engine (ADR-0005, `@MainActor`) awaits `recognize()` from
/// the main actor. No main-actor work happens here — the heavy lifting is inside the
/// injected `FaceEmbedding`, which offloads to its own queue.
public final class IdentityRecognizer: FaceRecognizing, Sendable {
    private let embedder: FaceEmbedding
    private let store: EnrollmentStoring
    /// Optional non-secret enrollment marker (ND-073) — distinguishes "Keychain item
    /// deleted" from "never enrolled". `nil` → a `.notEnrolled` read is `.notEnrolled`.
    private let marker: EnrollmentMarkerStoring?
    /// Last published identity status (ND-073). Lock-guarded; `OSAllocatedUnfairLock`
    /// is `Sendable`, so the class stays checked-`Sendable`.
    private let statusLock = OSAllocatedUnfairLock<IdentityStatus>(initialState: .unknown)

    /// Identity status computed from the most recent `recognize()` store read (ND-073).
    /// `.unknown` until the first successful read; never overwritten by `.unavailable`.
    public var lastIdentityStatus: IdentityStatus {
        statusLock.withLock { $0 }
    }

    /// Match-score logging for threshold tuning (ND-024). Logs ONLY the numeric cosine
    /// score, the threshold, and the decision — never an embedding or image (privacy).
    private let log = Logger(subsystem: "com.nodonuts.app", category: "recognition")

    /// - Parameters:
    ///   - embedder: the active `FaceEmbedding`; its `descriptor` is the SOLE source of the
    ///     match threshold (default + per-model override key + accepted range, ND-076)
    ///     and the active model version used for the re-enroll check (ADR-0014).
    ///   - store: enrollment store.
    ///   - marker: optional non-secret enrollment marker (ND-073) used only to compute
    ///     `lastIdentityStatus`; it never changes a recognition result.
    public init(embedder: FaceEmbedding, store: EnrollmentStoring,
                marker: EnrollmentMarkerStoring? = nil) {
        self.embedder = embedder
        self.store = store
        self.marker = marker
    }

    public func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        // ONE Keychain read per tick. A read failure is fail-safe: .error (never
        // presence-only), so a stranger can't pass on an enrolled machine (S1/EC-03).
        let state = store.enrollmentState()
        if case .unavailable = state {
            // ND-073: keep the previous status — don't flap on a transient read failure.
            return .error("enrollment store unavailable")
        }
        // ND-073: publish identity status from the SAME read (no extra Keychain access).
        // Status only — the recognition decision below is unchanged.
        let status = identityStatus(for: state,
                                    activeVersion: embedder.descriptor.version,
                                    markerVersion: marker?.markerVersion)
        statusLock.withLock { $0 = status }

        // ND-040 / ND-076: resolve the match threshold LIVE per call from the active
        // model's own per-model key, falling back to the model's default (out-of-range
        // overrides rejected). A Settings change takes effect on the very next tick.
        let threshold = resolvedMatchThreshold(for: embedder.descriptor)

        switch await embedder.embeddingWithLiveness(for: frame) {
        case .failure:
            // Transient detection/embedding failure → conservative HOLD (EC-10), not absence.
            return .error("face embedding failed")
        case .noFace:
            return .noFace
        case let .embedding(vector, textureScore):
            switch state {
            case .notEnrolled:
                // Presence-only fallback — only when GENUINELY not enrolled (non-breaking).
                // Anti-spoof is intentionally NOT applied here: before identity is set up
                // we don't want surprising flat-image locks (ND-041 decision).
                return .enrolledUserPresent(confidence: 1.0)
            case .enrolled(let references, let storedVersion):
                // ADR-0014 embedding versioning: the stored vectors were produced by
                // `storedVersion`. If that isn't the active model's version (a model swap,
                // or a legacy `nil`-version record), the coordinate spaces are unrelated —
                // cross-comparing is garbage. Treat as NOT enrolled for this model → the
                // presence-only fallback (identity re-engages after the user re-enrolls).
                // NEVER silently compare cross-model vectors.
                let activeVersion = embedder.descriptor.version
                guard storedVersion == activeVersion else {
                    log.notice("enrollment model version mismatch (stored \(storedVersion ?? "<legacy/none>", privacy: .public) vs active \(activeVersion, privacy: .public)) → forcing re-enrollment; presence-only until re-enrolled")
                    return .enrolledUserPresent(confidence: 1.0)
                }
                // Defensive: enrolled-but-empty shouldn't happen; presence-only rather
                // than lock out the real user.
                guard !references.isEmpty else { return .enrolledUserPresent(confidence: 1.0) }
                let maxSim = references.reduce(0.0) { best, ref in
                    max(best, cosineSimilarity(vector, ref))
                }
                // EC-03: a detected face that doesn't clear the threshold is NEVER present.
                let present = maxSim >= threshold
                // ND-024 tuning: log the score/threshold/decision (numbers only — no
                // embedding, no image — privacy). Enrolled branch only; the presence-only
                // (not-enrolled) path is not logged.
                log.notice("identity match: score \(maxSim, privacy: .public) vs threshold \(threshold, privacy: .public) → \(present ? "present" : "stranger", privacy: .public)")
                guard present else { return .strangerOnly }

                // ND-041 anti-spoof (EC-12): only when the face MATCHES do we apply the
                // conservative liveness check. If enabled AND the crop is unambiguously
                // flat (below the floor) → treat as a spoof → .strangerOnly (locks). The
                // bias is heavily toward LIVE: a normal live face never falls below the
                // floor, and the whole check is toggleable via `antiSpoofEnabled`.
                //
                // ND-041 / FIX #6: resolve the floor LIVE per call (like matchThreshold),
                // so it is tunable via `defaults write com.nodonuts.app spoofTextureFloor
                // <n>` with no relaunch — and effectively disable-able by a very low
                // positive value. When anti-spoof is off the embedder already returned the
                // `.infinity` sentinel (never flagged), so this branch is a cheap no-op.
                if resolvedAntiSpoofEnabled() {
                    let floor = resolvedSpoofTextureFloor()
                    if isLikelySpoof(textureScore: textureScore, floor: floor) {
                        // Log the numeric score only — never an image or embedding (privacy).
                        log.notice("anti-spoof: flagged likely spoof — texture \(textureScore, privacy: .public) < floor \(floor, privacy: .public) → stranger")
                        return .strangerOnly
                    }
                }
                return .enrolledUserPresent(confidence: maxSim)
            case .unavailable:
                return .error("enrollment store unavailable")   // already handled above; exhaustive
            }
        }
    }
}
