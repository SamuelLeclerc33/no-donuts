import Foundation
import CoreGraphics

// Owner: cooper (with wiggum's security hat). ND-116 / EC-12: motion + blink liveness.
// Privacy: pure arithmetic on landmark coordinates held in memory for ~1 s. No image,
// no embedding, nothing persisted or transmitted. No Vision / AppKit here, so every
// function below is checkable in EngineCheck with synthetic point sets.
//
// WHY (verified on-device 2026-09-28): a phone-screen photo of the enrolled user
// matched at ~0.80 and sailed through the variance-of-Laplacian texture check (58–89
// vs floor 12). No per-frame texture floor separates a modern screen from skin. What a
// photo or a screen CANNOT do is (a) blink, or (b) deform non-rigidly: every image of a
// flat picture, however it is tilted or moved, is the same picture under a plane
// projective transform (a homography). A live 3D head that turns shows parallax (the
// nose tip moves against the face contour), and a live face that talks, smiles or
// moves its eyes changes shape. Both break the homography.
//
// The rule (user decision, ND-116): a matched face counts as the enrolled user only if
// there was LIVE evidence — a blink or non-rigid motion — within the last 60 s.
//
// ALL thresholds below are PROVISIONAL: chosen from synthetic geometry (see the
// constants' docs) with margin over an assumed landmark jitter. The analyzer logs the
// raw numbers (eye-openness ratios, motion residuals) so they can be tuned on device.
//
// Out of scope / known limits (see the ADR): a VIDEO replay of the user (it blinks and
// moves) defeats this, as does a printed photo bent/flexed while shown (paper is not
// rigid). A phone or tablet screen — the verified attack — is rigid and flat.

/// A 2-D landmark position in oriented image PIXELS (any consistent isotropic unit).
public typealias LandmarkXY = SIMD2<Double>

// MARK: - Liveness window policy

/// Default liveness window (ND-116, user decision): evidence must be at most this old.
public let defaultLivenessWindowSeconds: TimeInterval = 60

/// Pure liveness policy (ND-116). A matched face is LIVE when either:
/// - there was live evidence (blink / non-rigid motion) at most `window` seconds ago, or
/// - we are within `window` seconds of `windowStart` — the bootstrap after enforcement
///   (re)starts (launch, unlock/wake, end of pause / trusted Wi-Fi / enrollment), so a
///   user who just typed their password isn't locked before their first blink lands.
///   Since ND-118a `windowStart` is the first analyzed face after the restart
///   (`LivenessStartWindow`), not the restart itself.
///
/// `windowStart` is deliberately NOT reset by a face (re)appearing: if it were, an
/// attacker could hide and re-show a photo to reopen a fresh 60 s window forever.
/// Only an enforcement restart (which needs an unlock, or the user's own pause / Wi-Fi
/// change on an already-unlocked Mac) opens a bootstrap window.
///
/// Times are on one monotonic clock (host time). `nil` = never.
public func isLive(now: TimeInterval,
                   lastEvidence: TimeInterval?,
                   windowStart: TimeInterval?,
                   window: TimeInterval = defaultLivenessWindowSeconds) -> Bool {
    guard window.isFinite, window > 0 else { return false }
    if let e = lastEvidence, e.isFinite, now - e <= window { return true }
    if let s = windowStart, s.isFinite, now >= s, now - s <= window { return true }
    return false
}

// MARK: - Enforcement-start window (ND-118a)

/// When the enforcement-start ("bootstrap") window STARTS (ND-118a; pure value type,
/// EngineCheck-covered).
///
/// On-device near miss (2026-09-28): the window used to start at `beginWindow()` —
/// enforcement (re)start — so time before the analyzer had seen the user's face at all
/// (camera warm-up, the user not yet back at the desk after a pause / trusted Wi-Fi
/// ended) was spent from the 60 s budget, and it expired before any evidence landed
/// (5 + 3 `.notLive` ticks). Now the window starts at the FIRST ANALYZED FACE (first
/// landmark-bearing frame) after `begin(at:)`, and lasts `window` seconds from there.
///
/// Bounded, by construction:
/// - The start is set ONCE per `begin(at:)` and never moves: a face disappearing and
///   reappearing (hiding / re-showing a photo) cannot reopen or extend it. So a still
///   photo shown from enforcement start stops being live `window` s after its first
///   analyzed frame, then locks after consensus + grace (ADR-0022's bound).
/// - Before any face is analyzed the window runs from `begin(at:)` as before, so a
///   landmark pass that is blind to a face the recognizer matches can't hold the Mac
///   unlocked past `armedAt + 1.5 × window` either: a first face later than `maxFirstFaceDelay` after arming doesn't move the start (fail-closed).
/// - Frames stamped before `begin(at:)` (in flight across a restart) don't count.
///
/// Rejected: "≥ N s of face-present analysis time" — pausing the budget while no face
/// is seen lets an attacker stretch it by hiding the photo for just under the grace
/// period between ticks (each re-show resets the absence consensus): wall time grows
/// ~10× before any cap. Starting once at the first face gives the same fix for the
/// observed case without that lever.
public struct LivenessStartWindow: Sendable, Equatable {
    /// `begin(at:)` time (enforcement (re)start); `nil` = never begun.
    public private(set) var armedAt: TimeInterval?
    /// First analyzed face at or after `armedAt`; `nil` = none yet.
    public private(set) var firstFaceAt: TimeInterval?

    public init() {}

    /// Arm a fresh window (enforcement (re)start, anti-spoof toggled back on).
    public mutating func begin(at time: TimeInterval) {
        guard time.isFinite else { return }
        armedAt = time; firstFaceAt = nil
    }

    /// A landmark-bearing frame captured at `time`. Only the first one after `begin`
    /// counts; later faces (including after a gap) never move the start.
    public mutating func faceAnalyzed(at time: TimeInterval) {
        guard firstFaceAt == nil, let a = armedAt, time.isFinite, time >= a else { return }
        firstFaceAt = time
    }

    /// Latest point after arming at which a first face may still anchor the window.
    /// Review fix: an uncapped first face could push the start arbitrarily late (or
    /// re-open an already-expired window). Capping it at half the window after arming
    /// bounds the startup window to at most `armedAt + 1.5 × window` in wall time.
    public static let maxFirstFaceDelay: TimeInterval = defaultLivenessWindowSeconds / 2

    /// The `windowStart` to hand the policy (`isLive` / `FaceTracker.verdict`).
    public var start: TimeInterval? {
        guard let a = armedAt else { return nil }
        if let f = firstFaceAt, f - a <= Self.maxFirstFaceDelay { return f }
        return a
    }
}

/// Result of a liveness query, for the recognizer's decision + its log line.
public struct LivenessVerdict: Equatable, Sendable {
    /// True when the matched face may count as the enrolled user.
    public let live: Bool
    /// Seconds since the last live evidence; `nil` if none since launch.
    public let evidenceAge: TimeInterval?
    /// True when `live` holds only because of the post-(re)start bootstrap window.
    public let bootstrap: Bool
    /// ND-116 review: whether the matched face is the analyzer's CURRENT face track.
    /// `nil` = not evaluated (the plain `evaluate`). False → evidence can't count.
    public let trackBound: Bool?
    /// True when `live` holds only because of a track-handoff probation (`FaceTracker`).
    public let probation: Bool

    public init(live: Bool, evidenceAge: TimeInterval?, bootstrap: Bool,
                trackBound: Bool? = nil, probation: Bool = false) {
        self.live = live
        self.evidenceAge = evidenceAge
        self.bootstrap = bootstrap
        self.trackBound = trackBound
        self.probation = probation
    }

    /// Pure constructor from the policy inputs.
    public static func evaluate(now: TimeInterval, lastEvidence: TimeInterval?,
                                windowStart: TimeInterval?,
                                window: TimeInterval = defaultLivenessWindowSeconds) -> LivenessVerdict {
        let live = isLive(now: now, lastEvidence: lastEvidence, windowStart: windowStart, window: window)
        let byEvidence = isLive(now: now, lastEvidence: lastEvidence, windowStart: nil, window: window)
        return LivenessVerdict(live: live,
                               evidenceAge: lastEvidence.map { max(0, now - $0) },
                               bootstrap: live && !byEvidence)
    }

    /// Numeric-only summary for the identity log line, e.g. "yes (last evidence 3.2s ago)".
    public var logDescription: String {
        var age = evidenceAge.map { String(format: "last evidence %.1fs ago", $0) } ?? "no evidence yet"
        if trackBound == false { age += "; matched face is not the tracked face" }
        if bootstrap { return "yes (startup window; \(age))" }
        if probation { return "yes (track handoff probation; \(age))" }
        return "\(live ? "yes" : "no") (\(age))"
    }

}

// MARK: - Face track (binds evidence to one continuous face)

/// Intersection-over-union of two rects (0 for empty / degenerate / non-finite).
public func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
    guard [a.minX, a.minY, a.width, a.height, b.minX, b.minY, b.width, b.height].allSatisfy({ $0.isFinite }),
          a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
    let i = a.intersection(b)
    guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
    let inter = Double(i.width * i.height)
    let union = Double(a.width * a.height + b.width * b.height) - inter
    return union > 0 ? inter / union : 0
}

/// One continuous face track (ND-116; one per face since ND-059). Evidence (blinks / motion)
/// belongs to a TRACK, never to "whoever is in front of the camera".
public struct FaceTrack: Sendable, Equatable {
    /// Continuity: max time between two observations of the same track. 1.0 s (was
    /// 0.5 s; on-device Test A 2026-09-28 reset twice in 2 s on the real user) rides
    /// over a few missed detections (looking down at the keyboard, a hand at the face).
    public static let maxGap: TimeInterval = 1.0
    /// Continuity: min IoU with the previous box. 0.3 (was 0.4): Vision's box changes
    /// size with pose (frontal ↔ three-quarter) as well as moving. A side-by-side swap
    /// (photo next to the attacker's face) is IoU ≈ 0.
    public static let minIoU: Double = 0.3
    /// Continuity: max frame-to-frame inter-ocular change. Kept at 25%: it is what
    /// separates a same-box swap to a photo at another scale (EngineCheck attack: 70 →
    /// 50 px, −29%). A real-user reset it causes is absorbed by the handoff below.
    public static let maxIODChange: Double = 0.25
    /// Handoff: a new track that starts within this time of the previous track's last
    /// sighting AND overlaps its last box (IoU ≥ `handoffMinIoU`) may be handed a
    /// probation (see `FaceTracker`).
    public static let handoffGap: TimeInterval = 1.0
    public static let handoffMinIoU: Double = 0.2
    /// Probation length: a handed-off track counts as live for this long without its own
    /// evidence. 20 s: on-device the real user produced evidence every ~10 s (motion)
    /// and ~15 s (blinks); well under the 60 s evidence window, so it never extends the
    /// ADR-0022 bound.
    public static let probationSeconds: TimeInterval = 20
    /// ND-059 review: how decisively a face↔track assignment must win to count as
    /// "clear". The best assignment's total IoU must beat every conflicting assignment by
    /// at least this; otherwise the assignment is UNCERTAIN (see `FaceTracker`). The
    /// verdict applies the same margin to bind the matched box. 0.3 IoU (provisional): a
    /// real face keeps IoU ~0.85–0.95 with its own last box frame to frame, so a neighbour
    /// overlapping it at up to ~0.5 is still decisive; two faces nearly on top of each
    /// other (crossing) are not.
    public static let assignmentMargin: Double = 0.3
    /// ND-059 review: two detections this close (IoU ≥ 0.7), at the same scale (IOD within
    /// 10%), whose landmarks agree (the caller's `sameFace`), are ONE face detected twice.
    public static let duplicateMinIoU: Double = 0.7
    public static let duplicateMaxIODChange: Double = 0.1

    public fileprivate(set) var id: Int
    public fileprivate(set) var lastBox: CGRect
    public fileprivate(set) var lastIOD: Double
    public fileprivate(set) var lastSeen: TimeInterval
    public fileprivate(set) var startedAt: TimeInterval
    /// This track's OWN latest blink / motion event (never inherited).
    public fileprivate(set) var evidenceAt: TimeInterval?
    /// The recognizer MATCHED the enrolled user on this track at a tick. Never inherited.
    public fileprivate(set) var verified: Bool = false
    /// Handoff probation deadline (nil = none).
    public fileprivate(set) var probationUntil: TimeInterval?

    func isFresh(at now: TimeInterval) -> Bool {
        now.isFinite && abs(now - lastSeen) <= Self.maxGap
    }
    func overlaps(_ box: CGRect, minIoU: Double = FaceTrack.minIoU) -> Bool {
        intersectionOverUnion(lastBox, box) >= minIoU
    }
}

/// Why a new track started (numbers only, for the `.debug` log / tuning).
public struct TrackBreak: Sendable, Equatable {
    /// `ambiguous` (ND-059): which face continues which track was UNCERTAIN (no
    /// assignment won by `assignmentMargin`); those tracks were retired with NO handoff.
    public enum Reason: String, Sendable { case first, gap, overlap, scale, ambiguous }
    public enum Handoff: String, Sendable { case none, fresh, inherited }
    public let reason: Reason
    public let gap: TimeInterval?
    public let iou: Double?
    public let iodChange: Double?
    public let handoff: Handoff
}

/// Which track a face observed in a frame belongs to (ND-059).
public struct TrackAssignment: Sendable, Equatable {
    /// Index into the `faces` passed to `FaceTracker.observe(faces:time:)`.
    public let faceIndex: Int
    public let trackID: Int
    /// `nil` = the face continued an existing track; otherwise why a new one started
    /// (the caller must give that track fresh detectors).
    public let trackBreak: TrackBreak?
}

/// Face-track state machine (ND-116; pure value type, EngineCheck-covered).
///
/// **Why tracks** (security review): a phone photo shown at each 1 s recognition tick
/// while the attacker's own face blinks between ticks. Swapping photo ↔ face moves or
/// rescales the face box, which breaks the track; the matched (photo) box then belongs
/// to a track with no evidence → not live.
///
/// **Handoff** (on-device Test A: two spurious track breaks 2 s apart on the real user
/// → 9 `.notLive` ticks → false lock). A new track that starts within `handoffGap` of
/// the previous track's last sighting and overlaps its last box (IoU ≥ 0.2) gets a
/// probation — live for `probationSeconds` without evidence of its own:
/// - FRESH probation (now + 20 s) only from a predecessor that was VERIFIED (matched
///   as the enrolled user at a tick) AND live by its OWN evidence (≤ 60 s old);
/// - otherwise it INHERITS the predecessor's probation deadline unchanged (so rapid
///   repeated breaks are covered) — a deadline is never extended by inheritance.
///
/// Why this can't be farmed: `verified` and own evidence are never inherited, and no
/// single track has both unless it is the enrolled user's live face. A photo track can
/// be verified (it matches) but never has own evidence; the attacker's own face track
/// can have evidence but is never verified (it doesn't match). So in the alternation
/// loop no track can issue a fresh probation. The only case that gains anything is the
/// REAL user's live face replaced by a photo in the same place within 1 s: ≤ 20 s once
/// (then the photo track needs evidence of its own, which it can't produce).
///
/// Why not "don't count `.notLive` as absence for N s on a new track" (option (c)):
/// new tracks are free to create (hide the photo, show it again), so that grace would
/// hold the Mac unlocked indefinitely unless it were bound to a verified live
/// predecessor — which is exactly this handoff.
///
/// **Several tracks (ND-059).** With `maxTracks` 2 (the analyzer), the two largest faces
/// each get their own track, so the user's blinks count when they are the SECOND face
/// (a colleague leaning in closer). Per frame (`observe(faces:time:occupants:sameFace:)`):
/// 1. An out-of-order frame (older than any track's last sighting) is ignored.
/// 2. Faces are taken largest first (`faceIndicesByArea`). A face that duplicates a
///    bigger one (IoU ≥ `duplicateMinIoU`, IOD within `duplicateMaxIODChange`, the
///    caller's `sameFace` — landmark agreement — true, and at most ONE nearby track
///    overlapping the pair at ≥ `minIoU`) is dropped: Vision reported one face twice.
///    Box-only callers pass no `sameFace`, so nothing is merged (fail-safe). Then only
///    the `maxTracks` largest remaining faces are considered.
/// 3. **Ambiguity rule (uncertain assignment, not overlap).** Faces and nearby tracks
///    with IoU ≥ `handoffMinIoU` are "linked". In each linked group where some face or
///    track has two links, the best one-to-one assignment (highest total IoU) must beat
///    every CONFLICTING assignment (one using a link it doesn't) by `assignmentMargin`.
///    If it does, that assignment stands: two faces steadily overlapping each keep
///    their own track. If not (faces crossing, nearly on top of each other), the group's
///    tracks are retired with NO handoff and its faces start `.ambiguous` tracks, so
///    evidence can't move from a live stranger onto a photo of the user as they cross.
///    KNOWN LIMIT: equal-size faces that swap places between two analyzed frames (or
///    while hidden for < 1 s) produce the SAME boxes as two faces standing still, so no
///    box rule can tell them apart. That is the ADR-0022 "same spot within 1 s" hole,
///    already open for faces side by side (IoU 0); see ADR-0023.
/// 4. Continuity (fresh track, IoU ≥ `minIoU`, IOD change ≤ `maxIODChange`) applies to
///    those assigned pairs. An assigned pair that fails it REPLACES its track under the
///    handoff rules above.
/// 5. Any other face takes a free slot as an independent track (reason `.first`, or
///    `.gap` when it replaces a stale track; no handoff, since there is no overlap), or
///    else replaces the least recently seen track that wasn't continued.
/// 6. Stale tracks (not seen for > `maxGap`) that nothing replaced are dropped, and the
///    least recently seen tracks not seen this frame are evicted until at most
///    `maxTracks` remain (invariant after every frame).
///
/// `occupants`: faces in the same top-`maxTracks` ranking that had NO usable landmarks
/// (so no track, no evidence). They are remembered for the verdict only: a matched box
/// closer to an occupant than decisively to a track is unbound (fail-safe, ND-059 review).
///
/// With `maxTracks` 1 (the default) this reduces exactly to the single-track rules: the
/// one face always continues or replaces the one track.
public struct FaceTracker: Sendable, Equatable {
    /// Live tracks, at most `maxTracks`.
    public private(set) var tracks: [FaceTrack] = []
    /// Compatibility: the most recently seen track (the only one when `maxTracks` is 1).
    public var current: FaceTrack? { tracks.max(by: { $0.lastSeen < $1.lastSeen }) }
    public private(set) var tracksStarted = 0
    public private(set) var freshHandoffs = 0
    public private(set) var inheritedHandoffs = 0
    /// Tracks started by the ambiguity rule (ND-059).
    public private(set) var ambiguousBreaks = 0
    /// Duplicate detections merged into a bigger one (ND-059 review).
    public private(set) var duplicatesMerged = 0
    /// Most tracks alive at once since creation (ND-059 diagnostics).
    public private(set) var maxConcurrentTracks = 0
    /// Detected faces without usable landmarks in the latest frame, and that frame's time.
    public private(set) var occupants: [CGRect] = []
    public private(set) var occupantsSeenAt: TimeInterval?
    /// The track the last BOUND verdict used (diagnostics: its evidence, not the max over
    /// every track, which a stranger's blink would make look fresh).
    public private(set) var lastBoundTrackID: Int?
    public var window: TimeInterval
    /// Faces tracked at once, clamped to `1...maxCandidateFaces`.
    public let maxTracks: Int
    private var nextID = 1

    public init(window: TimeInterval = defaultLivenessWindowSeconds, maxTracks: Int = 1) {
        self.window = window
        self.maxTracks = clampedCandidateFaces(maxTracks)
    }

    /// Own evidence time of the track the recognizer last matched (nil = none / gone).
    public var matchedTrackEvidenceAt: TimeInterval? {
        guard let id = lastBoundTrackID else { return nil }
        return tracks.first { $0.id == id }?.evidenceAt
    }

    /// Observe a single face (Vision-normalized box, inter-ocular distance in pixels).
    /// Returns `nil` if it continues the current track, else the `TrackBreak` that
    /// started a new one (the caller must then reset its detectors). Invalid input
    /// (non-finite, empty box) ends every track and returns `nil`.
    @discardableResult
    public mutating func observe(box: CGRect, interOcular: Double, time: TimeInterval) -> TrackBreak? {
        guard time.isFinite, interOcular.isFinite, interOcular > 0,
              intersectionOverUnion(box, box) > 0 else { tracks = []; return nil }
        return observe(faces: [(box, interOcular)], time: time).first?.trackBreak
    }

    /// Observe every face analyzed in one frame (ND-059; see the type doc for the rules).
    /// Returns one assignment per TRACKED face (at most `maxTracks`, by input index).
    /// Invalid faces (non-finite, empty box, non-positive IOD) are skipped.
    /// - `occupants`: ranked faces with no usable landmarks (verdict only).
    /// - `sameFace(i, j)`: whether faces `i` and `j` have agreeing landmarks (duplicate
    ///   detection). Default: never (box-only callers merge nothing).
    @discardableResult
    public mutating func observe(faces input: [(box: CGRect, interOcular: Double)],
                                 time: TimeInterval,
                                 occupants: [CGRect] = [],
                                 sameFace: (Int, Int) -> Bool = { _, _ in false }) -> [TrackAssignment] {
        guard time.isFinite else { return [] }
        if tracks.contains(where: { time < $0.lastSeen }) { return [] }       // out of order: ignore
        if occupantsSeenAt.map({ time >= $0 }) ?? true {
            self.occupants = occupants.filter { intersectionOverUnion($0, $0) > 0 }
            occupantsSeenAt = time
        }

        func iou(_ f: Int, _ t: Int) -> Double { intersectionOverUnion(input[f].box, tracks[t].lastBox) }
        let nearbyWindow = max(FaceTrack.maxGap, FaceTrack.handoffGap)
        let nearby = tracks.indices.filter { time - tracks[$0].lastSeen <= nearbyWindow }

        // 2. Largest first; drop duplicate detections of one face; keep the top maxTracks.
        let valid = input.indices.filter {
            input[$0].interOcular.isFinite && input[$0].interOcular > 0
                && intersectionOverUnion(input[$0].box, input[$0].box) > 0
        }
        func isDuplicate(_ k: Int, of f: Int) -> Bool {
            guard intersectionOverUnion(input[k].box, input[f].box) >= FaceTrack.duplicateMinIoU,
                  abs(input[k].interOcular - input[f].interOcular) / input[f].interOcular
                      <= FaceTrack.duplicateMaxIODChange,
                  sameFace(f, k) else { return false }
            // Two different nearby tracks near the pair = two faces meeting, not a duplicate.
            let near = nearby.filter { iou(f, $0) >= FaceTrack.minIoU || iou(k, $0) >= FaceTrack.minIoU }
            return near.count <= 1
        }
        var faces: [Int] = []
        for f in faceIndicesByArea(valid.map { input[$0].box }).map({ valid[$0] }) {
            if faces.contains(where: { isDuplicate(f, of: $0) }) { duplicatesMerged += 1; continue }
            if faces.count < maxTracks { faces.append(f) }
        }
        guard !faces.isEmpty else { return [] }

        // 3. Ambiguity rule: an assignment must be decisive, per linked group.
        let links = faces.flatMap { f in
            nearby.filter { iou(f, $0) >= FaceTrack.handoffMinIoU }.map { (face: f, track: $0) }
        }
        var retired = Set<Int>(), ambiguousFaces = Set<Int>()
        var assigned: [(face: Int, track: Int)] = []
        for group in linkGroups(links) {
            let conflict = Set(group.map(\.face)).count < group.count || Set(group.map(\.track)).count < group.count
            let matchings = oneToOneMatchings(group)
            func score(_ m: [(face: Int, track: Int)]) -> Double { m.reduce(0) { $0 + iou($1.face, $1.track) } }
            // Best: highest total IoU, then most pairs, then first found (deterministic).
            var best = matchings[0]
            for m in matchings.dropFirst() where score(m) > score(best) + 1e-12
                || (abs(score(m) - score(best)) <= 1e-12 && m.count > best.count) { best = m }
            let inBest = { (l: (face: Int, track: Int)) in best.contains { $0 == l } }
            let rival = matchings.filter { $0.contains { !inBest($0) } }.map(score).max()
            if conflict, let r = rival, score(best) - r < FaceTrack.assignmentMargin {
                retired.formUnion(group.map(\.track)); ambiguousFaces.formUnion(group.map(\.face))
            } else {
                assigned += best
            }
        }

        // 4. Continuity on the assigned pairs; a pair that fails it replaces its track.
        func continuous(_ f: Int, _ t: Int) -> Bool {
            let tr = tracks[t]
            return time - tr.lastSeen <= FaceTrack.maxGap && iou(f, t) >= FaceTrack.minIoU
                && abs(input[f].interOcular - tr.lastIOD) / tr.lastIOD <= FaceTrack.maxIODChange
        }
        var out: [TrackAssignment] = []
        var kept: [FaceTrack] = []                                         // continued + new
        for (f, t) in assigned {
            if continuous(f, t) {
                var tr = tracks[t]
                tr.lastBox = input[f].box; tr.lastIOD = input[f].interOcular; tr.lastSeen = time
                kept.append(tr)
                out.append(TrackAssignment(faceIndex: f, trackID: tr.id, trackBreak: nil))
            } else {
                let (tr, brk) = replacement(for: input[f], predecessor: tracks[t], time: time)
                kept.append(tr)
                out.append(TrackAssignment(faceIndex: f, trackID: tr.id, trackBreak: brk))
            }
        }
        for f in faces where ambiguousFaces.contains(f) {
            let tr = newTrack(input[f], time: time, probation: nil)
            kept.append(tr)
            ambiguousBreaks += 1
            out.append(TrackAssignment(faceIndex: f, trackID: tr.id, trackBreak:
                TrackBreak(reason: .ambiguous, gap: nil, iou: nil, iodChange: nil, handoff: .none)))
        }

        // 5. Remaining faces: take a free slot, or replace the least recently seen track
        // that wasn't used (never an overlapping one: every free link was assigned above).
        let usedTracks = Set(assigned.map(\.track)).union(retired)
        var pool = tracks.indices.filter { !usedTracks.contains($0) }
        func isStale(_ t: Int) -> Bool { time - tracks[t].lastSeen > FaceTrack.maxGap }
        let handled = Set(assigned.map(\.face)).union(ambiguousFaces)
        for f in faces where !handled.contains(f) {
            var predecessor: Int?
            if kept.count + pool.filter({ !isStale($0) }).count < maxTracks {
                predecessor = pool.filter(isStale).min(by: { tracks[$0].lastSeen < tracks[$1].lastSeen })
            } else if let lru = pool.min(by: { tracks[$0].lastSeen < tracks[$1].lastSeen }) {
                predecessor = lru
            } else {
                continue                                                   // no slot: not tracked
            }
            let (tr, brk) = replacement(for: input[f], predecessor: predecessor.map { tracks[$0] }, time: time)
            if let p = predecessor { pool.removeAll { $0 == p } }
            kept.append(tr)
            out.append(TrackAssignment(faceIndex: f, trackID: tr.id, trackBreak: brk))
        }

        // 6. Keep fresh tracks nothing replaced; drop stale ones; evict the least recently
        // seen of them until at most maxTracks remain (review fix: ambiguity-created tracks
        // used to bypass the slot pool, leaving 3).
        let room = max(0, maxTracks - kept.count)
        let survivors = pool.filter { !isStale($0) }.map { tracks[$0] }
            .sorted { $0.lastSeen > $1.lastSeen }.prefix(room)
        tracks = Array(survivors) + kept
        maxConcurrentTracks = max(maxConcurrentTracks, tracks.count)
        return out.sorted { $0.faceIndex < $1.faceIndex }
    }

    /// Connected groups of links (faces and tracks joined by a shared link).
    private func linkGroups(_ links: [(face: Int, track: Int)]) -> [[(face: Int, track: Int)]] {
        var groups: [[(face: Int, track: Int)]] = []
        for l in links {
            let joined = groups.indices.filter { g in groups[g].contains { $0.face == l.face || $0.track == l.track } }
            var merged = [l]
            for g in joined.reversed() { merged = groups.remove(at: g) + merged }
            groups.append(merged)
        }
        return groups
    }

    /// Every one-to-one subset of `links` (including the empty one). Links are few (at
    /// most `maxTracks` faces × `maxTracks` tracks = 4), so enumeration is cheap.
    private func oneToOneMatchings(_ links: [(face: Int, track: Int)]) -> [[(face: Int, track: Int)]] {
        var result: [[(face: Int, track: Int)]] = [[]]
        for l in links {
            result += result.filter { m in !m.contains { $0.face == l.face || $0.track == l.track } }.map { $0 + [l] }
        }
        return result
    }

    private mutating func newTrack(_ face: (box: CGRect, interOcular: Double), time: TimeInterval,
                                   probation: TimeInterval?) -> FaceTrack {
        let t = FaceTrack(id: nextID, lastBox: face.box, lastIOD: face.interOcular, lastSeen: time,
                          startedAt: time, evidenceAt: nil, verified: false, probationUntil: probation)
        nextID &+= 1
        tracksStarted += 1
        return t
    }

    /// A new track for `face`, replacing `predecessor` (if any) under the ADR-0022
    /// handoff rules.
    private mutating func replacement(for face: (box: CGRect, interOcular: Double), predecessor: FaceTrack?,
                                      time: TimeInterval) -> (FaceTrack, TrackBreak) {
        var reason = TrackBreak.Reason.first
        var gap: TimeInterval?, iou: Double?, iodChange: Double?
        var handoff = TrackBreak.Handoff.none
        var probation: TimeInterval?
        if let p = predecessor {
            let dt = time - p.lastSeen
            let o = intersectionOverUnion(face.box, p.lastBox)
            let dIOD = abs(face.interOcular - p.lastIOD) / p.lastIOD
            gap = dt; iou = o; iodChange = dIOD
            if dt > FaceTrack.maxGap { reason = .gap }
            else if o < FaceTrack.minIoU { reason = .overlap }
            else if dIOD > FaceTrack.maxIODChange { reason = .scale }
            else { reason = .overlap }                                     // continuity lost to another face
            if dt <= FaceTrack.handoffGap, p.overlaps(face.box, minIoU: FaceTrack.handoffMinIoU) {
                if p.verified, isLive(now: time, lastEvidence: p.evidenceAt, windowStart: nil, window: window) {
                    probation = time + FaceTrack.probationSeconds
                    handoff = .fresh; freshHandoffs += 1
                } else if let d = p.probationUntil, time <= d {
                    probation = d
                    handoff = .inherited; inheritedHandoffs += 1
                }
            }
        }
        let t = newTrack(face, time: time, probation: probation)
        return (t, TrackBreak(reason: reason, gap: gap, iou: iou, iodChange: iodChange, handoff: handoff))
    }

    /// Record live evidence on the most recently seen track (ignored if there is none).
    /// Single-track callers only; with several tracks use `recordEvidence(trackID:at:)`.
    public mutating func recordEvidence(at time: TimeInterval) {
        guard let id = current?.id else { return }
        recordEvidence(trackID: id, at: time)
    }

    /// Record live evidence on track `trackID` (ignored if it is gone).
    public mutating func recordEvidence(trackID: Int, at time: TimeInterval) {
        guard time.isFinite, let i = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[i].evidenceAt = max(tracks[i].evidenceAt ?? time, time)
    }

    /// Drop every track (enforcement restart). No handoff survives it.
    public mutating func end() { tracks = []; occupants = []; occupantsSeenAt = nil; lastBoundTrackID = nil }

    /// Track-bound verdict for a face the recognizer MATCHED at `matchedBox`. Also marks
    /// that track `verified` (the only way a track becomes verified).
    ///
    /// Binding (ND-059 review): the candidates are the fresh tracks (seen ≤ `maxGap` ago)
    /// AND the fresh occupants (detected faces with no usable landmarks) overlapping
    /// `matchedBox` at IoU ≥ `minIoU`. The matched face binds to the best candidate only
    /// if it is a TRACK and beats the runner-up by `assignmentMargin`. So evidence can
    /// only come from the track built from the matched face itself: two faces nearly on
    /// top of each other → unbound, and a matched face that is closest to an untracked
    /// face (e.g. a photo whose landmarks failed, partly over a live attacker) → unbound,
    /// never the neighbour's track. No box → not bound.
    ///
    /// Live when bound and that track has its own evidence ≤ `window` old or an unexpired
    /// probation; or when inside the enforcement-start window.
    ///
    /// The enforcement-start window is deliberately NOT track-bound: it covers the
    /// moments before the analyzer has any track (camera just started, first landmark
    /// pass cold) and only opens after an OS unlock or the user's own pause / Wi-Fi /
    /// enrollment action on an unlocked Mac. Binding it adds false locks, no security.
    public mutating func verdict(now: TimeInterval, matchedBox: CGRect?,
                                 windowStart: TimeInterval?) -> LivenessVerdict {
        var boundIndex: Int?
        if let m = matchedBox {
            var candidates: [(iou: Double, track: Int?)] = tracks.indices
                .filter { tracks[$0].isFresh(at: now) }
                .map { (intersectionOverUnion(tracks[$0].lastBox, m), $0) }
            if let seen = occupantsSeenAt, now.isFinite, abs(now - seen) <= FaceTrack.maxGap {
                candidates += occupants.map { (intersectionOverUnion($0, m), nil) }
            }
            let ranked = candidates.filter { $0.iou >= FaceTrack.minIoU }.sorted { $0.iou > $1.iou }
            if let top = ranked.first, let t = top.track,
               ranked.count == 1 || top.iou - ranked[1].iou >= FaceTrack.assignmentMargin {
                boundIndex = t
            }
        }
        if let i = boundIndex { tracks[i].verified = true; lastBoundTrackID = tracks[i].id }
        let bound = boundIndex != nil
        let track = boundIndex.map { tracks[$0] }
        let evidence = track?.evidenceAt
        let byEvidence = isLive(now: now, lastEvidence: evidence, windowStart: nil, window: window)
        let byProbation = track?.probationUntil.map { now <= $0 } ?? false
        let byWindow = isLive(now: now, lastEvidence: nil, windowStart: windowStart, window: window)
        return LivenessVerdict(live: byEvidence || byProbation || byWindow,
                               evidenceAge: evidence.map { max(0, now - $0) },
                               bootstrap: byWindow && !byEvidence && !byProbation,
                               trackBound: bound,
                               probation: byProbation && !byEvidence)
    }
}

/// Something that can say whether the face in front of the camera is live (ND-116).
/// The production implementation is `LivenessAnalyzer`; EngineCheck injects fakes.
public protocol LivenessProviding: AnyObject, Sendable {
    /// `matchedFaceBox`: the Vision-normalized (oriented, bottom-left) box of the face
    /// the recognizer MATCHED this tick; evidence counts only if it is the tracked face.
    func currentVerdict(matchedFaceBox: CGRect?) -> LivenessVerdict
}

// MARK: - Eye openness (blink signal)

/// Eye openness of one eye contour, normalized by a face-vertical scale (ND-116).
///
/// Order-independent (Vision's eye contour ordering is not part of its API): the eye's
/// axis is the pair of contour points farthest apart (the corners); its height is the
/// extent of the contour perpendicular to that axis.
///
/// Normalization — why NOT the classic EAR (height / width): tilting a photo backwards
/// foreshortens its vertical axis, so height / width drops exactly like a blink, and a
/// quick flick of a phone would fake one. Dividing by `faceVerticalScale` (eye line to
/// mouth, see `faceVerticalScale`) cancels that: both lengths foreshorten together
/// under pitch, neither changes under yaw, and both scale with distance/zoom. What stays
/// is the eyelid actually closing.
///
/// Returns `nil` for fewer than 4 points or a degenerate scale / eye.
public func eyeOpenness(eye points: [LandmarkXY], faceVerticalScale scale: Double) -> Double? {
    guard points.count >= 4, scale.isFinite, scale > 0 else { return nil }
    var a = points[0], b = points[1], best = -1.0
    for i in 0..<points.count {
        for j in (i + 1)..<points.count {
            let d = simd_length_sq_(points[i] - points[j])
            if d > best { best = d; a = points[i]; b = points[j] }
        }
    }
    guard best > 0, best.isFinite else { return nil }
    let axis = (b - a) / best.squareRoot()
    let normal = LandmarkXY(-axis.y, axis.x)
    var lo = Double.infinity, hi = -Double.infinity
    for p in points {
        let d = ((p - a) * normal).sum()
        lo = min(lo, d); hi = max(hi, d)
    }
    let height = hi - lo
    guard height.isFinite, height >= 0 else { return nil }
    return height / scale
}

/// Face-vertical scale for `eyeOpenness`: distance from the midpoint of the two eye
/// centroids to the lips centroid. `nil` if any set is empty or the distance is zero.
public func faceVerticalScale(leftEye: [LandmarkXY], rightEye: [LandmarkXY],
                              lips: [LandmarkXY]) -> Double? {
    guard let l = centroid(leftEye), let r = centroid(rightEye), let m = centroid(lips) else { return nil }
    let d = simd_length_(m - (l + r) / 2)
    return d.isFinite && d > 0 ? d : nil
}

/// Distance between the two eye centroids (the motion residual's normalizer).
public func interOcularDistance(leftEye: [LandmarkXY], rightEye: [LandmarkXY]) -> Double? {
    guard let l = centroid(leftEye), let r = centroid(rightEye) else { return nil }
    let d = simd_length_(l - r)
    return d.isFinite && d > 0 ? d : nil
}

/// Duplicate-detection landmark test (ND-059 review): both eye centroids of two
/// detections lie within `tolerance` × `interOcular` of each other. Vision reporting ONE
/// face twice gives near-identical landmarks; two different faces (a photo and a live
/// head) would need their eyes on the same pixels, which means one occludes the other.
public func eyeCentersAgree(_ a: (left: LandmarkXY, right: LandmarkXY),
                            _ b: (left: LandmarkXY, right: LandmarkXY),
                            interOcular: Double, tolerance: Double = 0.1) -> Bool {
    guard interOcular.isFinite, interOcular > 0, tolerance.isFinite, tolerance >= 0 else { return false }
    let limit = tolerance * interOcular
    let dl = simd_length_(a.left - b.left), dr = simd_length_(a.right - b.right)
    return dl.isFinite && dr.isFinite && dl <= limit && dr <= limit
}

func centroid(_ points: [LandmarkXY]) -> LandmarkXY? {
    guard !points.isEmpty else { return nil }
    let s = points.reduce(LandmarkXY(0, 0), +)
    let c = s / Double(points.count)
    return c.x.isFinite && c.y.isFinite ? c : nil
}

@inline(__always) func simd_length_sq_(_ v: LandmarkXY) -> Double { (v * v).sum() }
@inline(__always) func simd_length_(_ v: LandmarkXY) -> Double { simd_length_sq_(v).squareRoot() }

// MARK: - Blink detector

/// A detected blink (numbers only, for logging / tuning).
public struct BlinkEvent: Equatable, Sendable {
    /// First-closed-sample → first-reopened-sample time (seconds).
    public let closedDuration: TimeInterval
    /// The deepest closure seen: max over the two eyes of (openness / baseline).
    public let minRatio: Double
}

/// Blink detector over a timestamped per-eye openness sequence (ND-116). Pure value
/// type: `ingest` one sample per analyzed frame (~7 fps).
///
/// A blink = BOTH eyes drop below `closedFraction` × their own rolling open-eye
/// baseline, then BOTH recover to at least `reopenFraction` × baseline, with the
/// closed phase lasting at most `maxClosedDuration`. Longer closures (eyes shut, looking
/// down at the keyboard) are not blinks: once a dip outlasts `maxClosedDuration` it is
/// abandoned and its samples feed the baseline, which re-converges to the new level
/// within ~`baselineWindow / 2` samples (~1.5 s at 7 fps). A gap in samples longer than `maxSampleGap`
/// (face lost, frames dropped) abandons any dip in progress.
///
/// Baseline: the per-eye MEDIAN of the last `baselineWindow` samples taken while not in a
/// dip — robust to the blinks themselves. No blink can be reported before
/// `minBaselineSamples` samples exist (~1 s at 7 fps).
///
/// Provisional constants (tune on device from the `.debug` log):
/// - `closedFraction` 0.6: a real blink takes the lid to ~0–30% of open; Vision's eye
///   contour is smoothed and may not close fully, so 0.6 leaves room. Jitter on a still
///   photo moves openness by a few percent, far from a 40% drop.
/// - `reopenFraction` 0.8: hysteresis, so jitter at the threshold can't chatter.
/// - `maxClosedDuration` 0.5 s: blinks close for ~100–400 ms. At ~7 fps the measured
///   duration is quantized to ~143 ms steps, so a 400 ms blink can measure ~430 ms.
public struct BlinkDetector: Sendable {
    public var closedFraction: Double = 0.6
    public var reopenFraction: Double = 0.8
    public var maxClosedDuration: TimeInterval = 0.5
    public var maxSampleGap: TimeInterval = 0.5
    public var baselineWindow: Int = 21
    public var minBaselineSamples: Int = 7
    /// A gap this long also drops the baseline (it may be another person / lighting).
    public var baselineResetGap: TimeInterval = 5

    private var history: [(left: Double, right: Double)] = []
    private var dipStart: TimeInterval?
    private var dipMin: Double = 1
    private var adapting = false
    private var lastTime: TimeInterval?

    public init() {}

    /// Last baseline ratios' deepest dip in progress — diagnostics only.
    public var inDip: Bool { dipStart != nil }

    public mutating func reset() {
        history.removeAll(); dipStart = nil; dipMin = 1; adapting = false; lastTime = nil
    }

    /// Feed one sample. Returns a `BlinkEvent` on the sample that completes a blink.
    /// Non-finite / non-positive openness values are ignored (not a sample).
    public mutating func ingest(time: TimeInterval, left: Double, right: Double) -> BlinkEvent? {
        guard time.isFinite, left.isFinite, right.isFinite, left >= 0, right >= 0 else { return nil }
        if let last = lastTime {
            let gap = time - last
            if gap < 0 { return nil }                        // out of order: ignore
            if gap > baselineResetGap { history.removeAll(); adapting = false }
            if gap > maxSampleGap { dipStart = nil; dipMin = 1 }
        }
        lastTime = time

        guard history.count >= minBaselineSamples,
              let baseL = median(history.map(\.left)), let baseR = median(history.map(\.right)),
              baseL > 0, baseR > 0 else {
            appendHistory(left, right)
            return nil
        }
        let rl = left / baseL, rr = right / baseR

        if let start = dipStart {
            dipMin = min(dipMin, max(rl, rr))
            if min(rl, rr) >= reopenFraction {
                let duration = time - start
                let depth = dipMin
                dipStart = nil; dipMin = 1
                appendHistory(left, right)
                return duration <= maxClosedDuration
                    ? BlinkEvent(closedDuration: duration, minRatio: depth) : nil
            }
            // ND-116 review fix: a "dip" longer than any blink is not a blink — it is a
            // new openness level (looking down, squinting, glasses glare, lighting).
            // Abandon it and feed these samples to the baseline again, so the baseline
            // adapts and later blinks at the new level are detected. (Before, the
            // detector stayed stuck mid-dip forever and never saw another blink.)
            if time - start > maxClosedDuration {
                dipStart = nil; dipMin = 1
                adapting = true
                appendHistory(left, right)
            }
            return nil                                       // still closed / half-open
        }
        if adapting {
            // Re-baselining after an abandoned dip: every sample feeds the baseline and no
            // new dip starts until the eyes read "open" against it again (the median
            // caught up with the new level, or the eyes reopened).
            appendHistory(left, right)
            if min(rl, rr) >= reopenFraction { adapting = false }
            return nil
        }
        if max(rl, rr) < closedFraction {
            dipStart = time
            dipMin = max(rl, rr)
            return nil
        }
        appendHistory(left, right)
        return nil
    }

    private mutating func appendHistory(_ l: Double, _ r: Double) {
        history.append((l, r))
        if history.count > baselineWindow { history.removeFirst(history.count - baselineWindow) }
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

// MARK: - Planar (homography) residual — the non-rigid motion signal

/// Least-squares homography fit `src → dst` (DLT, h33 = 1, 8 dof, Hartley-normalized),
/// returning the RMS transfer error in `dst` units. `nil` for mismatched / fewer than
/// 6 correspondences or a singular fit.
///
/// Every view of a FLAT picture (phone screen, print) is related to every other view by
/// a homography, so its landmarks refit with ~zero residual (plus detector jitter)
/// however the picture is moved, tilted or rotated. A live face that turns (parallax) or
/// changes expression leaves a residual. This is the signal `NonRigidMotionDetector`
/// thresholds.
public func homographyResidualRMS(from src: [LandmarkXY], to dst: [LandmarkXY]) -> Double? {
    let n = src.count
    guard n >= 6, dst.count == n else { return nil }
    guard let (ns, _) = hartleyNormalize(src), let (nd, td) = hartleyNormalize(dst) else { return nil }

    // Normal equations AᵀA h = Aᵀb, two rows per correspondence (h33 = 1):
    //   [x y 1 0 0 0 -x·u -y·u] h = u
    //   [0 0 0 x y 1 -x·v -y·v] h = v
    var ata = [Double](repeating: 0, count: 64)
    var atb = [Double](repeating: 0, count: 8)
    for i in 0..<n {
        let x = ns[i].x, y = ns[i].y, u = nd[i].x, v = nd[i].y
        let r1: [Double] = [x, y, 1, 0, 0, 0, -x * u, -y * u]
        let r2: [Double] = [0, 0, 0, x, y, 1, -x * v, -y * v]
        for a in 0..<8 {
            atb[a] += r1[a] * u + r2[a] * v
            for b in 0..<8 { ata[a * 8 + b] += r1[a] * r1[b] + r2[a] * r2[b] }
        }
    }
    guard let h = solveLinear8(ata, atb) else { return nil }

    // Transfer error measured back in ORIGINAL dst units: map normalized src through H,
    // then undo dst's normalization (td = (scale, centroid)).
    var sse = 0.0
    for i in 0..<n {
        let x = ns[i].x, y = ns[i].y
        let w = h[6] * x + h[7] * y + 1
        guard abs(w) > 1e-12 else { return nil }
        let pu = (h[0] * x + h[1] * y + h[2]) / w
        let pv = (h[3] * x + h[4] * y + h[5]) / w
        let px = pu / td.scale + td.center.x
        let py = pv / td.scale + td.center.y
        let dx = px - dst[i].x, dy = py - dst[i].y
        sse += dx * dx + dy * dy
    }
    let rms = (sse / Double(n)).squareRoot()
    return rms.isFinite ? rms : nil
}

/// Translate to the centroid and scale so the mean distance from it is √2.
private func hartleyNormalize(_ pts: [LandmarkXY]) -> ([LandmarkXY], (scale: Double, center: LandmarkXY))? {
    guard let c = centroid(pts) else { return nil }
    let meanDist = pts.reduce(0.0) { $0 + simd_length_($1 - c) } / Double(pts.count)
    guard meanDist.isFinite, meanDist > 1e-12 else { return nil }
    let s = 2.0.squareRoot() / meanDist
    return (pts.map { ($0 - c) * s }, (s, c))
}

/// Gaussian elimination with partial pivoting on an 8×8 system. `nil` if singular.
private func solveLinear8(_ aIn: [Double], _ bIn: [Double]) -> [Double]? {
    var a = aIn, b = bIn
    let n = 8
    for col in 0..<n {
        var piv = col
        var best = abs(a[col * n + col])
        for r in (col + 1)..<n where abs(a[r * n + col]) > best { best = abs(a[r * n + col]); piv = r }
        guard best > 1e-12, best.isFinite else { return nil }
        if piv != col {
            for k in 0..<n { a.swapAt(col * n + k, piv * n + k) }
            b.swapAt(col, piv)
        }
        let d = a[col * n + col]
        for r in (col + 1)..<n {
            let f = a[r * n + col] / d
            if f == 0 { continue }
            for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
            b[r] -= f * b[col]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = b[r]
        for k in (r + 1)..<n { s -= a[r * n + k] * x[k] }
        x[r] = s / a[r * n + r]
        guard x[r].isFinite else { return nil }
    }
    return x
}

// MARK: - Non-rigid motion detector

/// Output of one motion evaluation (numbers only, for logs).
public struct MotionEvaluation: Equatable, Sendable {
    /// Homography residual RMS / inter-ocular distance for this frame vs its reference.
    public let score: Double
    /// Seconds back to the OLDEST reference frame compared.
    public let lag: TimeInterval
    /// The jitter floor the score was compared with (median consecutive-frame score).
    public let noiseFloor: Double
    /// The score this evaluation had to beat: max(absoluteThreshold, noiseRatio × floor).
    public let requiredScore: Double
    /// True on the evaluation that registers a non-rigid-motion EVENT.
    public let event: Bool
}

/// Non-rigid / non-planar facial motion detector (ND-116). Pure value type: `ingest`
/// the full landmark constellation (fixed point order, oriented pixels) + inter-ocular
/// distance for each analyzed frame (~7 fps).
///
/// Score: each frame is compared with up to three retained frames whose ages are closest
/// to `referenceLags` (all within `minLag...maxLag`, ~0.5–1 s: long enough for a head
/// turn or a word to show), and the score is the MEDIAN of those homography residual
/// RMS values / current inter-ocular distance. The median matters: Vision landmarks have
/// heavy-tailed, single-frame glitches (measured: isolated 2–5× spikes on a static flat
/// picture), and one glitched REFERENCE frame must not look like motion.
///
/// Self-calibrating jitter floor: landmark jitter ALONE also leaves a residual, and its
/// size depends on light, face size and camera (synthetic: 1 px of per-point jitter at
/// IOD 70 px already scores ≈ 0.028 — the same as a 10° head turn). So a fixed threshold
/// can't be both safe and sensitive. The detector also scores each frame against the
/// PREVIOUS frame (≤ `maxShortLag`, ~1/7 s: little real motion, the same jitter) and
/// keeps the median of the last `noiseWindow` of those as the jitter floor. For a flat
/// picture the long-lag score is jitter too, so it hovers AT the floor (ratio ≈ 1); for
/// a live face that turns or talks it grows with the lag. A frame counts as "moving"
/// when score > max(`absoluteThreshold`, `noiseRatio` × floor).
///
/// An EVENT needs `requiredConsecutive` consecutive moving evaluations (~0.4 s of
/// sustained deformation at 7 fps: a glitched CURRENT frame can't fire it), then a
/// `refractory` gap before the next (so counts mean something). No event before
/// `minNoiseSamples` floor samples exist.
///
/// PROVISIONAL constants. Calibrated on (a) synthetic 3-D-head geometry (EngineCheck)
/// and (b) real Vision landmarks on a rendered, moving + perspective-tilting FLAT face
/// picture (developer run 2026-09-28): with ratio 2.0 × 2-in-a-row the flat picture
/// fired 1–6 false events per 20 s (adjacent glitches); ratio 2.5 × 3-in-a-row plus
/// the reference median fired none. Tune on device from the `.debug` "motion" lines —
/// the phone-photo spoof must stay below `requiredScore`:
/// - `noiseRatio` 2.5: a flat picture's long-lag score sits at ~1–1.5× its own floor
///   (glitches aside); a live 10–20° head turn at ≤ 0.7 px jitter reaches ~3×.
/// - `absoluteThreshold` 0.015 IOD (≈ 1 px at IOD 70): with very clean landmarks the
///   floor is tiny, and a ratio alone would fire on sub-pixel detector quirks.
public struct NonRigidMotionDetector: Sendable {
    public var absoluteThreshold: Double = 0.015
    public var noiseRatio: Double = 2.5
    public var minLag: TimeInterval = 0.5
    public var referenceLags: [TimeInterval] = [0.55, 0.7, 0.85]
    public var maxLag: TimeInterval = 1.0
    public var maxShortLag: TimeInterval = 0.25
    public var noiseWindow: Int = 21
    public var minNoiseSamples: Int = 5
    public var requiredConsecutive: Int = 3
    public var refractory: TimeInterval = 1.0

    private var samples: [(time: TimeInterval, points: [LandmarkXY])] = []
    private var shortScores: [Double] = []
    private var consecutive = 0
    private var lastEventAt: TimeInterval?

    public init() {}

    public mutating func reset() {
        samples.removeAll(); shortScores.removeAll(); consecutive = 0; lastEventAt = nil
    }

    /// Current jitter floor (median consecutive-frame score), `nil` until enough samples.
    public var noiseFloor: Double? {
        shortScores.count >= minNoiseSamples ? median(shortScores) : nil
    }

    /// Feed one frame's landmarks. Returns an evaluation when a jitter floor and a
    /// reference frame in the lag window exist (and the point sets correspond).
    public mutating func ingest(time: TimeInterval, points: [LandmarkXY],
                                interOcular: Double) -> MotionEvaluation? {
        guard time.isFinite, interOcular.isFinite, interOcular > 0, points.count >= 6 else { return nil }
        if let last = samples.last?.time, time <= last { return nil }
        // A point-count change (different landmark constellation) invalidates history.
        if let first = samples.first, first.points.count != points.count {
            samples.removeAll(); shortScores.removeAll(); consecutive = 0
        }
        // Jitter floor: this frame vs the previous one, if it is recent enough.
        if let prev = samples.last, time - prev.time <= maxShortLag,
           let r = homographyResidualRMS(from: prev.points, to: points) {
            shortScores.append(r / interOcular)
            if shortScores.count > noiseWindow { shortScores.removeFirst(shortScores.count - noiseWindow) }
        }
        // Keep only frames that can still serve as a reference.
        samples.removeAll { time - $0.time > maxLag }
        defer { samples.append((time, points)) }

        guard let floor = noiseFloor else { consecutive = 0; return nil }
        let candidates = samples.filter { time - $0.time >= minLag }
        var refIdx: [Int] = []
        for lag in referenceLags {
            if let i = candidates.indices.min(by: { abs(time - candidates[$0].time - lag) < abs(time - candidates[$1].time - lag) }),
               !refIdx.contains(i) { refIdx.append(i) }
        }
        let residuals = refIdx.compactMap { homographyResidualRMS(from: candidates[$0].points, to: points) }
        guard let residual = median(residuals), let oldest = refIdx.map({ candidates[$0].time }).min() else {
            consecutive = 0
            return nil
        }
        let score = residual / interOcular
        let required = max(absoluteThreshold, noiseRatio * floor)
        if score > required { consecutive += 1 } else { consecutive = 0 }
        var event = false
        if consecutive >= requiredConsecutive,
           lastEventAt.map({ time - $0 >= refractory }) ?? true {
            event = true
            lastEventAt = time
            consecutive = 0
        }
        return MotionEvaluation(score: score, lag: time - oldest, noiseFloor: floor,
                                requiredScore: required, event: event)
    }
}
