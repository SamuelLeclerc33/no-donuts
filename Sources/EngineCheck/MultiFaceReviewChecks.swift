import Foundation
import CoreGraphics
import NoDonutsCore

// Owner: cooper — ND-059 code-review fixes: decisive (not overlap-based) track
// ambiguity, duplicate detections, the maxTracks invariant, landmark-less faces as
// verdict occupants, the #1-failure hold, identity + confirmation, and the selection's
// single scored evaluation.

private let userV: [Float] = [1, 0, 0, 0]
private let colleagueV: [Float] = [0, 1, 0, 0]
private let bigBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
private let smallBox = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)

private func vec(_ v: [Float], _ box: CGRect? = nil) -> FaceEmbeddingResult {
    .embedding(v, textureScore: -1, faceBox: box)
}
private func parts(_ r: FaceEmbeddingResult) -> (v: [Float], texture: Double, box: CGRect?, report: FaceSelectionReport)? {
    if case let .embedding(v, t, b, s) = r { return (v, t, b, s) }
    return nil
}
/// Records the boxes a `confirms` closure was asked about.
private final class AskedBoxes: @unchecked Sendable {
    private let lock = NSLock()
    private var _boxes: [CGRect?] = []
    func append(_ b: CGRect?) { lock.withLock { _boxes.append(b) } }
    var boxes: [CGRect?] { lock.withLock { _boxes } }
}

private func isFailure(_ r: FaceEmbeddingResult) -> Bool { if case .failure = r { return true }; return false }

/// A liveness provider that is live only for the listed boxes; counts calls per box.
private final class BoxLiveness: LivenessProviding, @unchecked Sendable {
    private let q = NSLock()
    private let liveBoxes: [CGRect]
    private(set) var calls: [CGRect?] = []
    init(live: [CGRect]) { liveBoxes = live }
    func currentVerdict(matchedFaceBox: CGRect?) -> LivenessVerdict {
        q.lock(); defer { q.unlock() }
        calls.append(matchedFaceBox)
        let live = matchedFaceBox.map { b in liveBoxes.contains(b) } ?? false
        return LivenessVerdict(live: live, evidenceAge: live ? 1 : 90, bootstrap: false)
    }
}

@MainActor
private func withAntiSpoof(_ on: Bool, _ body: () async -> Void) async {
    let key = "antiSpoofEnabled"
    let prior = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(on, forKey: key)
    await body()
    if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
}

private func store() -> InMemoryEnrollmentStore {
    InMemoryEnrollmentStore(embeddings: [userV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
}

@MainActor
func runMultiFaceReviewChecks(_ c: Checks) async {
    print("\nND-059 review fixes:")
    let dt = 1.0 / 7
    let left = CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.4)
    /// `left` shifted so IoU(left, shifted) = `iou` (same size boxes, horizontal shift).
    func beside(_ iou: Double) -> CGRect { left.offsetBy(dx: 0.3 * (1 - iou) / (1 + iou), dy: 0) }

    // MARK: 1. Ambiguity = uncertain assignment, not overlap
    // A present user with a colleague's head steadily overlapping theirs: before, the
    // overlap rule retired both tracks EVERY frame, so the user never kept evidence →
    // .notLive → a lock ~10 s later while present.
    for overlap in [0.25, 0.4] {
        var tr = FaceTracker(maxTracks: 2)
        let colleague = beside(overlap)
        var userID: Int?, liveTicks = 0, colleagueLive = 0, ticks = 0
        var i = 0, t = 0.0, nextTick = 1.0
        while t < 61 {
            let wobble = 0.004 * sin(t * 1.3)
            let userBox = left.offsetBy(dx: wobble, dy: 0.003 * cos(t))
            for a in tr.observe(faces: [(userBox, 70), (colleague.offsetBy(dx: -wobble, dy: 0), 68)], time: t)
            where a.faceIndex == 0 {
                userID = a.trackID
                if i % 70 == 3 { tr.recordEvidence(trackID: a.trackID, at: t) }     // a blink every 10 s
            }
            if t >= nextTick {
                ticks += 1
                if tr.verdict(now: t, matchedBox: userBox, windowStart: nil).live { liveTicks += 1 }
                if tr.verdict(now: t, matchedBox: colleague, windowStart: nil).live { colleagueLive += 1 }
                nextTick += 1
            }
            i += 1; t += dt
        }
        c.expect(ticks == 60 && liveTicks == 60 && colleagueLive == 0 && tr.ambiguousBreaks == 0
                 && tr.tracksStarted == 2 && userID != nil,
                 "steady overlap IoU \(overlap) for 60 s, blinks on the user's track → live every tick (\(liveTicks)/\(ticks)); colleague's box never live; no ambiguous resets")
    }

    // Uncertain assignment still retires: a face landing between two tracks, or two
    // faces nearly on top of each other.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var ids: [Int: Int] = [:]
        for a in tr.observe(faces: [(left, 70), (beside(0.25), 70)], time: 0) { ids[a.faceIndex] = a.trackID }
        tr.recordEvidence(trackID: ids[0]!, at: 0)
        let midway = left.offsetBy(dx: 0.09, dy: 0)                  // equally close to both tracks
        let a = tr.observe(faces: [(midway, 70)], time: dt)
        c.expect(a.first?.trackBreak?.reason == .ambiguous && tr.tracks.count <= 2
                 && !tr.verdict(now: dt, matchedBox: midway, windowStart: nil).live,
                 "uncertain: one face midway between two tracks → .ambiguous, no evidence carried")
    }

    // A crossing where the tracker is ALSO told the faces' landmarks agree (worst case for
    // the duplicate merge): the photo still never inherits the live stranger's evidence.
    do {
        var tr = FaceTracker(maxTracks: 2)
        let right = CGRect(x: 0.45, y: 0.3, width: 0.3, height: 0.4)
        var liveTicks = 0, i = 0
        while Double(i) * dt < 8 {
            let t = Double(i) * dt
            let p = min(max((t - 2) / 4, 0), 1)
            let strangerBox = left.offsetBy(dx: 0.35 * p, dy: 0)
            let photoBox = right.offsetBy(dx: -0.35 * p, dy: 0)
            for a in tr.observe(faces: [(strangerBox, 70), (photoBox, 70)], time: t, sameFace: { _, _ in true })
            where a.faceIndex == 0 {
                tr.recordEvidence(trackID: a.trackID, at: t)
            }
            if i % 7 == 1, tr.verdict(now: t, matchedBox: photoBox, windowStart: nil).live { liveTicks += 1 }
            i += 1
        }
        c.expect(liveTicks == 0 && tr.duplicatesMerged == 0,
                 "attack: crossing with 'landmarks agree' forced → never merged, photo never live (live ticks \(liveTicks))")
    }

    // Duplicate detections of ONE face (Vision reports it twice): merged, no reset.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var liveTicks = 0, ticks = 0, i = 0, t = 0.0, nextTick = 1.0
        while t < 61 {
            let box = left.offsetBy(dx: 0.003 * sin(t), dy: 0)
            var faces: [(box: CGRect, interOcular: Double)] = [(box, 70)]
            if i % 3 == 0 { faces.append((box.offsetBy(dx: 0.006, dy: -0.004), 71)) }  // IoU ≈ 0.95
            for a in tr.observe(faces: faces, time: t, sameFace: { _, _ in true }) where i % 70 == 3 {
                tr.recordEvidence(trackID: a.trackID, at: t)
            }
            if t >= nextTick {
                ticks += 1
                if tr.verdict(now: t, matchedBox: faces.last!.box, windowStart: nil).live { liveTicks += 1 }
                nextTick += 1
            }
            i += 1; t += dt
        }
        c.expect(liveTicks == 60 && tr.tracksStarted == 1 && tr.duplicatesMerged > 100 && tr.ambiguousBreaks == 0,
                 "duplicate detection of the user every 3rd frame for 60 s → one track, live every tick (\(liveTicks)/\(ticks)), \(tr.duplicatesMerged) merged")
    }
    do {
        // A verified user on a fresh handoff probation: a duplicate detection appearing
        // must not reset the track or drop the probation.
        var tr = FaceTracker(maxTracks: 2)
        tr.observe(faces: [(left, 70)], time: 0); tr.recordEvidence(at: 0)
        _ = tr.verdict(now: 0, matchedBox: left, windowStart: nil)
        tr.observe(faces: [(left, 95)], time: dt)                        // scale break → fresh probation
        let deadline = tr.current?.probationUntil
        let started = tr.tracksStarted
        var t = 2 * dt
        while t < 10 {
            tr.observe(faces: [(left, 95), (left.offsetBy(dx: 0.005, dy: 0), 96)], time: t, sameFace: { _, _ in true })
            t += dt
        }
        let v = tr.verdict(now: t, matchedBox: left, windowStart: nil)
        c.expect(deadline != nil && tr.tracksStarted == started && tr.tracks.count == 1
                 && tr.current?.probationUntil == deadline && v.live && v.probation,
                 "duplicate detection during a handoff probation → no new track, probation kept (still live on it)")
    }
    do {
        // Fail-safe defaults: without landmark agreement nothing is merged, and a close
        // pair next to TWO nearby tracks is never a duplicate.
        var boxOnly = FaceTracker(maxTracks: 2)
        boxOnly.observe(faces: [(left, 70), (left.offsetBy(dx: 0.005, dy: 0), 70)], time: 0)
        var two = FaceTracker(maxTracks: 2)
        two.observe(faces: [(left, 70), (beside(0.4), 70)], time: 0)
        two.observe(faces: [(left.offsetBy(dx: 0.03, dy: 0), 70), (left.offsetBy(dx: 0.04, dy: 0), 70)], time: dt,
                    sameFace: { _, _ in true })
        c.expect(boxOnly.duplicatesMerged == 0 && boxOnly.tracks.count == 2 && two.duplicatesMerged == 0,
                 "duplicates: merged only with landmark agreement, and never when two nearby tracks are near the pair")
        let a = (left: LandmarkXY(100, 200), right: LandmarkXY(170, 200))
        c.expect(eyeCentersAgree(a, (LandmarkXY(104, 203), LandmarkXY(166, 198)), interOcular: 70)
                 && !eyeCentersAgree(a, (LandmarkXY(110, 200), LandmarkXY(170, 200)), interOcular: 70)
                 && !eyeCentersAgree(a, a, interOcular: 0) && !eyeCentersAgree(a, a, interOcular: .nan),
                 "eyeCentersAgree: both eyes within 0.1 IOD; degenerate IOD → false")
    }

    // MARK: 3. At most maxTracks tracks after every frame
    do {
        var tr = FaceTracker(maxTracks: 2)
        let a = left, b = CGRect(x: 0.6, y: 0.3, width: 0.3, height: 0.4)
        var ids: [Int: Int] = [:]
        for x in tr.observe(faces: [(a, 70), (b, 70)], time: 0) { ids[x.faceIndex] = x.trackID }
        // B undetected; two faces both overlapping A nearly equally.
        let out = tr.observe(faces: [(a.offsetBy(dx: -0.03, dy: 0), 70), (a.offsetBy(dx: 0.03, dy: 0), 70)], time: dt)
        c.expect(tr.tracks.count == 2 && out.count == 2 && !tr.tracks.contains { $0.id == ids[1] }
                 && Set(tr.tracks.map(\.id)) == Set(out.map(\.trackID)),
                 "invariant: A,B tracked; B undetected; two faces over A → 2 tracks (B evicted), not 3")
        // Fuzz: random 0–3 faces per frame for 3000 frames never exceeds maxTracks.
        var rng: UInt64 = 42
        func rnd() -> Double { rng = rng &* 6_364_136_223_846_793_005 &+ 1; return Double(rng >> 11) / Double(1 << 53) }
        var fuzz = FaceTracker(maxTracks: 2), worst = 0, t = 0.0
        for _ in 0..<3000 {
            let n = Int(rnd() * 4)
            let faces = (0..<n).map { _ in
                (box: CGRect(x: 0.1 + rnd() * 0.3, y: 0.3, width: 0.25 + rnd() * 0.1, height: 0.4), interOcular: 60 + rnd() * 20)
            }
            fuzz.observe(faces: faces, time: t, occupants: rnd() < 0.2 ? [left] : [], sameFace: { _, _ in rnd() < 0.5 })
            worst = max(worst, fuzz.tracks.count)
            t += dt * (rnd() < 0.05 ? 10 : 1)
        }
        c.expect(worst <= 2 && fuzz.maxConcurrentTracks <= 2,
                 "invariant (fuzz, 3000 frames): never more than maxTracks tracks (max \(worst))")
    }

    // MARK: 4. Landmark-less faces are occupants for the verdict
    for overlap in [0.35, 0.75] {
        var tr = FaceTracker(maxTracks: 2)
        let attacker = left, photo = beside(overlap)
        var liveTicks = 0, ticks = 0
        for i in 0..<420 {
            let t = Double(i) * dt
            // The photo is detected but its landmarks fail: it reaches the tracker only as
            // an occupant. The attacker's live face blinks / moves every frame.
            for a in tr.observe(faces: [(attacker, 70)], time: t, occupants: [photo]) {
                tr.recordEvidence(trackID: a.trackID, at: t)
            }
            if i % 7 == 1 {
                ticks += 1
                if tr.verdict(now: t, matchedBox: photo, windowStart: nil).live { liveTicks += 1 }
            }
        }
        c.expect(ticks == 60 && liveTicks == 0,
                 "attack: photo with no landmarks overlapping a live attacker (IoU \(overlap)) → never live (\(liveTicks)/\(ticks))")
    }
    do {
        var tr = FaceTracker(maxTracks: 2)
        let user = left, colleague = beside(0.3)
        tr.observe(faces: [(user, 70)], time: 0, occupants: [colleague]); tr.recordEvidence(at: 0)
        let v = tr.verdict(now: 0.1, matchedBox: user, windowStart: nil)
        var ended = tr; ended.end()
        c.expect(v.live && v.trackBound == true && ended.occupants.isEmpty && ended.occupantsSeenAt == nil,
                 "occupants: a landmark-less colleague beside the user doesn't unbind the user; end() clears them")
    }

    // MARK: 6. Diagnostics report the matched face's evidence, not the freshest track's
    do {
        var tr = FaceTracker(maxTracks: 2)
        let user = left, stranger = CGRect(x: 0.6, y: 0.3, width: 0.3, height: 0.4)
        var ids: [Int: Int] = [:]
        for a in tr.observe(faces: [(user, 70), (stranger, 70)], time: 0) { ids[a.faceIndex] = a.trackID }
        tr.recordEvidence(trackID: ids[0]!, at: 0)
        _ = tr.verdict(now: 0.5, matchedBox: user, windowStart: nil)
        tr.observe(faces: [(user, 70), (stranger, 70)], time: 0.8)
        tr.recordEvidence(trackID: ids[1]!, at: 0.8)                      // the stranger blinks
        c.expect(tr.lastBoundTrackID == ids[0] && tr.matchedTrackEvidenceAt == 0
                 && tr.tracks.compactMap(\.evidenceAt).max() == 0.8,
                 "diagnostics: evidence age is the MATCHED track's (t 0), not the stranger's fresher blink (t 0.8)")
        let d = LivenessAnalyzer(antiSpoofEnabled: { true }).diagnostics()
        c.expect(d.lines.count == 6 && d.lines[0].contains("matched face") && d.lastEvidenceAge == nil,
                 "diagnostics: the evidence line names the matched face's track; nothing matched → never")
    }

    // MARK: 7. One ranking, one clamp
    do {
        let vga = CGRect(x: 0, y: 0, width: 640, height: 480)
        let mid = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)
        let mid2 = CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.27)       // same area as mid
        let big = CGRect(x: 0.25, y: 0.2, width: 0.3, height: 0.4)
        let boxes = [mid, big, mid2]
        var tr = FaceTracker(maxTracks: 9)
        let tracked = Set(tr.observe(faces: boxes.map { ($0, 70) }, time: 0).map(\.faceIndex))
        c.expect(tr.maxTracks == maxCandidateFaces && FaceSelection(maxFaces: 9, accepts: { _ in true }).maxFaces == maxCandidateFaces
                 && tracked == Set(rankedFaceCandidates(boxes: boxes, orientedExtent: vga, maxFaces: 9))
                 && faceIndicesByArea(boxes) == [1, 0, 2],
                 "one ranking: the tracker keeps exactly the faces the recognizer ranks (ties → lower index), one clamp constant")
    }

    // MARK: 2 + owner scope: the selection loop (identity, then confirmation)
    do {
        func run(_ results: [FaceEmbeddingResult], confirmBoxes: [CGRect]?,
                 textures: [Double] = [50, 60]) -> (r: FaceEmbeddingResult, textures: [Int], asked: [CGRect?]) {
            var t: [Int] = []
            let asked = AskedBoxes()
            let confirms: (@Sendable (CGRect?, Double) -> Bool)? = confirmBoxes.map { ok in
                { @Sendable box, _ in asked.append(box); return box.map { ok.contains($0) } ?? false }
            }
            let sel = FaceSelection.anyOfTop2(confirms: confirms) { $0 == userV }
            let r = selectFace(candidateCount: results.count, selection: sel,
                               embed: { results[$0] }, texture: { t.append($0); return textures[$0] })
            return (r, t, asked.boxes)
        }
        // Fix 2: #0 not the user + #1 FAILED → hold, never a stranger reading.
        let f2 = run([vec(colleagueV, bigBox), .failure], confirmBoxes: nil)
        c.expect(isFailure(f2.r) && f2.textures.isEmpty,
                 "select: #0 not accepted + #1 embedding FAILED → .failure (EC-10 mirror: #1 may be the user)")
        let poster = run([vec(userV, bigBox), vec(userV, smallBox)], confirmBoxes: [smallBox])
        c.expect(parts(poster.r)?.box == smallBox && parts(poster.r)?.texture == 60 && poster.textures == [0, 1]
                 && poster.asked == [bigBox, smallBox] && parts(poster.r)?.report.chosenRank == 1,
                 "select: #0 matches but isn't confirmed, #1 matches and is → #1 (2 textures)")
        let neither = run([vec(userV, bigBox), vec(userV, smallBox)], confirmBoxes: [])
        c.expect(parts(neither.r)?.box == bigBox && parts(neither.r)?.texture == 50 && neither.textures == [0, 1]
                 && parts(neither.r)?.report.accepted == true,
                 "select: both match, neither confirmed → #0 returned as is (its own rejection), textures ≤ 2")
        let unconfirmedThenStranger = run([vec(userV, bigBox), vec(colleagueV, smallBox)], confirmBoxes: [])
        c.expect(parts(unconfirmedThenStranger.r)?.box == bigBox && unconfirmedThenStranger.textures == [0],
                 "select: #0 unconfirmed match + #1 stranger → #0 (no texture for the unaccepted #1)")
        let unconfirmedThenFail = run([vec(userV, bigBox), .failure], confirmBoxes: [])
        c.expect(parts(unconfirmedThenFail.r)?.box == bigBox,
                 "select: #0 unconfirmed match + #1 FAILED → #0's rejection (fail closed, not a hold that stays unlocked)")
        let strangerThenPhoto = run([vec(colleagueV, bigBox), vec(userV, smallBox)], confirmBoxes: [])
        c.expect(parts(strangerThenPhoto.r)?.box == smallBox && strangerThenPhoto.textures == [1],
                 "select: #0 stranger + #1 unconfirmed match → #1, as before (the recognizer rejects it)")
        let failThenUnconfirmed = run([.failure, vec(userV, smallBox)], confirmBoxes: [])
        c.expect(isFailure(failThenUnconfirmed.r),
                 "select: #0 FAILED + #1 unconfirmed match → .failure (EC-10 hold, never stranger/not-live)")
        let failThenConfirmed = run([.failure, vec(userV, smallBox)], confirmBoxes: [smallBox])
        c.expect(parts(failThenConfirmed.r)?.box == smallBox,
                 "select: #0 FAILED + #1 confirmed match → #1 stands in")
        let first = run([vec(userV, bigBox), vec(userV, smallBox)], confirmBoxes: [bigBox])
        c.expect(parts(first.r)?.box == bigBox && first.textures == [0] && first.asked == [bigBox],
                 "select: #0 matches and is confirmed → #1 never embedded or asked (lazy)")
    }

    // MARK: 8. The selection's scored evaluation is the decision
    do {
        let sel = FaceSelection.anyOfTop2(threshold: 0.6) { Double($0[0]) }
        c.expect(sel.evaluate([0.6, 0, 0, 0]) == FaceMatch(accepted: true, score: Double(Float(0.6)))
                 && !sel.evaluate([0.59, 0, 0, 0]).accepted && !FaceSelection.anyOfTop2(threshold: 0.6) { _ in .nan }.accepts([1]),
                 "scored selection: accepted iff score ≥ threshold; NaN never accepted")
        let r = selectFace(candidateCount: 2, selection: sel,
                           embed: { $0 == 0 ? vec([0.2, 0, 0, 0], bigBox) : vec([0.9, 0, 0, 0], smallBox) },
                           texture: { _ in 1 })
        c.expect(parts(r)?.report.score == Double(Float(0.9)) && parts(r)?.report.accepted == true,
                 "select: the report carries the returned face's score from the ONE evaluation")
        // The recognizer decides from that report (no second reference scan): a report
        // that says "not accepted" wins even for the user's own vector, and vice versa.
        let says = FakeEmbedder(result: .embedding(userV, textureScore: 10_000, faceBox: bigBox,
            selection: FaceSelectionReport(facesDetected: 1, facesEmbedded: 1, chosenRank: 0, accepted: false, score: 0.1)))
        let r1 = await IdentityRecognizer(embedder: says, store: store()).recognize(CapturedFrame())
        let unscored = FakeEmbedder(result: .embedding(userV, textureScore: 10_000, faceBox: bigBox))
        let r2 = await IdentityRecognizer(embedder: unscored, store: store()).recognize(CapturedFrame())
        c.expect(r1 == .strangerOnly && r2 == .enrolledUserPresent(confidence: 1.0),
                 "recognizer: decides from the selection's scored report; an unscored report is evaluated with the same closure")
    }

    // MARK: owner scope — recognizer: identity, then confirmation
    typealias F = MultiFaceFakeEmbedder.Face
    await withAntiSpoof(true) {
        do {
            // A flat poster / photo of the user as the larger face, the live user behind it.
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV, texture: 1), F(box: smallBox, vector: userV)])
            let live = BoxLiveness(live: [smallBox])
            let r = await IdentityRecognizer(embedder: e, store: store(), liveness: live).recognize(CapturedFrame())
            c.expect(r == .enrolledUserPresent(confidence: 1.0) && e.embedCalls == 2 && e.textureCalls == 2
                     && live.calls == [smallBox],
                     "recognizer: flat poster of the user as #0 + live user #1 → present (textures 2; flat #0 never asks liveness)")
        }
        do {
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: userV)])
            let live = BoxLiveness(live: [smallBox])
            let r = await IdentityRecognizer(embedder: e, store: store(), liveness: live).recognize(CapturedFrame())
            c.expect(r == .enrolledUserPresent(confidence: 1.0) && live.calls == [bigBox, smallBox],
                     "recognizer: photo of the user (not live) as #0 + live user #1 → present; one verdict per face")
        }
        do {
            let e1 = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: colleagueV)])
            let live1 = BoxLiveness(live: [smallBox])
            let r1 = await IdentityRecognizer(embedder: e1, store: store(), liveness: live1).recognize(CapturedFrame())
            let e2 = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV, texture: 1), F(box: smallBox, vector: colleagueV)])
            let r2 = await IdentityRecognizer(embedder: e2, store: store(), liveness: BoxLiveness(live: [smallBox])).recognize(CapturedFrame())
            c.expect(r1 == .notLive && live1.calls == [bigBox] && r2 == .strangerOnly,
                     "recognizer: photo #0 + live stranger #1 → .notLive as before (flat photo → .strangerOnly as before)")
        }
        do {
            let e1 = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV, texture: 1), F(box: smallBox, vector: userV)])
            let r1 = await IdentityRecognizer(embedder: e1, store: store(), liveness: BoxLiveness(live: [])).recognize(CapturedFrame())
            let e2 = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: userV, texture: 1)])
            let r2 = await IdentityRecognizer(embedder: e2, store: store(), liveness: BoxLiveness(live: [])).recognize(CapturedFrame())
            let e3 = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: nil)])
            let r3 = await IdentityRecognizer(embedder: e3, store: store(), liveness: BoxLiveness(live: [])).recognize(CapturedFrame())
            c.expect(r1 == .strangerOnly && e1.textureCalls == 2 && r2 == .notLive && e2.textureCalls == 2 && r3 == .notLive,
                     "recognizer: both match, neither confirmed → #0's own rejection (flat → stranger, not live → notLive); #1 failed → #0's rejection")
        }
        do {
            // Fix 2 end to end: colleague larger, the user's embed glitches → hold, not a fast lock.
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: nil)])
            let r = await IdentityRecognizer(embedder: e, store: store()).recognize(CapturedFrame())
            c.expect(r == .error("face embedding failed"),
                     "recognizer: colleague larger + the user's embed FAILS → .error (hold), never .strangerOnly")
        }
        do {
            // The decision is re-derived from the returned face, whatever the embedder
            // claims: an embedder that ignores the selection can't fail open.
            let flat = FakeEmbedder(result: .embedding(userV, textureScore: 1, faceBox: bigBox,
                selection: FaceSelectionReport(facesDetected: 1, facesEmbedded: 1, chosenRank: 0, accepted: true, score: 1)))
            let r1 = await IdentityRecognizer(embedder: flat, store: store(), liveness: BoxLiveness(live: [bigBox])).recognize(CapturedFrame())
            let stale = FakeEmbedder(result: .embedding(userV, textureScore: 10_000, faceBox: bigBox))
            let r2 = await IdentityRecognizer(embedder: stale, store: store(), liveness: BoxLiveness(live: [])).recognize(CapturedFrame())
            c.expect(r1 == .strangerOnly && r2 == .notLive,
                     "recognizer: texture and liveness re-checked on the RETURNED face (a selection bug can't fail open)")
        }
    }
    await withAntiSpoof(false) {
        let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV, texture: 1), F(box: smallBox, vector: userV)])
        let live = BoxLiveness(live: [])
        let r = await IdentityRecognizer(embedder: e, store: store(), liveness: live).recognize(CapturedFrame())
        c.expect(r == .enrolledUserPresent(confidence: 1.0) && e.embedCalls == 1 && live.calls.isEmpty,
                 "recognizer: anti-spoof OFF → no confirmation step (1 embed, liveness never asked)")
    }

    // MARK: 5. FaceScore's top-2 FAR label
    do {
        let clean = ThresholdRecommendation.cleanSeparation(threshold: 0.62, margin: 0.1, impostorMaximum: 0.5, genuineMinimum: 0.7)
        let overlap = ThresholdRecommendation.overlap(equalErrorThreshold: 0.55, falseRejectRate: 0.1, falseAcceptRate: 0.1)
        let none = ThresholdRecommendation.insufficientData(reason: "x", shortfalls: [])
        c.expect(clean.topTwoFARReference?.label == "suggested" && clean.topTwoFARReference?.threshold == 0.62
                 && overlap.topTwoFARReference?.label == "EER (not a recommendation)"
                 && overlap.topTwoFARReference?.threshold == 0.55 && none.topTwoFARReference == nil,
                 "FaceScore top-2 FAR: only clean separation is 'suggested'; overlap's EER is labelled not a recommendation")
    }
}
