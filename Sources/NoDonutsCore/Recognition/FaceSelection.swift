import Foundation
import CoreGraphics

// Owner: cooper — which detected face(s) an embedder embeds (ND-059, EC-06).
// Privacy: pure control flow over in-memory vectors; no I/O, no logging, no network.

/// Which faces an embedder may embed for one frame, and when it may stop (ND-059).
///
/// Why: embedding only the LARGEST face made a colleague leaning in closer than the user
/// read as a stranger, which triggers the ADR-0017 fast lock on a present user (EC-06).
/// With `.anyOfTop2`, the embedder embeds the largest face first and embeds the second
/// largest ONLY if the first one isn't accepted. So a single face, or a user who is the
/// largest face, costs exactly what it did before.
///
/// The recognizer supplies `evaluate` (an enrolled-reference match at the live
/// threshold), so the embedder stays identity-agnostic and never sees the references
/// themselves. `evaluate` also returns the match SCORE, which the loop carries in the
/// report: the recognizer logs and decides from that one evaluation, so its threshold
/// and the selection's can't disagree and the references aren't scanned twice.
public struct FaceSelection: Sendable {
    /// Largest faces considered, clamped to `1...maxCandidateFaces`.
    public let maxFaces: Int
    /// Judges one vector: good enough to stop, and its match score (`nil` = unscored).
    /// `.largestOnly` accepts everything.
    public let evaluate: @Sendable ([Float]) -> FaceMatch
    /// Enrollment: a frame with more than one quality-passing face yields `.noFace`, so a
    /// second person in view can never contribute a reference vector.
    public let requireSingleFace: Bool
    /// Confirmation of an IDENTITY-accepted face (ND-059 review, owner decision): given
    /// its box and texture score, is it also real — not a likely flat spoof and live?
    /// `nil` = always confirmed (anti-spoof off, presence-only paths). Lets a live user
    /// who is the SECOND face count when the largest face is a photo / poster of them.
    /// The embedder never decides presence from it: the recognizer re-derives its
    /// decision from the returned face alone.
    public let confirms: (@Sendable (_ faceBox: CGRect?, _ textureScore: Double) -> Bool)?

    public init(maxFaces: Int, requireSingleFace: Bool = false,
                confirms: (@Sendable (_ faceBox: CGRect?, _ textureScore: Double) -> Bool)? = nil,
                evaluate: @escaping @Sendable ([Float]) -> FaceMatch) {
        self.maxFaces = clampedCandidateFaces(maxFaces)
        self.requireSingleFace = requireSingleFace
        self.confirms = confirms
        self.evaluate = evaluate
    }

    /// An unscored yes/no predicate (fakes, enrollment, presence-only paths).
    public init(maxFaces: Int, requireSingleFace: Bool = false,
                confirms: (@Sendable (_ faceBox: CGRect?, _ textureScore: Double) -> Bool)? = nil,
                accepts: @escaping @Sendable ([Float]) -> Bool) {
        self.init(maxFaces: maxFaces, requireSingleFace: requireSingleFace, confirms: confirms,
                  evaluate: { FaceMatch(accepted: accepts($0), score: nil) })
    }

    /// Yes/no view of `evaluate`.
    public func accepts(_ vector: [Float]) -> Bool { evaluate(vector).accepted }

    /// The pre-ND-059 behaviour: embed the largest face, whatever it is.
    public static let largestOnly = FaceSelection(maxFaces: 1, accepts: { _ in true })

    /// Enrollment (ND-059): exactly one quality-passing face, else `.noFace`.
    public static let enrollment = FaceSelection(maxFaces: 2, requireSingleFace: true, accepts: { _ in true })

    /// Recognition on an enrolled machine: largest face first, second largest only if
    /// the largest isn't accepted.
    public static func anyOfTop2(confirms: (@Sendable (_ faceBox: CGRect?, _ textureScore: Double) -> Bool)? = nil,
                                 _ accepts: @escaping @Sendable ([Float]) -> Bool) -> FaceSelection {
        FaceSelection(maxFaces: 2, confirms: confirms, accepts: accepts)
    }

    /// Scored form (the recognizer): accepted when `score(v) >= threshold` (a NaN score
    /// is never accepted). The score travels in `FaceSelectionReport.score`.
    public static func anyOfTop2(threshold: Double,
                                 confirms: (@Sendable (_ faceBox: CGRect?, _ textureScore: Double) -> Bool)? = nil,
                                 score: @escaping @Sendable ([Float]) -> Double) -> FaceSelection {
        FaceSelection(maxFaces: 2, confirms: confirms, evaluate: { v in
            let s = score(v)
            return FaceMatch(accepted: s >= threshold, score: s)
        })
    }
}

/// One `FaceSelection.evaluate` verdict (ND-059).
public struct FaceMatch: Sendable, Equatable {
    public let accepted: Bool
    /// The match score behind `accepted` (max cosine vs references); `nil` = unscored.
    public let score: Double?
    public init(accepted: Bool, score: Double?) {
        self.accepted = accepted
        self.score = score
    }
}

/// What the selection did, numbers only (ND-059), for the identity log line.
public struct FaceSelectionReport: Sendable, Equatable {
    /// Faces Vision detected in the frame (before ranking and the ND-085 gate).
    public let facesDetected: Int
    /// Faces actually embedded this call (1 or 2).
    public let facesEmbedded: Int
    /// Rank of the returned face: 0 = largest, 1 = second largest.
    public let chosenRank: Int
    /// Whether the returned vector passed `FaceSelection.evaluate`.
    public let accepted: Bool
    /// The returned vector's score from `FaceSelection.evaluate`; `nil` = unscored (fakes
    /// that don't run `selectFace`, unscored selections). The recognizer re-evaluates only then.
    public let score: Double?

    public init(facesDetected: Int, facesEmbedded: Int, chosenRank: Int, accepted: Bool,
                score: Double? = nil) {
        self.facesDetected = facesDetected
        self.facesEmbedded = facesEmbedded
        self.chosenRank = chosenRank
        self.accepted = accepted
        self.score = score
    }

    /// One face, embedded, returned (fakes and the single-face default). Unscored.
    public static let single = FaceSelectionReport(facesDetected: 1, facesEmbedded: 1, chosenRank: 0, accepted: true)
}

/// The shared face-selection loop (ND-059), used by BOTH production embedders and by
/// EngineCheck's multi-face fake, so the checks exercise the production logic.
///
/// - Parameters:
///   - facesDetected: raw Vision face count, for the report only.
///   - candidateCount: faces left after `rankedFaceCandidates` (top-N by area, then the
///     ND-085 gate), largest first. Rank `r` below indexes this list.
///   - embed: embed the face at rank `r`. Its `textureScore` is IGNORED (the loop fills
///     it from `texture`); `.failure` / `.noFace` mean "no vector for this face".
///   - texture: the anti-spoof texture score of the face at rank `r`. Called at most
///     once per face and at most twice per call (see below).
///
/// Rules (identity = `evaluate`, confirmation = `confirms`, ND-059 review):
/// - no candidate → `.noFace` (absence);
/// - `requireSingleFace` and more than one candidate → `.noFace`;
/// - embed #0; identity-accepted AND confirmed → return it (1 embed, 1 texture);
/// - otherwise, when `maxFaces` is 2 and there is a #1, embed #1; identity-accepted and
///   confirmed → return it (a live user behind a poster / photo of themselves);
/// - #0 identity-accepted but NOT confirmed, and #1 didn't give a confirmed match (not
///   the user, not confirmed, or FAILED) → return #0 as it is: the recognizer then
///   rejects it exactly as before (flat → stranger, not live → not live). Fail closed;
/// - #0 not accepted, #1 identity-accepted (confirmed or not) → return #1, as before;
/// - #0 not accepted, #1 not accepted → return #0 unaccepted (the stranger path);
/// - #0 not accepted and #1 FAILED (no vector) → `.failure` (the mirror of EC-10: #1 may
///   be the present user, so a glitch on it must hold, not fast-lock);
/// - #0 failed and #1 is not accepted → `.failure` (EC-10: a glitch on the largest face
///   must never turn into a stranger reading from the other face);
/// - #0 failed and #1 identity-accepted but NOT confirmed → `.failure` (same rule: only a
///   confirmed #1 may stand in for a glitched #0).
///
/// `texture` runs only for identity-accepted faces and for the face returned unaccepted
/// (the log's number), so at most twice per call.
public func selectFace(facesDetected: Int? = nil,
                       candidateCount: Int,
                       selection: FaceSelection,
                       embed: (Int) -> FaceEmbeddingResult,
                       texture: (Int) -> Double) -> FaceEmbeddingResult {
    guard candidateCount > 0 else { return .noFace }
    let detected = max(facesDetected ?? candidateCount, candidateCount)
    if selection.requireSingleFace, candidateCount > 1 { return .noFace }

    func report(_ embedded: Int, _ rank: Int, _ match: FaceMatch) -> FaceSelectionReport {
        FaceSelectionReport(facesDetected: detected, facesEmbedded: embedded, chosenRank: rank,
                            accepted: match.accepted, score: match.score)
    }
    func confirmed(_ box: CGRect?, _ texture: Double) -> Bool {
        selection.confirms?(box, texture) ?? true
    }
    func isFailure(_ result: FaceEmbeddingResult) -> Bool {
        if case .failure = result { return true }
        return false
    }

    // #0's outcome: its vector, box and match, plus its texture once computed.
    let first = embed(0)
    var firstVector: (vector: [Float], box: CGRect?, match: FaceMatch, texture: Double?)?
    if case let .embedding(vector, _, box, _) = first {
        let match = selection.evaluate(vector)
        var tex: Double?
        if match.accepted {
            let t = texture(0)
            if confirmed(box, t) {
                return .embedding(vector, textureScore: t, faceBox: box, selection: report(1, 0, match))
            }
            tex = t
        }
        firstVector = (vector, box, match, tex)
    }
    let firstAccepted = firstVector?.match.accepted == true

    var embedded = 1
    if selection.maxFaces >= 2, candidateCount >= 2 {
        embedded = 2
        if case let .embedding(vector, _, box, _) = embed(1) {
            let match = selection.evaluate(vector)
            if match.accepted {
                let t = texture(1)
                // #0 is an unconfirmed match: only a CONFIRMED #1 replaces it.
                // #0 FAILED: only a confirmed #1 may stand in; an unconfirmed #1 would
                // turn the glitch into a stranger / not-live reading, so hold (EC-10).
                if confirmed(box, t) || (!firstAccepted && !isFailure(first)) {
                    return .embedding(vector, textureScore: t, faceBox: box, selection: report(2, 1, match))
                }
                if isFailure(first) { return .failure }
            }
        } else if firstVector != nil, !firstAccepted {
            return .failure                                    // #1 glitched: hold, never stranger
        }
    }

    guard let f = firstVector else {
        // #0 had no vector: a failure stays a failure (EC-10), never "no face".
        if case .noFace = first, embedded == 1 { return .noFace }
        return .failure
    }
    return .embedding(f.vector, textureScore: f.texture ?? texture(0), faceBox: f.box,
                      selection: report(embedded, 0, f.match))
}
