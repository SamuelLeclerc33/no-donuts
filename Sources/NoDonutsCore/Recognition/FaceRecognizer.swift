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
/// Decision table (one `enrollmentState()` read + one embed per call; ND-059: on the
/// enrolled path, up to two embeds — the second largest face only when the largest
/// doesn't match, `FaceSelection.anyOfTop2`):
/// - store `.unavailable`                          → `.error` (fail-safe; engine holds, sustained → lock)
/// - embed `.failure`                              → `.error` (EC-10 hold)
/// - embed `.noFace`                               → `.noFace`
/// - embed `.embedding`, store `.notEnrolled`      → `.enrolledUserPresent(1.0)` (presence-only, only when GENUINELY not enrolled)
/// - embed `.embedding`, store `.enrolled(refs, ver)` where `ver != active model version`
///     → presence-only fallback (STALE / cross-model — force re-enroll; NEVER cross-compare, ADR-0014)
/// - embed `.embedding`, store `.enrolled(refs, ver)` matching version → max cosine vs refs;
///     `>= threshold` → `.enrolledUserPresent(max)`, else `.strangerOnly` (EC-03: non-match never present).
///     ND-059: the user matching as EITHER of the two largest faces counts; `.strangerOnly`
///     only when neither matches (the largest face's score is reported then). With
///     anti-spoof on, a match must also be CONFIRMED (texture not flat, live) or the
///     second face is tried; if neither is a confirmed match, the largest matching face is
///     returned and rejected below exactly as before. The texture / liveness decision is
///     always re-derived here from the returned face (ADR-0023).
/// - a MATCH with anti-spoof on: texture flagged → `.strangerOnly` (ND-041); otherwise no
///     live evidence (blink / non-rigid motion) in the window → `.notLive` (ND-116)
///
/// **Liveness (ND-116, EC-12):** a phone-screen photo of the user matches and passes the
/// texture check, so on the ENROLLED-MATCH path only, the injected `LivenessProviding`
/// must also report live evidence within its window. Gated by the same
/// `antiSpoofEnabled` toggle ("Reject photos of me"): off → liveness is not required.
/// The not-enrolled / version-mismatch / empty-references presence-only paths are NOT
/// gated (identity isn't set up; no surprise locks). `liveness == nil` (FaceScore,
/// most checks) → not required.
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
/// **Confidence semantics:** the `confidence` carried by `.enrolledUserPresent` is the
/// max cosine match score on the identity path, and a fixed `1.0` on every presence-only
/// fallback (not enrolled / version mismatch / empty references). It is never a Vision
/// face-*detection* confidence. The presence engine switches on the result case alone,
/// never on this magnitude; it is surfaced for logging and tuning only (ND-024).
///
/// There is deliberately NO standalone "any face = present" recognizer (the old
/// presence-only `FaceDetectionRecognizer` was removed in ND-068): presence-only
/// behaviour exists only as an explicit, status-published branch of this class, so it
/// can never be wired in by mistake on an enrolled machine.
///
/// Privacy (ADR-0002 / SECURITY_PRIVACY): detection and embedding run entirely
/// on-device. Each frame is analyzed in memory and discarded; only the enrollment
/// reference embeddings are persisted (encrypted, in the Keychain). No image, frame,
/// or derived data is ever sent over a network.
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
    /// ND-116 live-evidence source; `nil` → liveness not required.
    private let liveness: LivenessProviding?
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
    private let log = Logger(subsystem: Log.subsystem, category: "recognition")

    /// - Parameters:
    ///   - embedder: the active `FaceEmbedding`; its `descriptor` is the SOLE source of the
    ///     match threshold (default + per-model override key + accepted range, ND-076)
    ///     and the active model version used for the re-enroll check (ADR-0014).
    ///   - store: enrollment store.
    ///   - marker: optional non-secret enrollment marker (ND-073) used only to compute
    ///     `lastIdentityStatus`; it never changes a recognition result.
    ///   - liveness: ND-116 live-evidence source (production: `LivenessAnalyzer`). Only
    ///     consulted on an enrolled match with anti-spoof on.
    public init(embedder: FaceEmbedding, store: EnrollmentStoring,
                marker: EnrollmentMarkerStoring? = nil,
                liveness: LivenessProviding? = nil) {
        self.embedder = embedder
        self.store = store
        self.marker = marker
        self.liveness = liveness
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

        // ND-059 (EC-06): on a genuinely enrolled machine (version matches, references
        // present), accept ANY of the two largest faces that matches — lazily: the second
        // face is embedded only when the largest doesn't match. A colleague leaning in
        // closer than the user no longer reads as a stranger. Every presence-only path
        // (not enrolled / version mismatch / empty references) stays largest-only: it
        // only needs "a face", so a second embed would buy nothing.
        // ND-041/ND-116: ONE toggle read per tick gates texture AND liveness (both for the
        // selection's confirmation and for the decision below).
        let antiSpoof = resolvedAntiSpoofEnabled()
        let spoofFloor = resolvedSpoofTextureFloor()
        // One liveness verdict per face box per tick: the selection's confirmation and the
        // decision below share it (no double-counted not-live verdicts).
        let verdicts = VerdictCache(liveness: liveness)
        let selection: FaceSelection
        if case let .enrolled(references, storedVersion) = state,
           storedVersion == embedder.descriptor.version, !references.isEmpty {
            // The score (max cosine vs references) comes back in the report, so the
            // decision below uses this ONE evaluation: same threshold by construction.
            // ND-059 review (owner): an identity match must also be CONFIRMED (not a
            // likely flat spoof, live) or the second face is tried — a live user behind a
            // poster / photo of themselves. The decision below re-checks the returned face
            // itself, so this closure can only ever pick a face, never fail open.
            let confirms: (@Sendable (CGRect?, Double) -> Bool)? = antiSpoof ? { @Sendable box, texture in
                !isLikelySpoof(textureScore: texture, floor: spoofFloor)
                    && (verdicts.verdict(for: box)?.live ?? true)
            } : nil
            selection = .anyOfTop2(threshold: threshold, confirms: confirms) { vector in
                references.reduce(-Double.infinity) { max($0, cosineSimilarity(vector, $1)) }
            }
        } else {
            selection = .largestOnly
        }

        switch await embedder.embeddingWithLiveness(for: frame, selecting: selection) {
        case .failure:
            // Transient detection/embedding failure → conservative HOLD (EC-10), not absence.
            return .error("face embedding failed")
        case .noFace:
            return .noFace
        case let .embedding(vector, textureScore, faceBox, report):
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
                // ND-059: the selection already scored the RETURNED face; reuse it. Only an
                // embedder that didn't run `selectFace` (fakes: unscored report) is
                // evaluated here — with the SAME closure, so the threshold can't drift.
                let match = report.score.map { FaceMatch(accepted: report.accepted, score: $0) }
                    ?? selection.evaluate(vector)
                let maxSim = match.score ?? -Double.infinity
                // EC-03: a detected face that doesn't clear the threshold is NEVER present.
                let present = match.accepted
                // ND-116 review fix: evidence must belong to the MATCHED face's track
                // (ND-059: the returned face — the second largest when it was the match).
                // Re-derived here for the returned face (cached per box this tick).
                let verdict = (present && antiSpoof) ? verdicts.verdict(for: faceBox) : nil
                let liveText = verdict?.logDescription ?? (antiSpoof ? "n/a" : "n/a (anti-spoof off)")
                // ND-024 tuning: log the score/threshold/decision (numbers only — no
                // embedding, no image — privacy). Enrolled branch only; the presence-only
                // (not-enrolled) path is not logged. ND-072: the liveness texture score is
                // appended (a number; `inf` = anti-spoof off or not extractable) so the
                // spoof floor can be sanity-checked live against the real user's scores.
                // ND-116: plus the liveness verdict on a match (numbers only).
                log.notice("identity match: score \(maxSim, privacy: .public) vs threshold \(threshold, privacy: .public) → \(present ? "present" : "stranger", privacy: .public); texture \(textureScore, privacy: .public); live: \(present ? liveText : "n/a", privacy: .public); faces \(report.facesDetected, privacy: .public) embedded \(report.facesEmbedded, privacy: .public) chose #\(report.chosenRank + 1, privacy: .public)")
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
                if antiSpoof {
                    let floor = spoofFloor
                    if isLikelySpoof(textureScore: textureScore, floor: floor) {
                        // Log the numeric score only — never an image or embedding (privacy).
                        log.notice("anti-spoof: flagged likely spoof — texture \(textureScore, privacy: .public) < floor \(floor, privacy: .public) → stranger")
                        return .strangerOnly
                    }
                    // ND-116: the texture check can't stop a screen replay — also require
                    // live evidence (blink / non-rigid motion) within the window. Not
                    // live → `.notLive` (normal absence, NOT the stranger fast lock).
                    if let verdict, !verdict.live {
                        return .notLive
                    }
                }
                return .enrolledUserPresent(confidence: maxSim)
            case .unavailable:
                return .error("enrollment store unavailable")   // already handled above; exhaustive
            }
        }
    }
}

/// One liveness verdict per face box per `recognize()` call (ND-059 review): the
/// selection's confirmation and the final decision share it, so a face asked about twice
/// counts one verdict. Lock-guarded; lives for one tick.
private final class VerdictCache: Sendable {
    private let liveness: LivenessProviding?
    private let cache = OSAllocatedUnfairLock<[(box: CGRect?, verdict: LivenessVerdict)]>(initialState: [])
    init(liveness: LivenessProviding?) { self.liveness = liveness }

    /// `nil` when no liveness provider is wired (liveness not required).
    func verdict(for box: CGRect?) -> LivenessVerdict? {
        guard let liveness else { return nil }
        if let hit = cache.withLock({ c in c.first { $0.box == box }?.verdict }) { return hit }
        let v = liveness.currentVerdict(matchedFaceBox: box)
        cache.withLock { $0.append((box, v)) }
        return v
    }
}
