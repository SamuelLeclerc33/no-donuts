import Foundation
import CoreGraphics
import CoreVideo
import NoDonutsCore

// Owner: cooper — ND-116 liveness (blink + non-rigid motion) checks, EC-12.
// Pure signal math on synthetic landmark geometry, the 60 s window policy, the
// recognizer gate (.notLive) and the engine mapping (normal absence, not stranger).

private let matchV: [Float] = [1, 0, 0, 0]
private let differentV: [Float] = [0, 1, 0, 0]

/// Scripted liveness source; counts how often the recognizer asked.
final class FakeLiveness: LivenessProviding, @unchecked Sendable {
    private let q = NSLock()
    var verdict: LivenessVerdict
    private(set) var calls = 0
    private(set) var lastBox: CGRect?
    init(live: Bool) { verdict = LivenessVerdict(live: live, evidenceAge: live ? 1 : 90, bootstrap: false) }
    func currentVerdict(matchedFaceBox: CGRect?) -> LivenessVerdict {
        q.lock(); defer { q.unlock() }; calls += 1; lastBox = matchedFaceBox; return verdict
    }
}

/// Deterministic Gaussian jitter (LCG + Box–Muller) so the checks are reproducible.
private struct Jitter {
    var state: UInt64
    mutating func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }
    mutating func gauss(_ s: Double) -> Double {
        s * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
    mutating func apply(_ pts: [LandmarkXY], _ s: Double) -> [LandmarkXY] {
        pts.map { $0 + LandmarkXY(gauss(s), gauss(s)) }
    }
}

/// Synthetic 3-D head, ~71 landmark-like points. Units = inter-ocular distance (eye
/// centers at x = ±0.5), +z toward the camera; nose tip protrudes ~0.45 IOD, the jaw
/// contour sits up to ~0.65 IOD behind the eye plane (rough adult proportions).
private func syntheticHead() -> [SIMD3<Double>] {
    var p: [SIMD3<Double>] = []
    for i in 0..<17 {                                                        // jaw contour
        let a = Double.pi * Double(i) / 16
        p.append([-cos(a), 0.1 - 1.35 * sin(a), -0.55 * (1 - sin(a)) - 0.1])
    }
    for i in 0..<5 { let x = 0.25 + 0.12 * Double(i); p.append([x, 0.35, 0.02]); p.append([-x, 0.35, 0.02]) }
    for s in [-1.0, 1.0] {                                                   // eyes
        for i in 0..<8 { let a = 2 * Double.pi * Double(i) / 8; p.append([s * 0.5 + 0.17 * cos(a), 0.05 * sin(a), -0.02]) }
    }
    p.append([0.5, 0, 0]); p.append([-0.5, 0, 0])                            // pupils
    for i in 0..<5 { let t = Double(i) / 4; p.append([0, -0.1 - 0.5 * t, 0.1 + 0.35 * t]) }   // nose crest
    for i in 0..<5 { let x = -0.2 + 0.1 * Double(i); p.append([x, -0.65, 0.3 - 0.3 * abs(x)]) }
    for i in 0..<10 { let a = 2 * Double.pi * Double(i) / 10; p.append([0.4 * cos(a), -1.0 + 0.12 * sin(a), 0.12 - 0.1 * abs(cos(a))]) }
    for i in 0..<6 { let a = 2 * Double.pi * Double(i) / 6; p.append([0.3 * cos(a), -1.0 + 0.03 * sin(a), 0.1]) }
    return p
}
private func rotY(_ p: SIMD3<Double>, _ deg: Double) -> SIMD3<Double> {
    let a = deg * .pi / 180; return [p.x * cos(a) + p.z * sin(a), p.y, -p.x * sin(a) + p.z * cos(a)]
}
private func rotX(_ p: SIMD3<Double>, _ deg: Double) -> SIMD3<Double> {
    let a = deg * .pi / 180; return [p.x, p.y * cos(a) - p.z * sin(a), p.y * sin(a) + p.z * cos(a)]
}
/// Pinhole camera 8 IOD (~50 cm) away, IOD ≈ 70 px on a 640×480 frame.
private func project(_ p: SIMD3<Double>) -> LandmarkXY {
    let z = 8.0 - p.z, f = 560.0
    return LandmarkXY(320 + f * p.x / z, 240 - f * p.y / z)
}
private func homography(_ p: LandmarkXY, _ m: [Double]) -> LandmarkXY {
    let w = m[6] * p.x + m[7] * p.y + 1
    return LandmarkXY((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
}
/// A hand-held phone photo at time t: in-plane rotation, drift, and a changing
/// perspective tilt — all a homography of the photo's (frontal) landmarks.
private func handheldPhoto(_ t: Double) -> [Double] {
    let r = 0.05 * sin(t)
    return [cos(r), -sin(r), 15 * sin(t * 0.7), sin(r), cos(r), 10 * sin(t * 1.1),
            0.0006 * sin(t * 0.9), 0.0004 * sin(t * 1.3 + 1)]
}

/// Run the motion detector at ~7 fps for `seconds`; returns (#events, max score/required).
private func runMotion(seconds: Double, _ gen: (Double) -> [LandmarkXY]) -> (events: Int, peak: Double) {
    var d = NonRigidMotionDetector()
    var events = 0, peak = 0.0, t = 0.0
    while t < seconds {
        if let e = d.ingest(time: t, points: gen(t), interOcular: 70) {
            if e.event { events += 1 }
            peak = max(peak, e.score / e.requiredScore)
        }
        t += 1.0 / 7
    }
    return (events, peak)
}

private func eyePoints(cx: Double, cy: Double, width: Double, height: Double, n: Int = 8) -> [LandmarkXY] {
    (0..<n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return LandmarkXY(cx + width / 2 * cos(a), cy + height / 2 * sin(a))
    }
}

/// Run anti-spoof ON/OFF for the body (the recognizer reads `.standard`), then restore.
@MainActor
private func withAntiSpoof(_ on: Bool, _ body: () async -> Void) async {
    let key = "antiSpoofEnabled"
    let prior = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(on, forKey: key)
    await body()
    if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
}

@MainActor
func runLivenessChecks(_ c: Checks) async {
    print("\nLiveness checks (ND-116):")

    // MARK: 60 s window policy
    do {
        c.expect(isLive(now: 100, lastEvidence: 90, windowStart: nil), "policy: evidence 10 s ago → live")
        c.expect(isLive(now: 100, lastEvidence: 40, windowStart: nil), "policy: evidence exactly 60 s ago → live")
        c.expect(!isLive(now: 100, lastEvidence: 39, windowStart: nil), "policy: evidence 61 s ago → NOT live")
        c.expect(!isLive(now: 100, lastEvidence: nil, windowStart: nil), "policy: no evidence, no window → NOT live")
        c.expect(isLive(now: 100, lastEvidence: nil, windowStart: 70), "policy: 30 s into the bootstrap window → live")
        c.expect(!isLive(now: 100, lastEvidence: nil, windowStart: 39), "policy: bootstrap window expired (61 s) → NOT live")
        c.expect(!isLive(now: 100, lastEvidence: nil, windowStart: 110), "policy: window start in the future → not a bootstrap")
        c.expect(!isLive(now: 100, lastEvidence: 99, windowStart: 99, window: 0), "policy: non-positive window → never live")
        c.expect(!isLive(now: 100, lastEvidence: .nan, windowStart: .nan), "policy: NaN times → NOT live")
        let boot = LivenessVerdict.evaluate(now: 100, lastEvidence: nil, windowStart: 90)
        let ev = LivenessVerdict.evaluate(now: 100, lastEvidence: 97, windowStart: 90)
        let stale = LivenessVerdict.evaluate(now: 200, lastEvidence: 97, windowStart: 90)
        c.expect(boot.live && boot.bootstrap && boot.evidenceAge == nil
                 && ev.live && !ev.bootstrap && ev.evidenceAge == 3
                 && !stale.live && !stale.bootstrap && stale.evidenceAge == 103,
                 "verdict: bootstrap flag only when live via the window; evidence age reported")
        c.expect(ev.logDescription == "yes (last evidence 3.0s ago)"
                 && stale.logDescription == "no (last evidence 103.0s ago)"
                 && boot.logDescription.hasPrefix("yes (startup window"),
                 "verdict: numeric-only log text")
    }

    // MARK: Eye openness
    do {
        let lips = eyePoints(cx: 0, cy: -70, width: 50, height: 10)
        let open = eyePoints(cx: -35, cy: 0, width: 30, height: 12)
        let closed = eyePoints(cx: -35, cy: 0, width: 30, height: 3)
        let right = eyePoints(cx: 35, cy: 0, width: 30, height: 12)
        let scale = faceVerticalScale(leftEye: open, rightEye: right, lips: lips) ?? 0
        let o = eyeOpenness(eye: open, faceVerticalScale: scale) ?? -1
        let shuffled = eyeOpenness(eye: open.reversed().shuffled(), faceVerticalScale: scale) ?? -2
        let cl = eyeOpenness(eye: closed, faceVerticalScale: scale) ?? -1
        c.expect(abs(scale - 70) < 1e-9 && abs(o - 12.0 / 70) < 1e-9, "openness: eye height / eye-to-mouth distance")
        c.expect(abs(o - shuffled) < 1e-12, "openness: independent of contour point order")
        c.expect(cl < 0.3 * o, "openness: closed eye ≪ open eye")
        // A photo tilted back (pitch) foreshortens ALL vertical lengths — must not look
        // like a blink. Classic EAR (height/width) would drop by the same factor.
        let squash = { (pts: [LandmarkXY]) in pts.map { LandmarkXY($0.x, $0.y * 0.55) } }
        let s2 = faceVerticalScale(leftEye: squash(open), rightEye: squash(right), lips: squash(lips)) ?? 0
        let o2 = eyeOpenness(eye: squash(open), faceVerticalScale: s2) ?? -1
        c.expect(abs(o2 - o) < 1e-9, "openness: invariant to photo pitch foreshortening (a tilt flick can't fake a blink)")
        // Roll (in-plane rotation) and scale: invariant too.
        let rot = { (pts: [LandmarkXY]) in pts.map { LandmarkXY(1.7 * ($0.x * cos(0.4) - $0.y * sin(0.4)), 1.7 * ($0.x * sin(0.4) + $0.y * cos(0.4))) } }
        let s3 = faceVerticalScale(leftEye: rot(open), rightEye: rot(right), lips: rot(lips)) ?? 0
        let o3 = eyeOpenness(eye: rot(open), faceVerticalScale: s3) ?? -1
        c.expect(abs(o3 - o) < 1e-9, "openness: invariant to roll + scale")
        c.expect(eyeOpenness(eye: Array(open.prefix(3)), faceVerticalScale: 70) == nil
                 && eyeOpenness(eye: open, faceVerticalScale: 0) == nil
                 && faceVerticalScale(leftEye: [], rightEye: right, lips: lips) == nil,
                 "openness: degenerate input → nil")
    }

    // MARK: Blink detector (7 fps)
    do {
        let dt = 1.0 / 7
        /// Feed `values` (left, right openness) at 7 fps after 2 s of open eyes; count blinks.
        func blinks(_ script: [(Double, Double)], jitter: Double = 0.003, gapAt: Int? = nil) -> [BlinkEvent] {
            var d = BlinkDetector(); var j = Jitter(state: 7); var out: [BlinkEvent] = []
            var t = 0.0
            for _ in 0..<14 { if let e = d.ingest(time: t, left: 0.17 + j.gauss(jitter), right: 0.17 + j.gauss(jitter)) { out.append(e) }; t += dt }
            for (i, v) in script.enumerated() {
                if i == gapAt { t += 1.0 }
                if let e = d.ingest(time: t, left: v.0, right: v.1) { out.append(e) }
                t += dt
            }
            return out
        }
        let open = (0.17, 0.17), shut = (0.04, 0.05)
        let one = blinks([shut, shut, open, open, open])
        c.expect(one.count == 1 && one[0].closedDuration < 0.5 && one[0].minRatio < 0.35,
                 "blink: both eyes ~25% for ~2 frames then reopen → 1 blink")
        c.expect(blinks([shut, open]).count == 1, "blink: a single closed sample (~143 ms) → blink")
        c.expect(blinks(Array(repeating: shut, count: 8) + [open]).isEmpty,
                 "blink: eyes closed ~1 s (looking down / resting) → NOT a blink")
        c.expect(blinks([(0.13, 0.13), (0.13, 0.13), open]).isEmpty,
                 "blink: shallow 24% dip (above 0.6×baseline) → NOT a blink")
        c.expect(blinks([(0.04, 0.17), (0.04, 0.17), open]).isEmpty, "blink: one eye only (wink / occlusion) → NOT a blink")
        c.expect(blinks([shut, shut, open], gapAt: 2).isEmpty, "blink: a >0.5 s sample gap before the reopen abandons the dip")
        c.expect(blinks([(0.12, 0.12), open]).isEmpty, "blink: hysteresis — 0.71× is neither closed nor a blink")
        let three = blinks([shut, open, open, open, open, open, open, shut, shut, open, open, open, open, open, open, shut, open])
        c.expect(three.count == 3, "blink: three separated blinks → 3")
        // Jittery still photo, 60 s: no blinks.
        var d = BlinkDetector(); var j = Jitter(state: 11); var n = 0
        for i in 0..<420 { if d.ingest(time: Double(i) * dt, left: 0.17 + j.gauss(0.01), right: 0.17 + j.gauss(0.01)) != nil { n += 1 } }
        c.expect(n == 0, "blink: 60 s of a still photo with 6% openness jitter → 0 blinks")
        // No baseline yet → nothing.
        var fresh = BlinkDetector()
        _ = fresh.ingest(time: 0, left: 0.17, right: 0.17)
        c.expect(fresh.ingest(time: 0.14, left: 0.02, right: 0.02) == nil
                 && fresh.ingest(time: 0.28, left: 0.17, right: 0.17) == nil,
                 "blink: no blink before the open-eye baseline exists")
        // Review fix: a sustained LOWER openness (looking down, squint, glasses glare)
        // must not leave the detector stuck mid-dip — the baseline adapts and blinks at
        // the new level are detected again.
        do {
            var d = BlinkDetector(); var t = 0.0; var found: [TimeInterval] = []
            func feed(_ v: Double, _ n: Int) {
                for _ in 0..<n { if d.ingest(time: t, left: v, right: v) != nil { found.append(t) }; t += dt }
            }
            feed(0.17, 14)                      // open, baseline 0.17
            feed(0.09, 42)                      // 6 s at 53% (below 0.6×): not a blink, must re-baseline
            let noneDuringShift = found.isEmpty && !d.inDip
            feed(0.02, 1); feed(0.09, 8)        // blink at the NEW level
            feed(0.02, 2); feed(0.09, 8)
            c.expect(noneDuringShift && found.count == 2,
                     "blink: sustained lower openness → baseline adapts → later blinks detected (\(found.count))")
        }
    }

    // MARK: Face track — evidence bound to one continuous face (review fix)
    do {
        let dt = 1.0 / 7
        let base = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
        // Continuous live face drifting ~0.02/frame + IOD ±3%: one track, evidence kept.
        var tr = FaceTrack(); var resets = 0
        for i in 0..<210 {
            let t = Double(i) * dt
            let b = base.offsetBy(dx: 0.08 * sin(t), dy: 0.05 * sin(t * 0.7))
            if !tr.observe(box: b, interOcular: 70 * (1 + 0.03 * sin(t * 1.3)), time: t), i > 0 { resets += 1 }
            if i == 20 { tr.recordEvidence(at: t) }
        }
        let now = 209 * dt
        let v = LivenessVerdict.evaluate(now: now, track: tr, matchedBox: tr.lastBox, windowStart: nil)
        c.expect(resets == 0 && v.live && v.trackBound == true, "track: continuous moving live face → one track, its evidence counts")
        // Jump / scale / gap each start a new track and drop its evidence.
        func fresh() -> FaceTrack {
            var t = FaceTrack(); t.observe(box: base, interOcular: 70, time: 0); t.recordEvidence(at: 0); return t
        }
        var j = fresh()
        let jumped = !j.observe(box: base.offsetBy(dx: 0.2, dy: 0), interOcular: 70, time: dt)
        c.expect(jumped && j.evidenceAt == nil, "track: box jump (IoU < 0.4) → new track, evidence dropped")
        var sc = fresh()
        let scaled = !sc.observe(box: base, interOcular: 90, time: dt)
        c.expect(scaled && sc.evidenceAt == nil, "track: inter-ocular jump > 25% → new track, evidence dropped")
        var g = fresh()
        let gapBroke = !g.observe(box: base, interOcular: 70, time: 0.6)
        var g2 = fresh()
        let gapOk = g2.observe(box: base, interOcular: 70, time: 0.45)
        c.expect(gapBroke && g.evidenceAt == nil && gapOk && g2.evidenceAt == 0,
                 "track: > 0.5 s gap → new track; ≤ 0.5 s (missed detections) → same track")
        // Verdict binding.
        let t1 = fresh()
        let other = base.offsetBy(dx: 0.25, dy: 0)
        c.expect(!LivenessVerdict.evaluate(now: 0.1, track: t1, matchedBox: other, windowStart: nil).live,
                 "verdict: matched box not overlapping the current track → NOT live")
        c.expect(!LivenessVerdict.evaluate(now: 0.1, track: t1, matchedBox: nil, windowStart: nil).live,
                 "verdict: no matched box → NOT live (fail-safe)")
        c.expect(LivenessVerdict.evaluate(now: 0.1, track: t1, matchedBox: nil, windowStart: 0).live,
                 "verdict: no matched box but inside the enforcement-start window → live")
        c.expect(!LivenessVerdict.evaluate(now: 2, track: t1, matchedBox: base, windowStart: nil).live,
                 "verdict: track not seen for > 0.5 s (stale) → NOT live")
        c.expect(LivenessVerdict.evaluate(now: 0.1, track: t1, matchedBox: base.offsetBy(dx: 0.03, dy: 0), windowStart: nil).live,
                 "verdict: matched box on the tracked face with evidence → live")
        c.expect(abs(intersectionOverUnion(base, base) - 1) < 1e-9 && intersectionOverUnion(base, base.offsetBy(dx: 0.4, dy: 0)) == 0
                 && intersectionOverUnion(.zero, base) == 0, "IoU: identity 1, disjoint 0, degenerate 0")
    }

    // MARK: Attack — phone photo at each tick, attacker's own face blinking between ticks
    do {
        let dt = 1.0 / 7
        let attacker = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)     // real face, beside the phone
        let phone = CGRect(x: 0.5, y: 0.3, width: 0.3, height: 0.4)        // photo held up at ticks
        let samePlace = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)    // photo swapped into the same box…
        for (label, photoBox, photoIOD) in [("side by side", phone, 70.0), ("same box, smaller photo", samePlace, 50.0)] {
            var tr = FaceTrack(); var anyLive = false; var ticks = 0
            for i in 0..<420 {                                              // 60 s at 7 fps
                let t = Double(i) * dt
                let phase = i % 7                                           // 1 s tick cycle
                if phase < 2 {
                    tr.observe(box: photoBox, interOcular: photoIOD, time: t)   // photo in view around the tick
                    if phase == 1 {                                          // the tick: recognizer matched the photo
                        ticks += 1
                        if LivenessVerdict.evaluate(now: t, track: tr, matchedBox: photoBox, windowStart: nil).live { anyLive = true }
                    }
                } else {
                    tr.observe(box: attacker, interOcular: 70, time: t)      // attacker's face, blinking
                    tr.recordEvidence(at: t)
                }
            }
            c.expect(!anyLive && ticks == 60, "attack (\(label)): photo at ticks + live stranger between → never live")
        }
    }

    // MARK: Homography residual
    do {
        let head = syntheticHead().map(project)
        let m = [1.05, 0.1, 12, -0.08, 0.97, -7, 0.0003, -0.0002]
        let warped = head.map { homography($0, m) }
        let r = homographyResidualRMS(from: head, to: warped) ?? -1
        c.expect(r >= 0 && r < 1e-6, "homography: a flat picture under any projective transform refits exactly (residual \(String(format: "%.1e", r)) px)")
        let yaw = syntheticHead().map { project(rotY($0, 15)) }
        let ry = (homographyResidualRMS(from: head, to: yaw) ?? 0) / 70
        c.expect(ry > 0.035, "homography: live 15° head turn leaves parallax (\(String(format: "%.3f", ry)) IOD)")
        c.expect(homographyResidualRMS(from: Array(head.prefix(5)), to: Array(warped.prefix(5))) == nil
                 && homographyResidualRMS(from: head, to: Array(warped.dropLast())) == nil
                 && homographyResidualRMS(from: Array(repeating: LandmarkXY(1, 1), count: 20),
                                          to: Array(repeating: LandmarkXY(2, 2), count: 20)) == nil,
                 "homography: <6 points / mismatched / degenerate → nil")
    }

    // MARK: Non-rigid motion detector — photo vs live (synthetic, 60 s at 7 fps)
    do {
        let head3 = syntheticHead()
        let photo = head3.map(project)
        for sigma in [0.3, 0.7, 1.0] {
            var j = Jitter(state: 42)
            let p = runMotion(seconds: 60) { t in j.apply(photo.map { homography($0, handheldPhoto(t)) }, sigma) }
            c.expect(p.events == 0 && p.peak < 1,
                     "motion: hand-held phone photo, \(sigma) px jitter → 0 events (peak \(String(format: "%.2f", p.peak))× required)")
        }
        var js = Jitter(state: 5)
        let still = runMotion(seconds: 60) { t in js.apply(head3.map { project(rotY($0, 0.5 * sin(t * 0.5))) }, 0.7) }
        c.expect(still.events == 0, "motion: live but motionless (±0.5°) → no motion event (blinks must carry it)")
        // Live motions the PROVISIONAL constants (ratio 2.5 × 3 in a row) are expected to
        // catch; a ±10° turn at 0.7 px jitter is deliberately NOT required (sensitivity
        // traded for zero false events on a moving flat picture — see the detector doc).
        for (label, sigma, gen) in [("turn ±10°/2 s", 0.5, { (t: Double, p: SIMD3<Double>) in rotY(p, 10 * sin(t * .pi)) }),
                                    ("nod ±10°/2 s", 0.7, { (t: Double, p: SIMD3<Double>) in rotX(p, 10 * sin(t * .pi)) }),
                                    ("turn ±20°/4 s", 0.7, { (t: Double, p: SIMD3<Double>) in rotY(p, 20 * sin(t * .pi / 2)) })] {
            var j = Jitter(state: 9)
            let live = runMotion(seconds: 20) { t in j.apply(head3.map { project(gen(t, $0)) }, sigma) }
            c.expect(live.events >= 2, "motion: live \(label), \(sigma) px jitter → events (\(live.events) in 20 s, peak \(String(format: "%.2f", live.peak))×)")
        }
        // Heavy-tailed landmark glitches (seen on real Vision output): two ADJACENT
        // glitched frames every few seconds on a still photo must not fire an event.
        do {
            var j = Jitter(state: 21)
            let still = runMotion(seconds: 60) { t in
                var pts = j.apply(photo.map { homography($0, handheldPhoto(t)) }, 0.5)
                let k = Int((t * 7).rounded())
                if k % 25 == 0 || k % 25 == 1 { for i in 0..<12 { pts[i] += LandmarkXY(j.gauss(6), j.gauss(6)) } }
                return pts
            }
            c.expect(still.events == 0, "motion: 2-frame landmark glitches on a photo → 0 events (reference median + 3 in a row)")
        }
        // Refractory + persistence: one sustained turn yields ~1 event per second at most.
        var j2 = Jitter(state: 3)
        let burst = runMotion(seconds: 10) { t in j2.apply(head3.map { project(rotY($0, 10 * sin(t * .pi))) }, 0.3) }
        c.expect(burst.events <= 10, "motion: refractory caps events at ≤ 1/s (\(burst.events) in 10 s)")
        // Constellation change (different point count) resets instead of comparing garbage.
        var d = NonRigidMotionDetector()
        var t = 0.0, evals = 0
        for i in 0..<30 {
            let pts = i < 15 ? photo : Array(photo.dropLast())
            if d.ingest(time: t, points: pts, interOcular: 70) != nil { evals += 1 }
            t += 1.0 / 7
        }
        c.expect(evals > 0 && d.noiseFloor != nil, "motion: point-count change resets history, then re-arms")
    }

    // MARK: Recognizer gate (.notLive)
    await withAntiSpoof(true) {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let notLive = FakeLiveness(live: false)
        let r1 = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, liveness: notLive).recognize(CapturedFrame())
        c.expect(r1 == .notLive && notLive.calls == 1, "recognizer: enrolled MATCH + no live evidence → .notLive (ND-116)")
        let live = FakeLiveness(live: true)
        let r2 = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, liveness: live).recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = r2 { present = true }
        c.expect(present, "recognizer: enrolled match + live evidence → present")
        let strangerL = FakeLiveness(live: false)
        let r3 = await IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store, liveness: strangerL).recognize(CapturedFrame())
        c.expect(r3 == .strangerOnly && strangerL.calls == 0, "recognizer: non-match stays .strangerOnly; liveness not consulted")
        let flatL = FakeLiveness(live: false)
        let r4 = await IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 0), store: store, liveness: flatL).recognize(CapturedFrame())
        c.expect(r4 == .strangerOnly, "recognizer: flat texture still → .strangerOnly (texture check keeps precedence)")
        let noEnroll = FakeLiveness(live: false)
        let r5 = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: InMemoryEnrollmentStore(), liveness: noEnroll).recognize(CapturedFrame())
        var p5 = false
        if case .enrolledUserPresent = r5 { p5 = true }
        c.expect(p5 && noEnroll.calls == 0, "recognizer: NOT enrolled (presence-only) → liveness not required")
        let staleStore = InMemoryEnrollmentStore()
        try? staleStore.enroll(embeddings: [matchV], modelVersion: "some-other-model")
        let mm = FakeLiveness(live: false)
        let r6 = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: staleStore, liveness: mm).recognize(CapturedFrame())
        var p6 = false
        if case .enrolledUserPresent = r6 { p6 = true }
        c.expect(p6 && mm.calls == 0, "recognizer: model-mismatch presence-only path → liveness not required")
        let r7 = await IdentityRecognizer(embedder: FakeEmbedder(nil), store: store, liveness: FakeLiveness(live: false)).recognize(CapturedFrame())
        c.expect(r7 == .noFace, "recognizer: no face stays .noFace")
        let box = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.4)
        let boxL = FakeLiveness(live: true)
        _ = await IdentityRecognizer(embedder: FakeEmbedder(result: .embedding(matchV, textureScore: 10_000, faceBox: box)),
                                     store: store, liveness: boxL).recognize(CapturedFrame())
        c.expect(boxL.lastBox == box, "recognizer: passes the MATCHED face's box to the liveness verdict (track binding)")
        let r8 = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store).recognize(CapturedFrame())
        var p8 = false
        if case .enrolledUserPresent = r8 { p8 = true }
        c.expect(p8, "recognizer: no liveness provider wired → not required (FaceScore / legacy)")
    }
    await withAntiSpoof(false) {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let l = FakeLiveness(live: false)
        let r = await IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store, liveness: l).recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = r { present = true }
        c.expect(present && l.calls == 0, "recognizer: 'Reject photos of me' OFF → liveness not required (one toggle gates texture + liveness)")
    }

    // MARK: Engine mapping — .notLive is a NORMAL absence
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.notLive), locker, config)
        for i in 0..<3 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let noFastLock = locker.lockCallCount == 0 && e.state == .absent
        for i in 3..<5 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        let noLockBeforeGrace = locker.lockCallCount == 0
        await e.tick(now: t0.addingTimeInterval(4 + config.graceSeconds + 0.1))
        c.expect(noFastLock && noLockBeforeGrace && locker.lockCallCount == 1 && e.state == .suspended,
                 "engine: .notLive → .absent, no 3-tick stranger lock; locks after consensus + grace")
    }
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.strangerOnly, .strangerOnly, .notLive, .strangerOnly]), locker)
        for i in 0..<4 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 0, "engine: .notLive breaks the stranger streak (like noFace)")
    }
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())),
                           SeqRecognizer([.notLive, .notLive, .notLive, .notLive, .enrolledUserPresent(confidence: 0.9),
                                          .notLive, .notLive, .notLive, .notLive]), locker)
        for i in 0..<9 { await e.tick(now: t0.addingTimeInterval(Double(i) * 3)) }
        c.expect(locker.lockCallCount == 0, "engine: a live reading resets the .notLive absence consensus")
    }

    // MARK: Analyzer plumbing (no face → no evidence; toggle gating)
    do {
        let enabled = FlagBox(true)
        let a = LivenessAnalyzer(antiSpoofEnabled: { enabled.value })
        let frame = makeGrayBGRAFrame(width: 64, height: 48) { x, y in UInt8((x * 7 + y * 3) % 256) }
        a.beginWindow()
        let v0 = a.currentVerdict(matchedFaceBox: nil)
        c.expect(v0.live && v0.bootstrap, "analyzer: beginWindow → live via the bootstrap window")
        for i in 0..<3 {
            a.submit(CapturedFrame(pixelBuffer: frame, captureTime: livenessHostNow() + Double(i) * 0.15))
            for _ in 0..<200 where a.diagnostics().framesAnalyzed + a.diagnostics().framesDropped <= i { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        let d = a.diagnostics()
        c.expect(d.framesAnalyzed + d.framesDropped == 3 && d.framesWithFace == 0 && d.blinks == 0 && d.lastEvidenceAge == nil,
                 "analyzer: faceless frames analyzed, no evidence")
        enabled.value = false
        let before = a.diagnostics().framesAnalyzed + a.diagnostics().framesDropped
        a.submit(CapturedFrame(pixelBuffer: frame, captureTime: livenessHostNow()))
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.expect(a.diagnostics().framesAnalyzed + a.diagnostics().framesDropped == before,
                 "analyzer: anti-spoof off → frames are not analyzed (no power cost)")
        c.expect(a.diagnostics().lines.count == 5, "analyzer: diagnostics lines (numbers only)")
    }
}

final class FlagBox: @unchecked Sendable {
    private let q = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { q.lock(); defer { q.unlock() }; return v } set { q.lock(); v = newValue; q.unlock() } }
}
