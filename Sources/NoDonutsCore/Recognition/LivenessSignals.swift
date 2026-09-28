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

/// One continuous track of the largest face (ND-116). Evidence (blinks / motion)
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
    public enum Reason: String, Sendable { case first, gap, overlap, scale }
    public enum Handoff: String, Sendable { case none, fresh, inherited }
    public let reason: Reason
    public let gap: TimeInterval?
    public let iou: Double?
    public let iodChange: Double?
    public let handoff: Handoff
}

/// Face-track state machine (ND-116; pure value type, EngineCheck-covered).
///
/// **Why tracks** (security review): a phone photo shown at each 1 s recognition tick
/// while the attacker's own face blinks between ticks. Swapping photo ↔ face moves or
/// rescales the largest face box, which breaks the track; the matched (photo) box then
/// belongs to a track with no evidence → not live.
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
public struct FaceTracker: Sendable, Equatable {
    public private(set) var current: FaceTrack?
    public private(set) var tracksStarted = 0
    public private(set) var freshHandoffs = 0
    public private(set) var inheritedHandoffs = 0
    public var window: TimeInterval
    private var nextID = 1

    public init(window: TimeInterval = defaultLivenessWindowSeconds) { self.window = window }

    /// Observe the largest face (Vision-normalized box, inter-ocular distance in pixels).
    /// Returns `nil` if it continues the current track, else the `TrackBreak` that
    /// started a new one (the caller must then reset its detectors). Invalid input
    /// (non-finite, empty box) ends the current track and returns `nil`.
    @discardableResult
    public mutating func observe(box: CGRect, interOcular: Double, time: TimeInterval) -> TrackBreak? {
        guard time.isFinite, interOcular.isFinite, interOcular > 0,
              intersectionOverUnion(box, box) > 0 else { current = nil; return nil }
        var reason = TrackBreak.Reason.first
        var gap: TimeInterval?, iou: Double?, iodChange: Double?
        if var t = current {
            let dt = time - t.lastSeen
            let o = intersectionOverUnion(box, t.lastBox)
            let dIOD = abs(interOcular - t.lastIOD) / t.lastIOD
            gap = dt; iou = o; iodChange = dIOD
            if dt < 0 { return nil }                                     // out of order: ignore
            if dt > FaceTrack.maxGap { reason = .gap }
            else if o < FaceTrack.minIoU { reason = .overlap }
            else if dIOD > FaceTrack.maxIODChange { reason = .scale }
            else {
                t.lastBox = box; t.lastIOD = interOcular; t.lastSeen = time
                current = t
                return nil
            }
        }
        // New track; decide the handoff from the predecessor's state at the break.
        var handoff = TrackBreak.Handoff.none
        var probation: TimeInterval?
        if let p = current, time - p.lastSeen <= FaceTrack.handoffGap,
           p.overlaps(box, minIoU: FaceTrack.handoffMinIoU) {
            if p.verified, isLive(now: time, lastEvidence: p.evidenceAt, windowStart: nil, window: window) {
                probation = time + FaceTrack.probationSeconds
                handoff = .fresh; freshHandoffs += 1
            } else if let d = p.probationUntil, time <= d {
                probation = d
                handoff = .inherited; inheritedHandoffs += 1
            }
        }
        current = FaceTrack(id: nextID, lastBox: box, lastIOD: interOcular, lastSeen: time,
                            startedAt: time, evidenceAt: nil, verified: false, probationUntil: probation)
        nextID &+= 1
        tracksStarted += 1
        return TrackBreak(reason: reason, gap: gap, iou: iou, iodChange: iodChange, handoff: handoff)
    }

    /// Record live evidence on the current track (ignored if there is none).
    public mutating func recordEvidence(at time: TimeInterval) {
        guard var t = current, time.isFinite else { return }
        t.evidenceAt = max(t.evidenceAt ?? time, time)
        current = t
    }

    /// Drop the track (enforcement restart). No handoff survives it.
    public mutating func end() { current = nil }

    /// Track-bound verdict for a face the recognizer MATCHED at `matchedBox`. Also marks
    /// that track `verified` (the only way a track becomes verified).
    ///
    /// Live when the current track is fresh (seen ≤ `maxGap` ago), overlaps `matchedBox`
    /// (IoU ≥ `minIoU`) and has its own evidence ≤ `window` old or an unexpired
    /// probation; or when inside the enforcement-start window. No box → not bound.
    ///
    /// The enforcement-start window is deliberately NOT track-bound: it covers the
    /// moments before the analyzer has any track (camera just started, first landmark
    /// pass cold) and only opens after an OS unlock or the user's own pause / Wi-Fi /
    /// enrollment action on an unlocked Mac. Binding it adds false locks, no security.
    public mutating func verdict(now: TimeInterval, matchedBox: CGRect?,
                                 windowStart: TimeInterval?) -> LivenessVerdict {
        var bound = false
        if var t = current, t.isFresh(at: now), let m = matchedBox, t.overlaps(m) {
            bound = true
            t.verified = true
            current = t
        }
        let evidence = bound ? current?.evidenceAt : nil
        let byEvidence = isLive(now: now, lastEvidence: evidence, windowStart: nil, window: window)
        let byProbation = bound && (current?.probationUntil.map { now <= $0 } ?? false)
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
