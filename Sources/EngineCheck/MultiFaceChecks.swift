import Foundation
import CoreGraphics
import NoDonutsCore

// Owner: cooper — ND-059 multi-face matching (EC-06): the ranking helper, the shared
// selection loop, the top-N FAR helper, and (below) the recognizer / liveness / enrollment
// behaviour built on them.

private let userV: [Float] = [1, 0, 0, 0]
private let colleagueV: [Float] = [0, 1, 0, 0]
private let otherV: [Float] = [0, 0, 1, 0]

/// A synthetic vector result for `selectFace`'s `embed` closure.
private func vec(_ v: [Float], _ box: CGRect? = nil) -> FaceEmbeddingResult {
    .embedding(v, textureScore: -1, faceBox: box)   // texture ignored by the loop
}

private func isFailure(_ r: FaceEmbeddingResult) -> Bool { if case .failure = r { return true }; return false }
private func isNoFace(_ r: FaceEmbeddingResult) -> Bool { if case .noFace = r { return true }; return false }
private func parts(_ r: FaceEmbeddingResult) -> (v: [Float], texture: Double, box: CGRect?, report: FaceSelectionReport)? {
    if case let .embedding(v, t, b, s) = r { return (v, t, b, s) }
    return nil
}

/// ND-059 sub-phase 1: pure helpers.
@MainActor
func runMultiFaceSelectionChecks(_ c: Checks) async {
    print("\nND-059 multi-face selection helpers:")

    // MARK: rankedFaceCandidates
    do {
        let vga = CGRect(x: 0, y: 0, width: 640, height: 480)
        let big = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let mid = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)
        let tiny = CGRect(x: 0.8, y: 0.8, width: 0.05, height: 0.05)
        c.expect(rankedFaceCandidates(boxes: [mid, big, tiny], orientedExtent: vga, maxFaces: 2) == [1, 0],
                 "rank: top-2 by area, largest first")
        c.expect(rankedFaceCandidates(boxes: [mid, big], orientedExtent: vga, maxFaces: 1) == [1],
                 "rank: maxFaces 1 → the largest only (pre-ND-059 rule)")
        c.expect(rankedFaceCandidates(boxes: [mid, mid], orientedExtent: vga, maxFaces: 2) == [0, 1],
                 "rank: equal areas keep input order (deterministic; same face max(by:) picked)")
        // #1 by area fails the gate (a thin sliver); a smaller #2 would pass it. It must
        // NOT be promoted into the top two.
        let sliver = CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.05)       // short side 24 px < 57.6
        let smallOK = CGRect(x: 0.6, y: 0.5, width: 0.12, height: 0.12)    // 0.0144 < 0.015, short side 57.6
        c.expect(rankedFaceCandidates(boxes: [big, sliver, smallOK], orientedExtent: vga, maxFaces: 2) == [0],
                 "rank: top-N by area FIRST, then the ND-085 gate — a small 3rd face is never promoted")
        c.expect(rankedFaceCandidates(boxes: [tiny], orientedExtent: vga, maxFaces: 2).isEmpty
                 && rankedFaceCandidates(boxes: [], orientedExtent: vga, maxFaces: 2).isEmpty,
                 "rank: only too-small faces / no faces → no candidate (.noFace)")
        c.expect(rankedFaceCandidates(boxes: [big, mid, smallOK], orientedExtent: vga, maxFaces: 5).count == 2
                 && rankedFaceCandidates(boxes: [big, mid], orientedExtent: vga, maxFaces: 0) == [0],
                 "rank: maxFaces clamped to 1...2")
        let nanBox = CGRect(x: 0.1, y: 0.1, width: CGFloat.nan, height: 0.5)
        c.expect(rankedFaceCandidates(boxes: [nanBox, mid], orientedExtent: vga, maxFaces: 2) == [1],
                 "rank: a non-finite box sorts last and fails the gate")
    }

    // MARK: selectFace (the shared loop)
    do {
        let accUser = FaceSelection.anyOfTop2 { $0 == userV }
        let boxA = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let boxB = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)
        /// Run the loop over scripted per-rank results; count embeds / textures.
        func run(_ results: [FaceEmbeddingResult], _ sel: FaceSelection, textures: [Double] = [50, 60],
                 detected: Int? = nil) -> (r: FaceEmbeddingResult, embeds: [Int], textures: [Int]) {
            var e: [Int] = [], t: [Int] = []
            let r = selectFace(facesDetected: detected, candidateCount: results.count, selection: sel,
                               embed: { e.append($0); return results[$0] },
                               texture: { t.append($0); return textures[$0] })
            return (r, e, t)
        }

        let colleagueLarger = run([vec(colleagueV, boxA), vec(userV, boxB)], accUser, detected: 3)
        let p1 = parts(colleagueLarger.r)
        c.expect(p1?.v == userV && p1?.box == boxB && p1?.texture == 60
                 && colleagueLarger.embeds == [0, 1] && colleagueLarger.textures == [1]
                 && p1?.report == FaceSelectionReport(facesDetected: 3, facesEmbedded: 2, chosenRank: 1, accepted: true),
                 "select: colleague larger + user smaller → user's vector, box and texture (2 embeds, rank #2)")

        let strangers = run([vec(colleagueV, boxA), vec(otherV, boxB)], accUser)
        let p2 = parts(strangers.r)
        c.expect(p2?.v == colleagueV && p2?.box == boxA && p2?.texture == 50 && strangers.embeds == [0, 1]
                 && strangers.textures == [0] && p2?.report.accepted == false && p2?.report.chosenRank == 0,
                 "select: two strangers → the LARGEST face, unaccepted (stranger path), texture on it only")

        let userLargest = run([vec(userV, boxA), vec(colleagueV, boxB)], accUser)
        c.expect(parts(userLargest.r)?.v == userV && userLargest.embeds == [0] && userLargest.textures == [0],
                 "select: largest face matches → 1 embed, 1 texture (lazy: no extra cost)")

        let single = run([vec(colleagueV, boxA)], accUser)
        c.expect(parts(single.r)?.v == colleagueV && single.embeds == [0]
                 && parts(single.r)?.report == FaceSelectionReport(facesDetected: 1, facesEmbedded: 1, chosenRank: 0, accepted: false),
                 "select: one non-matching face → 1 embed, stranger vector")

        let largestOnly = run([vec(colleagueV, boxA), vec(userV, boxB)], .largestOnly)
        c.expect(parts(largestOnly.r)?.v == colleagueV && largestOnly.embeds == [0] && largestOnly.textures == [0],
                 "select: .largestOnly → never embeds #2 (presence-only paths, pre-ND-059 behaviour)")

        let failNoMatch = run([.failure, vec(colleagueV, boxB)], accUser)
        c.expect(isFailure(failNoMatch.r) && failNoMatch.embeds == [0, 1] && failNoMatch.textures.isEmpty,
                 "select: #0 embedding FAILED + #1 not the user → .failure (EC-10: never glitch → stranger)")
        let failMatch = run([.failure, vec(userV, boxB)], accUser)
        c.expect(parts(failMatch.r)?.v == userV && parts(failMatch.r)?.box == boxB,
                 "select: #0 failed + #1 is the user → the user (a match is a match)")
        c.expect(isFailure(run([.failure], accUser).r) && isFailure(run([.failure, .failure], accUser).r),
                 "select: failures only → .failure")

        let enroll2 = run([vec(userV, boxA), vec(colleagueV, boxB)], .enrollment)
        let enroll1 = run([vec(userV, boxA)], .enrollment)
        c.expect(isNoFace(enroll2.r) && enroll2.embeds.isEmpty && parts(enroll1.r)?.v == userV,
                 "select: .enrollment with 2 quality-passing faces → .noFace, nothing embedded; 1 face → embedded")
        c.expect(isNoFace(run([], accUser).r), "select: no candidate → .noFace")

        let flat = run([vec(colleagueV, boxA), vec(userV, boxB)], accUser, textures: [80, 3])
        c.expect(parts(flat.r)?.texture == 3,
                 "select: the texture score comes from the MATCHED face (a flat #2 photo stays flat)")
        c.expect(FaceSelection(maxFaces: 9, accepts: { _ in true }).maxFaces == 2
                 && FaceSelection(maxFaces: 0, accepts: { _ in true }).maxFaces == 1,
                 "select: FaceSelection.maxFaces clamped to 1...2")
    }

    // MARK: anyOfNFalseAcceptRate
    do {
        c.expect(abs(anyOfNFalseAcceptRate(perFaceFAR: 0.01, n: 2) - 0.0199) < 1e-12
                 && abs(anyOfNFalseAcceptRate(perFaceFAR: 0.01, n: 1) - 0.01) < 1e-12,
                 "FAR top-N: 1 − (1 − p)^n (1% per face → 1.99% for two strangers)")
        c.expect(anyOfNFalseAcceptRate(perFaceFAR: 0, n: 2) == 0 && anyOfNFalseAcceptRate(perFaceFAR: 1, n: 2) == 1
                 && anyOfNFalseAcceptRate(perFaceFAR: -0.3, n: 2) == 0 && anyOfNFalseAcceptRate(perFaceFAR: 4, n: 2) == 1,
                 "FAR top-N: clamped to 0...1")
        c.expect(anyOfNFalseAcceptRate(perFaceFAR: .nan, n: 2) == 1 && anyOfNFalseAcceptRate(perFaceFAR: 0.2, n: 0) == 0,
                 "FAR top-N: NaN → worst case 1; n < 1 → 0")
    }
}

/// ND-059 sub-phase 2: the embedder API forwards the selection.
@MainActor
func runMultiFaceEmbedderAPIChecks(_ c: Checks) async {
    print("\nND-059 embedder API (selection forwarding):")
    let presumed = FaceEmbeddingModelDescriptor.uniqueFake()
    // Loading path: a call made while the model loads forwards the selection once loaded.
    do {
        let gate = LoadGate()
        let real = FakeEmbedder(userV, descriptor: presumed)
        let d = DeferredFaceEmbedder(presumed: presumed, fallback: FakeEmbedder(otherV),
                                     load: { await gate.wait(); return real })
        let pending = Task { await d.embeddingWithLiveness(for: CapturedFrame(), selecting: .anyOfTop2 { _ in false }) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        gate.open()
        _ = await pending.value
        c.expect(real.lastSelection?.maxFaces == 2 && real.lastSelection?.requireSingleFace == false,
                 "Deferred: selection forwarded on the LOADING path (top-2 reaches the real embedder)")
        _ = await d.embeddingWithLiveness(for: CapturedFrame(), selecting: .enrollment)
        c.expect(real.lastSelection?.requireSingleFace == true,
                 "Deferred: selection forwarded on the RESOLVED path (enrollment's single-face rule)")
        _ = await d.embedding(for: CapturedFrame())
        c.expect(real.lastSelection?.maxFaces == 1 && real.lastSelection?.requireSingleFace == false,
                 "embedding(for:) / embeddingWithLiveness(for:) derive .largestOnly")
    }
    // The multi-face fake uses the production loop: largest-only by default.
    do {
        let big = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let small = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)
        let f = MultiFaceFakeEmbedder([.init(box: small, vector: userV), .init(box: big, vector: colleagueV)])
        let r = await f.embedding(for: CapturedFrame())
        var v: [Float]?
        if case let .embedding(x) = r { v = x }
        c.expect(v == colleagueV && f.embedCalls == 1 && f.textureCalls == 1,
                 "multi-face fake: .largestOnly embeds just the largest face (behaviour before ND-059)")
    }
}

/// Run with "Reject photos of me" ON/OFF (the recognizer reads `.standard`), then restore.
@MainActor
private func withAntiSpoofSetting(_ on: Bool, _ body: () async -> Void) async {
    let key = "antiSpoofEnabled"
    let prior = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(on, forKey: key)
    await body()
    if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
}

private let bigBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)       // colleague leaning in
private let smallBox = CGRect(x: 0.55, y: 0.3, width: 0.2, height: 0.27)   // the user, further back

private func enrolledUserStore() -> InMemoryEnrollmentStore {
    InMemoryEnrollmentStore(embeddings: [userV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
}

/// ND-059 sub-phase 3: the recognizer matches any of the top-2 faces.
@MainActor
func runMultiFaceRecognizerChecks(_ c: Checks) async {
    print("\nND-059 recognizer — match any of the top-2 faces (EC-06):")
    typealias F = MultiFaceFakeEmbedder.Face

    await withAntiSpoofSetting(true) {
        do {
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: userV)])
            let live = FakeLiveness(live: true)
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore(), liveness: live).recognize(CapturedFrame())
            c.expect(r == .enrolledUserPresent(confidence: 1.0) && e.embedCalls == 2 && e.textureCalls == 1,
                     "recognizer: colleague LARGER + user smaller → present (2 embeds, 1 texture)")
            c.expect(live.calls == 1 && live.lastBox == smallBox,
                     "recognizer: the liveness verdict is asked for the MATCHED (2nd) face's box")
        }
        do {
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: otherV)])
            let live = FakeLiveness(live: true)
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore(), liveness: live).recognize(CapturedFrame())
            c.expect(r == .strangerOnly && e.embedCalls == 2 && e.textureCalls == 1 && live.calls == 0,
                     "recognizer: two strangers → .strangerOnly (ADR-0017 fast lock kept), liveness not consulted")
        }
        do {
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: colleagueV)])
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore(), liveness: FakeLiveness(live: true)).recognize(CapturedFrame())
            c.expect(r == .enrolledUserPresent(confidence: 1.0) && e.embedCalls == 1 && e.textureCalls == 1,
                     "recognizer: user is the largest face → 1 embed, 1 texture (no extra cost)")
        }
        do {
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV)])
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore()).recognize(CapturedFrame())
            c.expect(r == .strangerOnly && e.embedCalls == 1, "recognizer: one non-matching face → 1 embed, stranger")
        }
        do {
            let e1 = MultiFaceFakeEmbedder([F(box: bigBox, vector: nil), F(box: smallBox, vector: colleagueV)])
            let r1 = await IdentityRecognizer(embedder: e1, store: enrolledUserStore()).recognize(CapturedFrame())
            let e2 = MultiFaceFakeEmbedder([F(box: bigBox, vector: nil), F(box: smallBox, vector: userV)])
            let r2 = await IdentityRecognizer(embedder: e2, store: enrolledUserStore(), liveness: FakeLiveness(live: true)).recognize(CapturedFrame())
            c.expect(r1 == .error("face embedding failed") && r2 == .enrolledUserPresent(confidence: 1.0),
                     "recognizer: largest face's embed FAILS + 2nd not the user → .error (EC-10 hold, never a stranger); 2nd is the user → present")
        }
        do {
            // The texture score is the MATCHED face's: a flat photo of the user as face #2
            // is flagged even though the larger (real) face is well textured.
            let flat = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV, texture: 80),
                                              F(box: smallBox, vector: userV, texture: 1)])
            let r1 = await IdentityRecognizer(embedder: flat, store: enrolledUserStore(), liveness: FakeLiveness(live: true)).recognize(CapturedFrame())
            let ok = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV, texture: 1),
                                            F(box: smallBox, vector: userV, texture: 80)])
            let r2 = await IdentityRecognizer(embedder: ok, store: enrolledUserStore(), liveness: FakeLiveness(live: true)).recognize(CapturedFrame())
            c.expect(r1 == .strangerOnly && r2 == .enrolledUserPresent(confidence: 1.0),
                     "recognizer: texture comes from the matched face (#2 flat → stranger; #1 flat, #2 textured → present)")
        }
        do {
            // Accepted delta (plan): a stranger holding the user's photo beside their face.
            // The photo matches as #2, is not live → .notLive (normal ~10 s absence).
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: userV)])
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore(), liveness: FakeLiveness(live: false)).recognize(CapturedFrame())
            c.expect(r == .notLive, "recognizer: stranger + photo of the user as #2 (not live) → .notLive")
        }
        do {
            let notEnrolled = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: userV)])
            let r1 = await IdentityRecognizer(embedder: notEnrolled, store: InMemoryEnrollmentStore()).recognize(CapturedFrame())
            let stale = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: userV)])
            let staleStore = InMemoryEnrollmentStore(embeddings: [userV], modelVersion: "some-other-model")
            let r2 = await IdentityRecognizer(embedder: stale, store: staleStore).recognize(CapturedFrame())
            c.expect(r1 == .enrolledUserPresent(confidence: 1.0) && notEnrolled.embedCalls == 1
                     && notEnrolled.lastSelection?.maxFaces == 1
                     && r2 == .enrolledUserPresent(confidence: 1.0) && stale.embedCalls == 1,
                     "recognizer: presence-only paths (not enrolled / model mismatch) stay largest-only → 1 embed")
        }
        do {
            // A tiny face never takes part, even as the only other face.
            let tiny = CGRect(x: 0.8, y: 0.8, width: 0.05, height: 0.05)
            let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: tiny, vector: userV)])
            let r = await IdentityRecognizer(embedder: e, store: enrolledUserStore()).recognize(CapturedFrame())
            c.expect(r == .strangerOnly && e.embedCalls == 1,
                     "recognizer: a 2nd face under the ND-085 size gate is never embedded")
        }
    }

    // Engine end to end: colleague leaning in (larger) while the user works → no lock.
    await withAntiSpoofSetting(true) {
        let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: userV)])
        let recognizer = IdentityRecognizer(embedder: e, store: enrolledUserStore(), liveness: FakeLiveness(live: true))
        let locker = SpyLocker(succeed: true)
        let engine = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        for i in 0..<10 { await engine.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 0 && engine.state == .present,
                 "engine: colleague larger + user in frame for 10 ticks → present, never locked (EC-06)")
        // Contrast (not vacuous): the user leaves, two strangers remain → fast stranger lock.
        e.faces = [F(box: bigBox, vector: colleagueV), F(box: smallBox, vector: otherV)]
        for i in 10..<16 { await engine.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 1, "engine: user leaves, two strangers remain → stranger lock still fires")
    }
}

/// ND-059 sub-phase 4: one liveness track per face.
@MainActor
func runMultiFaceLivenessChecks(_ c: Checks) async {
    print("\nND-059 liveness — per-face tracks:")
    let dt = 1.0 / 7
    let left = CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.4)
    let right = CGRect(x: 0.45, y: 0.3, width: 0.3, height: 0.4)       // IoU(left, right) = 0
    let middle = CGRect(x: 0.275, y: 0.3, width: 0.3, height: 0.4)     // IoU ≈ 0.26 with both

    c.expect(FaceTracker().maxTracks == 1 && FaceTracker(maxTracks: 7).maxTracks == 2
             && FaceTracker(maxTracks: 0).maxTracks == 1,
             "tracker: default maxTracks 1 (every single-track check above is unchanged); clamped 1...2")

    // Per-track separation: evidence on one face never counts for the other.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var ids: [Int: Int] = [:]
        var t = 0.0
        for i in 0..<70 {
            for a in tr.observe(faces: [(left, 70), (right, 70)], time: t) { ids[a.faceIndex] = a.trackID }
            if i == 10, let r = ids[1] { tr.recordEvidence(trackID: r, at: t) }
            t += dt
        }
        let vRight = tr.verdict(now: t, matchedBox: right, windowStart: nil)
        let vLeft = tr.verdict(now: t, matchedBox: left, windowStart: nil)
        c.expect(tr.tracks.count == 2 && tr.tracksStarted == 2 && ids[0] != ids[1]
                 && vRight.live && vRight.trackBound == true && !vLeft.live && vLeft.trackBound == true,
                 "tracker(2): two faces → two tracks; the user's evidence counts only for the user's face")
    }

    // Photo of the user held beside a live, blinking stranger for 60 s → never live.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var liveTicks = 0, ticks = 0
        for i in 0..<420 {
            let t = Double(i) * dt
            for a in tr.observe(faces: [(left, 70), (right, 70)], time: t) where a.faceIndex == 0 {
                tr.recordEvidence(trackID: a.trackID, at: t)                 // the stranger blinks / moves
            }
            if i % 7 == 1 {
                ticks += 1
                if tr.verdict(now: t, matchedBox: right, windowStart: nil).live { liveTicks += 1 }
            }
        }
        c.expect(ticks == 60 && liveTicks == 0,
                 "attack: photo of the user beside a live stranger, 60 s → never live (\(liveTicks)/\(ticks))")
    }

    // The existing alternating attacks (photo at the ticks, live stranger between),
    // replayed through the analyzer's 2-track tracker.
    do {
        let attacker = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)
        let phone = CGRect(x: 0.5, y: 0.3, width: 0.3, height: 0.4)
        for (label, photoBox, photoIOD) in [("side by side", phone, 70.0), ("same box, smaller photo", attacker, 50.0)] {
            var tr = FaceTracker(maxTracks: 2); var liveTicks = 0; var ticks = 0
            for i in 0..<420 {
                let t = Double(i) * dt
                let phase = i % 7
                if phase < 2 {
                    tr.observe(faces: [(photoBox, photoIOD)], time: t)
                    if phase == 1 {
                        ticks += 1
                        if tr.verdict(now: t, matchedBox: photoBox, windowStart: nil).live { liveTicks += 1 }
                    }
                } else {
                    for a in tr.observe(faces: [(attacker, 70)], time: t) { tr.recordEvidence(trackID: a.trackID, at: t) }
                }
            }
            c.expect(liveTicks == 0 && ticks == 60, "attack (\(label)) with 2 tracks: never live")
        }
    }

    // Ambiguity rule (unit): a face overlapping BOTH tracks retires them, no handoff.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var ids: [Int: Int] = [:]
        for a in tr.observe(faces: [(left, 70), (right, 70)], time: 0) { ids[a.faceIndex] = a.trackID }
        tr.recordEvidence(trackID: ids[0]!, at: 0)
        _ = tr.verdict(now: 0, matchedBox: left, windowStart: nil)          // verified + own evidence
        let a = tr.observe(faces: [(middle, 70)], time: dt)
        let v = tr.verdict(now: dt, matchedBox: middle, windowStart: nil)
        c.expect(a.count == 1 && a[0].trackBreak?.reason == .ambiguous && a[0].trackBreak?.handoff == TrackBreak.Handoff.none
                 && tr.tracks.count == 1 && tr.tracks[0].evidenceAt == nil && tr.tracks[0].probationUntil == nil
                 && tr.ambiguousBreaks == 1 && !v.live,
                 "ambiguity: a face overlapping two tracks → both retired, .ambiguous, no evidence or probation (verified user loses it — accepted cost)")
        var tr2 = FaceTracker(maxTracks: 2)
        tr2.observe(faces: [(middle, 70)], time: 0)
        tr2.recordEvidence(at: 0)
        let a2 = tr2.observe(faces: [(left, 70), (right, 70)], time: dt)
        c.expect(a2.count == 2 && a2.allSatisfy { $0.trackBreak?.reason == .ambiguous }
                 && tr2.tracks.allSatisfy { $0.evidenceAt == nil },
                 "ambiguity: a track overlapping two faces → retired; both faces start evidence-free tracks")
    }

    // Verdict binding: two fresh tracks both overlapping the matched box → unbound.
    do {
        let a = left.offsetBy(dx: 0.1, dy: 0), b = left.offsetBy(dx: 0.12, dy: 0)   // IoU ≈ 0.88
        var tr = FaceTracker(maxTracks: 2)
        let first = tr.observe(faces: [(a, 70), (b, 70)], time: 0)            // no prior tracks: both new
        if let other = first.first(where: { $0.faceIndex == 1 }) { tr.recordEvidence(trackID: other.trackID, at: 0) }
        let v = tr.verdict(now: 0.1, matchedBox: a, windowStart: nil)
        c.expect(tr.tracks.count == 2 && v.trackBound == false && !v.live,
                 "verdict: matched box nearly equally close to TWO fresh tracks → unbound, not live (which face matched is unknown)")
    }

    // Crossing: a live stranger and a photo of the user cross each other → the photo
    // never inherits the stranger's evidence.
    do {
        var tr = FaceTracker(maxTracks: 2)
        var liveTicks = 0
        var i = 0
        while Double(i) * dt < 8 {
            let t = Double(i) * dt
            let p = min(max((t - 2) / 4, 0), 1)                              // cross between 2 s and 6 s
            let strangerBox = left.offsetBy(dx: 0.35 * p, dy: 0)
            let photoBox = right.offsetBy(dx: -0.35 * p, dy: 0)
            for a in tr.observe(faces: [(strangerBox, 70), (photoBox, 70)], time: t) where a.faceIndex == 0 {
                tr.recordEvidence(trackID: a.trackID, at: t)
            }
            if i % 7 == 1, tr.verdict(now: t, matchedBox: photoBox, windowStart: nil).live { liveTicks += 1 }
            i += 1
        }
        c.expect(liveTicks == 0 && tr.ambiguousBreaks >= 1,
                 "attack: live stranger and a user photo cross → photo never live (live ticks \(liveTicks), ambiguous breaks \(tr.ambiguousBreaks))")
    }

    // Jostle (ND-059 review, KNOWN LIMIT — ADR-0023): equal-size faces trading places
    // frame to frame give the tracker the SAME boxes as two faces standing still; only
    // the input ORDER differs, which production can't use (the analyzer orders by area).
    // So no box rule can both keep a steady overlap continuous (a present user beside a
    // colleague) and refuse this; it is the overlapping case of the "same spot within
    // 1 s" hole, already open side by side. Pin what IS guaranteed: the tracker is
    // order-independent — the jostle and the steady pair get identical box→track maps.
    do {
        let a = left.offsetBy(dx: 0.1, dy: 0), b = left.offsetBy(dx: 0.28, dy: 0)   // IoU = 0.25
        var steady = FaceTracker(maxTracks: 2), jostle = FaceTracker(maxTracks: 2)
        var identical = true
        for i in 0..<140 {
            let t = Double(i) * dt
            let s = steady.observe(faces: [(a, 70), (b, 70)], time: t)
            let j = jostle.observe(faces: i % 2 == 0 ? [(a, 70), (b, 70)] : [(b, 70), (a, 70)], time: t)
            let sMap = [a: s.first { $0.faceIndex == 0 }?.trackID, b: s.first { $0.faceIndex == 1 }?.trackID]
            let jA = j.first { $0.faceIndex == (i % 2 == 0 ? 0 : 1) }?.trackID
            let jB = j.first { $0.faceIndex == (i % 2 == 0 ? 1 : 0) }?.trackID
            if sMap[a] != jA || sMap[b] != jB { identical = false }
        }
        c.expect(identical && steady.tracksStarted == 2 && jostle.tracksStarted == 2,
                 "tracker(2): order-independent — a frame-by-frame swap is indistinguishable from a steady pair (documented limit, ADR-0023)")
    }

    // Only the two largest faces are ever tracked.
    do {
        var tr = FaceTracker(maxTracks: 2)
        let third = CGRect(x: 0.8, y: 0.8, width: 0.15, height: 0.15)
        let a = tr.observe(faces: [(third, 40), (left, 70), (right, 60)], time: 0)
        c.expect(a.count == 2 && !a.contains { $0.faceIndex == 0 } && tr.tracks.count == 2
                 && !tr.verdict(now: 0, matchedBox: third, windowStart: nil).live,
                 "tracker(2): a 3rd (smallest) face is never tracked")
    }

    // Single face under the analyzer's 2-track tracker: on-device Test A still clean,
    // and the handoff rules are unchanged.
    do {
        let base = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
        func testA(_ maxTracks: Int) -> (notLive: Int, tracks: Int) {
            var tr = FaceTracker(maxTracks: maxTracks); var notLive = 0
            var i = 0; var t = 0.0; var nextTick = 0.5
            while t < 172 {
                var box = base.offsetBy(dx: 0.02 * sin(t), dy: 0)
                var iod = 70.0
                if abs(t - 110) < dt / 2 { iod = 95 }
                if t >= 110 + dt / 2 { iod = 72 }
                if t >= 112, t < 112.6 { box = box.offsetBy(dx: 0.17, dy: 0.05) }
                tr.observe(faces: [(box, iod)], time: t)
                if i % 70 == 5, !(t > 109 && t < 120) { tr.recordEvidence(at: t) }
                if t >= nextTick {
                    if !tr.verdict(now: t, matchedBox: box, windowStart: 0).live { notLive += 1 }
                    nextTick += 1
                }
                i += 1; t += dt
            }
            return (notLive, tr.tracksStarted)
        }
        let one = testA(1), two = testA(2)
        c.expect(one.notLive == 0 && two.notLive == 0 && one.tracks == two.tracks,
                 "tracker(2), one face: Test A regression identical to 1 track (never .notLive, \(two.tracks) tracks)")
        func handoff(_ maxTracks: Int, jump: CGFloat, iod: Double) -> TrackBreak.Handoff? {
            var tr = FaceTracker(maxTracks: maxTracks)
            tr.observe(faces: [(base, 70)], time: 0); tr.recordEvidence(at: 0)
            _ = tr.verdict(now: 0, matchedBox: base, windowStart: nil)
            return tr.observe(faces: [(base.offsetBy(dx: jump, dy: 0), iod)], time: dt).first?.trackBreak?.handoff
        }
        c.expect(handoff(1, jump: 0, iod: 95) == .fresh && handoff(2, jump: 0, iod: 95) == .fresh
                 && handoff(1, jump: 0.3, iod: 70) == TrackBreak.Handoff.none && handoff(2, jump: 0.3, iod: 70) == TrackBreak.Handoff.none,
                 "tracker(2), one face: handoff rules unchanged (scale break → fresh probation; jump elsewhere → none)")
    }

    // ND-118a start window: a second face never moves (or re-opens) it.
    do {
        var sw = LivenessStartWindow(); sw.begin(at: 0)
        var t = 5.0
        while t < 70 { sw.faceAnalyzed(at: t); t += dt }                    // once per frame with ≥ 1 face
        c.expect(sw.start == 5, "start window: a 2nd face joining later doesn't move the start (ND-118a unchanged)")
    }

    // Analyzer: beginWindow drops every track (and, on its queue, every track's detectors).
    do {
        let a = LivenessAnalyzer(antiSpoofEnabled: { true })
        a.beginWindow()
        let d = a.diagnostics()
        c.expect(d.activeTracks == 0 && d.framesWithTwoFaces == 0 && d.maxConcurrentTracks == 0 && d.lines.count == 6,
                 "analyzer: beginWindow → no tracks; two-face / concurrency counters in the existing diagnostics lines")
    }
}

/// ND-059 sub-phase 5: enrollment requires exactly one quality-passing face.
@MainActor
func runMultiFaceEnrollmentChecks(_ c: Checks) async {
    print("\nND-059 enrollment — one face only:")
    typealias F = MultiFaceFakeEmbedder.Face
    let frames = (0..<8).map { CapturedFrame(captureTime: TimeInterval(500 + $0)) }
    do {
        let clock = FakeClock()
        let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: smallBox, vector: colleagueV)])
        let store = InMemoryEnrollmentStore()
        let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: e, store: store,
                                             now: { clock.now }, sleep: { clock.advance($0) })
        c.expect(out == .notEnoughFaces && store.enrolledEmbeddings().isEmpty && e.embedCalls == 0
                 && e.lastSelection?.requireSingleFace == true,
                 "enrollment: every frame has 2 quality-passing faces → no vector added (.notEnoughFaces), nothing embedded")
    }
    do {
        let clock = FakeClock()
        let tiny = CGRect(x: 0.8, y: 0.8, width: 0.05, height: 0.05)
        let e = MultiFaceFakeEmbedder([F(box: bigBox, vector: userV), F(box: tiny, vector: colleagueV)])
        let store = InMemoryEnrollmentStore()
        let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: e, store: store,
                                             now: { clock.now }, sleep: { clock.advance($0) })
        c.expect(out == .success(count: 5) && store.enrolledEmbeddings().allSatisfy { $0 == userV },
                 "enrollment: a 2nd face too small for the ND-085 gate doesn't block enrolling the user")
    }
}
