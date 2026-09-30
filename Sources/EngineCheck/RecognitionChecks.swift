import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
import CoreML
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

// Shared fixtures for the recognition-core checks (hoisted from runAll()).
private let matchV: [Float] = [1, 0, 0, 0]
private let differentV: [Float] = [0, 1, 0, 0]  // orthogonal to matchV → cos 0 < threshold
private let threshold = FaceEmbeddingModelDescriptor.fakeTest.defaultMatchThreshold

/// Recognition core: cosine, identity recognizer, store (ND-021/024).
@MainActor
func runRecognitionCoreChecks(_ c: Checks) async {
    // MARK: - Recognition core (cooper): cosine, identity recognizer, store (ND-021/024)

    print("\nRecognition checks:")

    // cosineSimilarity — pure math.
    do {
        let a: [Float] = [1, 2, 3, 4]
        c.expect(abs(cosineSimilarity(a, a) - 1.0) < 1e-6, "cosine: identical vectors → ~1.0")
        c.expect(cosineSimilarity([1, 0], [0, 1]) == 0, "cosine: orthogonal [1,0]/[0,1] → 0")
        c.expect(cosineSimilarity([1, 2, 3], [1, 2]) == 0, "cosine: mismatched lengths → 0")
        c.expect(cosineSimilarity([], []) == 0, "cosine: empty → 0")
        c.expect(cosineSimilarity([0, 0], [1, 1]) == 0, "cosine: zero-norm vector → 0")
        c.expect(cosineSimilarity([Float.nan, 1], [1, 1]) == 0, "cosine: NaN component → 0 (corrupt blob, no match)")
        c.expect(cosineSimilarity([Float.infinity, 1], [1, 1]) == 0, "cosine: Inf component → 0")
    }

    // IdentityRecognizer with fake embedder + in-memory store.

    // (a) not enrolled + embedder returns a vector → present (presence-only fallback).
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "identity: not enrolled + face → present (presence-only fallback)")
    }

    // (b) not enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: not enrolled + no face → .noFace")
    }

    // (c) enrolled with V, embedder returns V → present, confidence >= threshold.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        if case let .enrolledUserPresent(confidence) = result {
            c.expect(confidence >= threshold, "identity: enrolled + matching → present, confidence >= threshold")
        } else {
            c.expect(false, "identity: enrolled + matching → present, confidence >= threshold")
        }
    }

    // (d) enrolled, embedder returns a very different vector (cos < threshold) → strangerOnly (EC-03).
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly, "identity: enrolled + non-matching face → .strangerOnly (EC-03)")
    }

    // (e) enrolled + embedder nil → noFace.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(nil), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .noFace, "identity: enrolled + no face → .noFace")
    }

    // (f) FAIL-SAFE: embedder .failure → .error (EC-10 hold), NOT .noFace/absence —
    // both when enrolled and when not enrolled. A transient Vision glitch must not
    // count toward the absence consensus and lock a present user.
    do {
        let notEnrolled = InMemoryEnrollmentStore()
        let r1 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: notEnrolled)
        let res1 = await r1.recognize(CapturedFrame())
        let enrolled = InMemoryEnrollmentStore()
        try? enrolled.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r2 = IdentityRecognizer(embedder: FakeEmbedder(.failure), store: enrolled)
        let res2 = await r2.recognize(CapturedFrame())
        c.expect(res1 == .error("face embedding failed") && res2 == .error("face embedding failed"),
                 "identity: embedder .failure → .error (EC-10 hold), never absence")
    }

    // (g) FAIL-SAFE (S1): store .unavailable (Keychain read failed) → .error even with a
    // face present — MUST NOT drop to presence-only (which would let any stranger pass).
    do {
        let store = InMemoryEnrollmentStore(embeddings: [matchV], simulateUnavailable: true)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .error("enrollment store unavailable"),
                 "identity: store .unavailable + face → .error (fail-safe, never presence-only) [S1]")
    }
}

/// Embedding versioning + forced re-enrollment (ADR-0014, ND-021).
@MainActor
func runEmbeddingVersioningChecks(_ c: Checks) async {
    // MARK: Embedding versioning + forced re-enrollment (ADR-0014, ND-021) — cooper

    // (v1) VERSION MISMATCH: an enrollment stored under a DIFFERENT model version than the
    // active embedder must NOT be cross-compared (unrelated embedding spaces). The
    // recognizer treats it as NOT enrolled for this model → presence-only fallback, forcing
    // re-enrollment — even with a face that would otherwise mismatch (differentV). If the
    // stale vectors were (wrongly) compared, differentV would score below threshold →
    // .strangerOnly; presence-only proves we skipped the cross-model compare.
    do {
        // Enrolled under an OLD model version; active embedder is `.fakeTest` (v1).
        let store = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0")
        let r = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "versioning: stored version != active model → re-enroll required (presence-only), never cross-compare (ADR-0014)")
    }

    // (v2) LEGACY (no-version) record: a pre-versioning enrollment (modelVersion nil) is
    // stale under ANY active versioned model → same forced re-enroll (presence-only),
    // never compared. Uses matchV (which WOULD match) to prove the version gate fires
    // BEFORE the cosine compare.
    do {
        let store = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: nil)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .enrolledUserPresent(confidence: 1.0),
                 "versioning: legacy no-version record → treated as stale, re-enroll required (ADR-0014)")
    }

    // (v3) VERSION MATCH still recognizes normally: enrolled under the ACTIVE version, a
    // matching face → present; a non-matching face → stranger. Proves the version gate
    // only blocks MISMATCHES, not the normal identity path.
    do {
        let matchStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let rMatch = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: matchStore)
        let matched = await rMatch.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = matched { present = true }
        let strangerStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let rStranger = IdentityRecognizer(embedder: FakeEmbedder(differentV), store: strangerStore)
        let stranger = await rStranger.recognize(CapturedFrame())
        c.expect(present && stranger == .strangerOnly,
                 "versioning: matching active version → normal identity (present / stranger), gate only blocks mismatch (ADR-0014)")
    }

    // (v4) DESCRIPTOR THRESHOLD plumbs through as the base default: build the recognizer
    // WITHOUT an explicit threshold, so it must use the embedder descriptor's
    // `defaultMatchThreshold`. Use a descriptor with a high threshold that a partial match
    // (cos ≈ 0.707) can't clear → stranger; then a descriptor with a low threshold the same
    // score clears → present. Proves descriptor.defaultMatchThreshold drives the decision.
    do {
        let partialV: [Float] = [1, 1, 0, 0]  // cos vs matchV=[1,0,0,0] = 1/sqrt(2) ≈ 0.707
        func desc(_ t: Double) -> FaceEmbeddingModelDescriptor {
            FaceEmbeddingModelDescriptor(version: "fake-test-v1", displayName: "d",
                                         inputSize: 0, outputDimension: 4,
                                         defaultMatchThreshold: t, matchThresholdRange: 0.40...0.90,
                                         thresholdIsTuned: false)
        }
        // High descriptor threshold (0.9): 0.707 < 0.9 → stranger.
        let highStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "fake-test-v1")
        let rHigh = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc(0.9)), store: highStore)
        let high = await rHigh.recognize(CapturedFrame())
        // Low descriptor threshold (0.5): 0.707 >= 0.5 → present.
        let lowStore = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "fake-test-v1")
        let rLow = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc(0.5)), store: lowStore)
        let low = await rLow.recognize(CapturedFrame())
        var presentLow = false
        if case .enrolledUserPresent = low { presentLow = true }
        c.expect(high == .strangerOnly && presentLow,
                 "descriptor threshold: no explicit threshold → descriptor.defaultMatchThreshold drives decision (0.9 → stranger, 0.5 → present) (ADR-0014)")
    }
}

/// Identity status surfacing (ND-073).
@MainActor
func runIdentityStatusChecks(_ c: Checks) async {
    // MARK: Identity status surfacing (ND-073) — cooper

    // (s1) Pure status table: every branch, including the nil legacy version and a marker
    // alongside a matching enrollment (still .active — the marker never downgrades).
    do {
        let active = FaceEmbeddingModelDescriptor.fakeTest.version
        let t1 = identityStatus(for: .enrolled([matchV], modelVersion: active), activeVersion: active, markerVersion: nil) == .active
        let t2 = identityStatus(for: .enrolled([matchV], modelVersion: active), activeVersion: active, markerVersion: active) == .active
        let t3 = identityStatus(for: .enrolled([matchV], modelVersion: "old-v0"), activeVersion: active, markerVersion: "old-v0")
            == .off(.modelMismatch(stored: "old-v0", active: active))
        let t4 = identityStatus(for: .enrolled([matchV], modelVersion: nil), activeVersion: active, markerVersion: nil)
            == .off(.modelMismatch(stored: nil, active: active))
        let t5 = identityStatus(for: .notEnrolled, activeVersion: active, markerVersion: nil) == .notEnrolled
        let t6 = identityStatus(for: .notEnrolled, activeVersion: active, markerVersion: active)
            == .off(.enrollmentMissing(expected: active))
        let t7 = identityStatus(for: .unavailable, activeVersion: active, markerVersion: active) == .unknown
        c.expect(t1 && t2, "identityStatus: enrolled + matching version → .active (marker irrelevant) (ND-073)")
        c.expect(t3, "identityStatus: enrolled + different version → .off(.modelMismatch) (ND-073)")
        c.expect(t4, "identityStatus: legacy nil-version record → .off(.modelMismatch(stored: nil)) (ND-073)")
        c.expect(t5, "identityStatus: not enrolled + no marker → .notEnrolled (ND-073)")
        c.expect(t6, "identityStatus: not enrolled + marker → .off(.enrollmentMissing) (ND-073)")
        c.expect(t7, "identityStatus: store .unavailable → .unknown (ND-073)")
        let flags = IdentityStatus.active.hasStoredEnrollment
            && IdentityStatus.off(.modelMismatch(stored: nil, active: active)).hasStoredEnrollment
            && !IdentityStatus.off(.enrollmentMissing(expected: active)).hasStoredEnrollment
            && !IdentityStatus.notEnrolled.hasStoredEnrollment && !IdentityStatus.unknown.hasStoredEnrollment
            && IdentityStatus.off(.enrollmentMissing(expected: active)).isOff
            && !IdentityStatus.active.isOff && !IdentityStatus.unknown.isOff
        c.expect(flags, "IdentityStatus: isOff / hasStoredEnrollment convenience flags (ND-073)")
    }

    // (s2) Recognizer publishes status from its per-tick read; results unchanged.
    do {
        let active = FaceEmbeddingModelDescriptor.fakeTest.version
        // Initial status before any tick.
        let fresh = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: InMemoryEnrollmentStore())
        c.expect(fresh.lastIdentityStatus == .unknown, "recognizer status: initial value .unknown (ND-073)")

        // Mismatch → .off(.modelMismatch), result still presence-only.
        let mm = IdentityRecognizer(embedder: FakeEmbedder(differentV),
                                    store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0"))
        let mmRes = await mm.recognize(CapturedFrame())
        c.expect(mm.lastIdentityStatus == .off(.modelMismatch(stored: "old-model-v0", active: active))
                    && mmRes == .enrolledUserPresent(confidence: 1.0),
                 "recognizer status: version mismatch → .off(.modelMismatch), result still presence-only (ND-073)")

        // Match → .active.
        let ok = IdentityRecognizer(embedder: FakeEmbedder(matchV),
                                    store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: active),
                                    marker: InMemoryEnrollmentMarker(active))
        _ = await ok.recognize(CapturedFrame())
        c.expect(ok.lastIdentityStatus == .active, "recognizer status: matching version → .active (ND-073)")

        // Marker + empty store → .off(.enrollmentMissing), result still presence-only.
        let missing = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: InMemoryEnrollmentStore(),
                                         marker: InMemoryEnrollmentMarker(active))
        let missRes = await missing.recognize(CapturedFrame())
        c.expect(missing.lastIdentityStatus == .off(.enrollmentMissing(expected: active))
                    && missRes == .enrolledUserPresent(confidence: 1.0),
                 "recognizer status: marker + empty store → .off(.enrollmentMissing), result still presence-only (ND-073)")

        // Status updates even when the embed yields no face (it comes from the store read).
        let noFace = IdentityRecognizer(embedder: FakeEmbedder(nil),
                                        store: InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: active))
        _ = await noFace.recognize(CapturedFrame())
        c.expect(noFace.lastIdentityStatus == .active, "recognizer status: published from store read even on .noFace (ND-073)")

        // .unavailable keeps the previous status (no flapping), result still .error.
        let flaky = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: "old-model-v0")
        let fr = IdentityRecognizer(embedder: FakeEmbedder(matchV), store: flaky)
        _ = await fr.recognize(CapturedFrame())
        flaky.setSimulateUnavailable(true)
        let frRes = await fr.recognize(CapturedFrame())
        c.expect(fr.lastIdentityStatus == .off(.modelMismatch(stored: "old-model-v0", active: active))
                    && frRes == .error("enrollment store unavailable"),
                 "recognizer status: store .unavailable keeps previous status (no flap), result .error (ND-073)")
    }

    // (s3) Marker round-trip (in-memory + UserDefaults on an isolated suite).
    do {
        let m = InMemoryEnrollmentMarker()
        let start = m.markerVersion == nil
        m.setMarker("v-a")
        let afterSet = m.markerVersion == "v-a"
        m.setMarker("v-b")
        let overwritten = m.markerVersion == "v-b"
        m.clearMarker()
        c.expect(start && afterSet && overwritten && m.markerVersion == nil,
                 "InMemoryEnrollmentMarker: nil → set → overwrite → clear round-trip (ND-073)")

        let suite = "com.nodonuts.enginecheck.marker"
        if let d = UserDefaults(suiteName: suite) {
            d.removePersistentDomain(forName: suite)
            let ud = UserDefaultsEnrollmentMarker(defaults: d)
            let s0 = ud.markerVersion == nil
            ud.setMarker("v-x")
            let s1 = ud.markerVersion == "v-x" && d.string(forKey: "enrollmentMarkerModelVersion") == "v-x"
            ud.clearMarker()
            c.expect(s0 && s1 && ud.markerVersion == nil,
                     "UserDefaultsEnrollmentMarker: set/clear round-trip under key enrollmentMarkerModelVersion (ND-073)")
            d.removePersistentDomain(forName: suite)
        } else {
            c.expect(false, "UserDefaultsEnrollmentMarker: isolated suite available")
        }
    }
}

/// Anti-spoofing (ND-041, EC-12) + live threshold (ND-040).
@MainActor
func runAntiSpoofChecks(_ c: Checks) async {
    // MARK: Anti-spoofing (ND-041, EC-12) + live threshold (ND-040) — cooper/wiggum

    // isLikelySpoof pure-function boundaries: strictly below floor → true; at/above → live.
    do {
        let floor = defaultSpoofTextureFloor
        let belowFlagged = isLikelySpoof(textureScore: floor - 0.01, floor: floor) == true
        let atFloorLive = isLikelySpoof(textureScore: floor, floor: floor) == false           // exactly-at → live
        let aboveLive = isLikelySpoof(textureScore: floor + 0.01, floor: floor) == false
        let zeroFlagged = isLikelySpoof(textureScore: 0, floor: floor) == true
        let hugeLive = isLikelySpoof(textureScore: 10_000, floor: floor) == false
        // .infinity sentinel (embedder returns it when anti-spoof is off / luminance
        // extraction failed) → treated as LIVE, never flagged (FIX #7 / EC-12).
        let infinityLive = isLikelySpoof(textureScore: .infinity, floor: floor) == false
        c.expect(belowFlagged && atFloorLive && aboveLive && zeroFlagged && hugeLive && infinityLive,
                 "isLikelySpoof: < floor → true (spoof); >= floor → false (live); .infinity → live (ND-041)")
    }

    // isLikelySpoof with a RESOLVED floor (FIX #6): a score below the resolved floor →
    // spoof; at/above → live; .infinity → live regardless. Uses a throwaway suite to
    // resolve a custom floor, proving the resolver + isLikelySpoof compose correctly.
    do {
        let suiteName = "com.nodonuts.enginecheck.floorpair.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "spoofTextureFloor"
            suite.set(50.0, forKey: key)
            let floor = resolvedSpoofTextureFloor(defaults: suite, key: key)   // 50.0
            let belowFlagged = isLikelySpoof(textureScore: 49.9, floor: floor) == true
            let atLive = isLikelySpoof(textureScore: 50.0, floor: floor) == false
            let aboveLive = isLikelySpoof(textureScore: 50.1, floor: floor) == false
            let infLive = isLikelySpoof(textureScore: .infinity, floor: floor) == false
            c.expect(floor == 50.0 && belowFlagged && atLive && aboveLive && infLive,
                     "isLikelySpoof + resolved floor (50): below → spoof, at/above → live, .infinity → live (ND-041/FIX#6)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "isLikelySpoof + resolved floor: throwaway suite unavailable, skipped")
        }
    }

    // faceTextureScore pure metric: a flat (uniform) crop scores 0; a high-contrast
    // checkerboard scores well above the floor — the metric actually separates them.
    do {
        let w = 8, h = 8
        let flat = [Double](repeating: 128, count: w * h)  // no texture at all
        var checker = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { checker[y * w + x] = ((x + y) % 2 == 0) ? 0 : 255 } }
        let flatScore = faceTextureScore(luminance: flat, width: w, height: h)
        let checkerScore = faceTextureScore(luminance: checker, width: w, height: h)
        c.expect(flatScore == 0 && checkerScore > defaultSpoofTextureFloor && isLikelySpoof(textureScore: flatScore) && !isLikelySpoof(textureScore: checkerScore),
                 "faceTextureScore: flat crop → 0 (spoof); checkerboard → high (live) (ND-041)")
    }

    // (h) enrolled + matching + LIVE (score above floor) + anti-spoof ON → present.
    do {
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // High texture score → clearly live.
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10_000), store: store)
        let result = await r.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = result { present = true }
        c.expect(present, "anti-spoof: enrolled + matching + live → present (ND-041)")
    }

    // (i) enrolled + matching + FLAGGED (score below floor) + anti-spoof ON → strangerOnly.
    // Uses a throwaway UserDefaults suite as the SOURCE OF TRUTH by pointing the
    // process default at it — but the recognizer reads `.standard`, so we set the key
    // on `.standard` and restore it, keeping the check hermetic.
    do {
        let key = "antiSpoofEnabled"
        let floorKey = "spoofTextureFloor"
        let hadValue = UserDefaults.standard.object(forKey: key) != nil
        let prior = UserDefaults.standard.object(forKey: key)
        let hadFloor = UserDefaults.standard.object(forKey: floorKey) != nil
        let priorFloor = UserDefaults.standard.object(forKey: floorKey)
        UserDefaults.standard.set(true, forKey: key)          // explicitly ON
        UserDefaults.standard.set(100.0, forKey: floorKey)    // FIX #6: floor via defaults, resolved per call
        defer {
            if hadValue { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            if hadFloor { UserDefaults.standard.set(priorFloor, forKey: floorKey) }
            else { UserDefaults.standard.removeObject(forKey: floorKey) }
        }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        // Texture score BELOW the resolved floor (10 < 100) → flagged as spoof. Proves
        // the recognizer uses the LIVE resolved floor, not the hardcoded default.
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 10), store: store)
        let result = await r.recognize(CapturedFrame())
        c.expect(result == .strangerOnly,
                 "anti-spoof: enrolled + matching + flat + enabled (resolved floor 100) → .strangerOnly (ND-041/EC-12/FIX#6)")
    }

    // (j) enrolled + matching + FLAGGED + anti-spoof OFF → present (toggle off ignores).
    do {
        let key = "antiSpoofEnabled"
        let hadValue = UserDefaults.standard.object(forKey: key) != nil
        let prior = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)   // toggle OFF
        defer {
            if hadValue { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let r = IdentityRecognizer(embedder: FakeEmbedder(matchV, textureScore: 0), store: store)
        let result = await r.recognize(CapturedFrame())
        var present = false
        if case .enrolledUserPresent = result { present = true }
        c.expect(present, "anti-spoof: flagged but toggle OFF → present (ignores anti-spoof) (ND-041)")
    }
}

/// Inner-face liveness helper (ND-072), crop geometry, resolved settings (ND-040/076).
@MainActor
func runLivenessAndRecognitionSettingsChecks(_ c: Checks) async {
    // MARK: Shared inner-face liveness helper (ND-072, EC-12) — cooper/wiggum
    //
    // Both embedders now score liveness through ONE helper on the ORIGINAL frame's inner
    // face region. Synthetic BGRA frames (160×160, face box = central half → 120px padded
    // crop, 80px core: below the 128px working size, so no resample blurs the pattern).
    do {
        let side = 160
        let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let ctx = CIContext(options: nil)
        var seed: UInt32 = 0x9E37_79B9
        func noise() -> UInt8 { seed = seed &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: seed >> 24) }
        let flat = makeGrayBGRAFrame(width: side, height: side) { _, _ in 128 }
        let checker = makeGrayBGRAFrame(width: side, height: side) { x, y in ((x / 3 + y / 3) % 2 == 0) ? 30 : 220 }
        let noisy = makeGrayBGRAFrame(width: side, height: side) { _, _ in noise() }

        if let flat, let checker, let noisy {
            let flatScore = innerFaceTextureScore(frame: flat, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            let checkerScore = innerFaceTextureScore(frame: checker, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            let noiseScore = innerFaceTextureScore(frame: noisy, faceBoundingBox: face, orientation: .up, ciContext: ctx)
            c.expect(flatScore.isFinite && isLikelySpoof(textureScore: flatScore),
                     "innerFaceTextureScore: flat frame → low finite score (\(flatScore)) → spoof at default floor (ND-072)")
            c.expect(checkerScore.isFinite && checkerScore > defaultSpoofTextureFloor * 10,
                     "innerFaceTextureScore: checkerboard frame → high score (\(checkerScore)) → live (ND-072)")
            c.expect(noiseScore.isFinite && noiseScore > defaultSpoofTextureFloor * 10,
                     "innerFaceTextureScore: noise frame → high score (\(noiseScore)) → live (ND-072)")

            // Rotated source orientation (same one detection used) still extracts + scores.
            let rotated = innerFaceTextureScore(frame: checker, faceBoundingBox: face, orientation: .right, ciContext: ctx)
            c.expect(rotated.isFinite && rotated > defaultSpoofTextureFloor,
                     "innerFaceTextureScore: non-.up orientation → still scores the face region (ND-072)")

            // Same pixels as the Vision path: the frame-based helper == the Vision
            // embedder's call (faceCoreTextureScore on its rendered padded crop). This is
            // what keeps the floor on one scale across both embedders.
            var samePixels = false
            let ci = CIImage(cvPixelBuffer: noisy).oriented(.up)
            if let rect = paddedFaceCropRect(faceBoundingBox: face, paddingFraction: 0.25, orientedExtent: ci.extent),
               let cg = ctx.createCGImage(ci.cropped(to: rect), from: rect),
               let visionPath = faceCoreTextureScore(paddedCrop: cg, paddingFraction: 0.25) {
                samePixels = visionPath == noiseScore
            }
            c.expect(samePixels, "innerFaceTextureScore == Vision-path faceCoreTextureScore on the same frame (one scale, ND-072)")

            // Extraction failures / ambiguity → .infinity (LIVE), never a spoof (EC-12).
            let zeroBox = innerFaceTextureScore(frame: flat, faceBoundingBox: .zero, orientation: .up, ciContext: ctx)
            let nanBox = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: .nan, y: 0.2, width: 0.5, height: 0.5),
                                               orientation: .up, ciContext: ctx)
            let offFrame = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: 2, y: 2, width: 0.5, height: 0.5),
                                                 orientation: .up, ciContext: ctx)
            let tiny = innerFaceTextureScore(frame: flat, faceBoundingBox: CGRect(x: 0.5, y: 0.5, width: 0.004, height: 0.004),
                                             orientation: .up, ciContext: ctx)
            let badPad = innerFaceTextureScore(frame: flat, faceBoundingBox: face, orientation: .up,
                                               paddingFraction: -1, ciContext: ctx)
            c.expect(zeroBox == .infinity && nanBox == .infinity && offFrame == .infinity && tiny == .infinity && badPad == .infinity,
                     "innerFaceTextureScore: empty/NaN/off-frame/tiny box or bad padding → .infinity (live, never spoof) (ND-072/EC-12)")

            // Core-ML-style outcome into the REAL recognizer gate at the DEFAULT floor (12):
            // the helper's flat-frame score trips it (→ .strangerOnly); its textured score
            // and the .infinity failure sentinel do not (→ present).
            let key = "antiSpoofEnabled", floorKey = "spoofTextureFloor"
            let prior = UserDefaults.standard.object(forKey: key)
            let priorFloor = UserDefaults.standard.object(forKey: floorKey)
            UserDefaults.standard.set(true, forKey: key)
            UserDefaults.standard.removeObject(forKey: floorKey)   // → defaultSpoofTextureFloor
            defer {
                if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                if let priorFloor { UserDefaults.standard.set(priorFloor, forKey: floorKey) }
            }
            let desc = FaceEmbeddingModelDescriptor.uniqueFake()
            let store = InMemoryEnrollmentStore()
            try? store.enroll(embeddings: [matchV], modelVersion: desc.version)
            func gate(_ score: Double) async -> RecognitionResult {
                await IdentityRecognizer(embedder: FakeEmbedder(result: .embedding(matchV, textureScore: score), descriptor: desc),
                                         store: store).recognize(CapturedFrame())
            }
            let flatResult = await gate(flatScore)
            var texturedPresent = false, failurePresent = false
            if case .enrolledUserPresent = await gate(noiseScore) { texturedPresent = true }
            if case .enrolledUserPresent = await gate(zeroBox) { failurePresent = true }
            c.expect(flatResult == .strangerOnly && texturedPresent && failurePresent,
                     "anti-spoof gate on Core-ML-style scores (default floor): flat → .strangerOnly; textured / .infinity → present (ND-072)")
        } else {
            c.expect(false, "innerFaceTextureScore: could not allocate synthetic CVPixelBuffers")
        }
    }

    // Shared padded-crop geometry (both embedders' crop + the liveness helper): the exact
    // arithmetic the embedders used inline before ND-072 (regression guard).
    do {
        let extent = CGRect(x: 0, y: 0, width: 160, height: 160)
        let centered = paddedFaceCropRect(faceBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                                          paddingFraction: 0.25, orientedExtent: extent)
        let edge = paddedFaceCropRect(faceBoundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                      paddingFraction: 0.25, orientedExtent: extent)
        let off = paddedFaceCropRect(faceBoundingBox: CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
                                     paddingFraction: 0.25, orientedExtent: extent)
        c.expect(centered == CGRect(x: 20, y: 20, width: 120, height: 120)
                 && edge == CGRect(x: 0, y: 0, width: 100, height: 100) && off == nil,
                 "paddedFaceCropRect: 0.25 padding, [0,1] clamp at the edge, off-frame → nil (ND-072 regression)")
    }

    // (k) resolvedAntiSpoofEnabled default: absent key → true (ON by default); explicit
    // false → false. Throwaway suite, cleaned up.
    do {
        let suiteName = "com.nodonuts.enginecheck.antispoof.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "antiSpoofEnabled"
            let absentOn = resolvedAntiSpoofEnabled(defaults: suite, key: key) == true
            suite.set(false, forKey: key)
            let explicitOff = resolvedAntiSpoofEnabled(defaults: suite, key: key) == false
            suite.set(true, forKey: key)
            let explicitOn = resolvedAntiSpoofEnabled(defaults: suite, key: key) == true
            c.expect(absentOn && explicitOff && explicitOn,
                     "resolvedAntiSpoofEnabled: absent → ON; false → off; true → on (ND-041)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedAntiSpoofEnabled: throwaway suite unavailable, skipped")
        }
    }

    // (l) LIVE per-model threshold (ND-040 / ND-076): with the active model's per-model key
    // set on defaults, the recognizer resolves it PER CALL. The recognizer reads `.standard`
    // (EngineCheck's own domain, never com.nodonuts.app); a UNIQUE-version descriptor makes
    // the key guaranteed-fresh, and it is removed afterwards.
    do {
        let desc = FaceEmbeddingModelDescriptor.uniqueFake()
        let key = desc.thresholdOverrideKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = InMemoryEnrollmentStore()
        try? store.enroll(embeddings: [matchV], modelVersion: desc.version)
        let partialV: [Float] = [1, 1, 0, 0]  // cos(matchV=[1,0,0,0]) = 1/sqrt(2) ≈ 0.707
        let r = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: desc), store: store)
        UserDefaults.standard.set(0.5, forKey: key)   // 0.707 >= 0.5 → present
        let below = await r.recognize(CapturedFrame())
        var presentBelow = false
        if case .enrolledUserPresent = below { presentBelow = true }
        UserDefaults.standard.set(0.9, forKey: key)   // 0.707 < 0.9 → stranger (live change applied)
        let above = await r.recognize(CapturedFrame())
        let strangerAbove = above == .strangerOnly
        // An OUT-OF-RANGE 0.95 (above the 0.90 ceiling) is REJECTED → descriptor default 0.6
        // → present. A clamp to 0.90 would have given stranger, so this proves reject-not-clamp.
        UserDefaults.standard.set(0.95, forKey: key)
        let rejectedHigh = await r.recognize(CapturedFrame())
        var presentRejectedHigh = false
        if case .enrolledUserPresent = rejectedHigh { presentRejectedHigh = true }
        c.expect(presentBelow && strangerAbove && presentRejectedHigh,
                 "live threshold: recognizer resolves per-model key per call — 0.5 → present, 0.9 → stranger, 0.95 (out of range) rejected → default, not clamped (ND-040/ND-076)")
    }

    // (l2) NO OVERRIDE → descriptor default (ND-076): a fresh per-model key is absent, so the
    // recognizer must use `descriptor.defaultMatchThreshold` — nothing else (no Config, no
    // init param). 0.707 vs default 0.8 → stranger; vs default 0.7 → present.
    do {
        let partialV: [Float] = [1, 1, 0, 0]
        let strict = FaceEmbeddingModelDescriptor.uniqueFake(defaultMatchThreshold: 0.8)
        let lenient = FaceEmbeddingModelDescriptor.uniqueFake(defaultMatchThreshold: 0.7)
        let s1 = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: strict.version)
        let s2 = InMemoryEnrollmentStore(embeddings: [matchV], modelVersion: lenient.version)
        let rStrict = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: strict), store: s1)
        let rLenient = IdentityRecognizer(embedder: FakeEmbedder(partialV, descriptor: lenient), store: s2)
        let strictResult = await rStrict.recognize(CapturedFrame())
        let lenientResult = await rLenient.recognize(CapturedFrame())
        var lenientPresent = false
        if case .enrolledUserPresent = lenientResult { lenientPresent = true }
        c.expect(UserDefaults.standard.object(forKey: strict.thresholdOverrideKey) == nil
                 && strictResult == .strangerOnly && lenientPresent,
                 "identity: no per-model override → descriptor.defaultMatchThreshold is the sole default (0.8 → stranger, 0.7 → present at cos 0.707) (ND-076)")
    }

    // InMemoryEnrollmentStore round-trip + enrollmentState transitions.
    do {
        let store = InMemoryEnrollmentStore()
        let notEnrolledInitially = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        try? store.enroll(embeddings: [matchV], modelVersion: FaceEmbeddingModelDescriptor.fakeTest.version)
        let enrolledAfter = store.isEnrolled && store.enrolledEmbeddings() == [matchV] && isEnrolledState(store.enrollmentState())
        try? store.reset()
        let notEnrolledAfterReset = !store.isEnrolled && isNotEnrolled(store.enrollmentState())
        c.expect(notEnrolledInitially && enrolledAfter && notEnrolledAfterReset,
                 "InMemoryEnrollmentStore: enrollmentState notEnrolled → enrolled → reset round-trip")
    }

    // resolvedVisionOrientation fallback (cooper). Uses a throwaway UserDefaults
    // suite (like the TrustedNetworksStore check) so it never touches real prefs.
    // Default (key absent) → .up; out-of-range (99) → .up; valid 6 → .right.
    do {
        let suiteName = "com.nodonuts.enginecheck.orientation.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "visionOrientation"
            // Absent → .up
            let absentUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Out-of-range rawValue → .up
            suite.set(99, forKey: key)
            let outOfRangeUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Zero (invalid rawValue) → .up
            suite.set(0, forKey: key)
            let zeroUp = resolvedVisionOrientation(defaults: suite, key: key) == .up
            // Valid 6 → .right
            suite.set(6, forKey: key)
            let sixRight = resolvedVisionOrientation(defaults: suite, key: key) == .right
            c.expect(absentUp && outOfRangeUp && zeroUp && sixRight,
                     "resolvedVisionOrientation: absent/out-of-range/0 → .up; 6 → .right")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            // Couldn't make a throwaway suite — don't touch .standard; skip cleanly.
            c.expect(true, "resolvedVisionOrientation: throwaway suite unavailable, skipped")
        }
    }

    // resolvedMatchThreshold(for:) validation (cooper, ND-076). Throwaway UserDefaults
    // suite so it never touches real prefs. Reads ONLY the model's per-model key; accepts
    // only a number inside `descriptor.matchThresholdRange`; absent / non-number / out of
    // range → descriptor default (REJECT, never clamp).
    do {
        let suiteName = "com.nodonuts.enginecheck.threshold.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
            let vi = FaceEmbeddingModelDescriptor.visionFeaturePrint
            let key = fn.thresholdOverrideKey
            c.expect(key == "matchThreshold.facenet-vggface2-v2"
                     && vi.thresholdOverrideKey == "matchThreshold.vision-featureprint-v1",
                     "thresholdOverrideKey: per-model \"matchThreshold.<version>\" (ND-076)")
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold,
                     "resolvedMatchThreshold: absent → descriptor default (0.5 FaceNet)")
            suite.set(0.6, forKey: key)
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == 0.6,
                     "resolvedMatchThreshold: in-range 0.6 → 0.6")
            suite.set(0.40, forKey: key)
            let floorOK = resolvedMatchThreshold(for: fn, defaults: suite) == 0.40
            suite.set(0.90, forKey: key)
            let ceilOK = resolvedMatchThreshold(for: fn, defaults: suite) == 0.90
            c.expect(floorOK && ceilOK, "resolvedMatchThreshold: range bounds 0.40 / 0.90 inclusive → accepted")
            suite.set(0.39, forKey: key)
            c.expect(resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold,
                     "resolvedMatchThreshold: 0.39 below FaceNet floor → default (rejected, not clamped to 0.40)")
            suite.set(0.01, forKey: key)
            let injectedLow = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(0.0, forKey: key)
            let zero = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(-0.5, forKey: key)
            let negative = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(Double.nan, forKey: key)
            let nan = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(injectedLow && zero && negative && nan,
                     "resolvedMatchThreshold: 0.01 / 0 / negative / NaN → default (fail-open overrides rejected)")
            suite.set(0.95, forKey: key)
            let above = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(1.0, forKey: key)
            let one = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(above && one, "resolvedMatchThreshold: 0.95 above FaceNet ceiling / 1.0 → default (rejected, not clamped)")
            suite.set("0.7", forKey: key)
            let str = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            suite.set(true, forKey: key)
            let bool = resolvedMatchThreshold(for: fn, defaults: suite) == fn.defaultMatchThreshold
            c.expect(str && bool, "resolvedMatchThreshold: non-number (String / Bool) → default")
            // Per-model isolation: a FaceNet override never bleeds into the Vision model,
            // and the legacy global key is ignored by the resolver.
            suite.set(0.8, forKey: key)
            suite.set(0.45, forKey: legacyMatchThresholdKey)
            c.expect(resolvedMatchThreshold(for: vi, defaults: suite) == vi.defaultMatchThreshold
                     && resolvedMatchThreshold(for: fn, defaults: suite) == 0.8,
                     "resolvedMatchThreshold: FaceNet key doesn't affect Vision; legacy global key ignored (ND-076)")
            // Vision accepts up to its own 0.95 ceiling (per-model range).
            suite.set(0.95, forKey: vi.thresholdOverrideKey)
            c.expect(resolvedMatchThreshold(for: vi, defaults: suite) == 0.95,
                     "resolvedMatchThreshold: Vision 0.95 in its own range → accepted (ranges are per-model)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedMatchThreshold: throwaway suite unavailable, skipped")
        }
    }

    // Descriptor ranges contain their defaults (ND-076) — and the FaceNet floor is 0.40.
    do {
        let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
        let vi = FaceEmbeddingModelDescriptor.visionFeaturePrint
        c.expect(fn.matchThresholdRange == 0.40...0.90 && fn.matchThresholdRange.contains(fn.defaultMatchThreshold)
                 && vi.matchThresholdRange == 0.40...0.95 && vi.matchThresholdRange.contains(vi.defaultMatchThreshold)
                 && vi.defaultMatchThreshold == 0.6,
                 "descriptors: FaceNet 0.40...0.90 ∋ 0.5; Vision 0.40...0.95 ∋ 0.6 (ND-076)")
    }

    // dropLegacyMatchThresholdKey (ND-076): returns the old numeric value and removes the
    // key; absent → nil; non-numeric → nil but still removed. Throwaway suite.
    do {
        let suiteName = "com.nodonuts.enginecheck.legacythreshold.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let absent = dropLegacyMatchThresholdKey(defaults: suite) == nil
            suite.set(0.5, forKey: legacyMatchThresholdKey)
            suite.set(0.7, forKey: FaceEmbeddingModelDescriptor.facenetVGGFace2.thresholdOverrideKey)
            let dropped = dropLegacyMatchThresholdKey(defaults: suite)
            let removed = suite.object(forKey: legacyMatchThresholdKey) == nil
            let perModelKept = suite.double(forKey: FaceEmbeddingModelDescriptor.facenetVGGFace2.thresholdOverrideKey) == 0.7
            let second = dropLegacyMatchThresholdKey(defaults: suite) == nil
            suite.set("junk", forKey: legacyMatchThresholdKey)
            let junk = dropLegacyMatchThresholdKey(defaults: suite) == nil
                && suite.object(forKey: legacyMatchThresholdKey) == nil
            c.expect(absent && dropped == 0.5 && removed && perModelKept && second && junk,
                     "dropLegacyMatchThresholdKey: returns 0.5 + removes key, per-model key kept, idempotent, junk removed → nil (ND-076)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "dropLegacyMatchThresholdKey: throwaway suite unavailable, skipped")
        }
    }

    // resolvedSpoofTextureFloor validation (cooper, FIX #6). Throwaway UserDefaults
    // suite so it never touches real prefs. Absent / 0 / negative / NaN / non-numeric
    // → default; only a finite strictly-positive number is accepted. Mirrors the other
    // resolvers; lets the floor be tuned live via `defaults write ... spoofTextureFloor`.
    do {
        let suiteName = "com.nodonuts.enginecheck.spooffloor.\(UUID().uuidString)"
        if let suite = UserDefaults(suiteName: suiteName) {
            let key = "spoofTextureFloor"
            let def = defaultSpoofTextureFloor   // 12.0
            // Absent → default
            let absentDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // 0.0 → default (a zero floor can never flag; treat as junk)
            suite.set(0.0, forKey: key)
            let zeroDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Negative → default
            suite.set(-5.0, forKey: key)
            let negativeDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // NaN → default
            suite.set(Double.nan, forKey: key)
            let nanDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Infinity → default
            suite.set(Double.infinity, forKey: key)
            let infDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Non-numeric (a stored String) → default
            suite.set("nope", forKey: key)
            let stringDefault = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == def
            // Valid positive → that value
            suite.set(25.0, forKey: key)
            let validAccepted = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == 25.0
            // Tiny positive (the "effectively disable" escape hatch) → accepted
            suite.set(0.0001, forKey: key)
            let tinyAccepted = resolvedSpoofTextureFloor(default: def, defaults: suite, key: key) == 0.0001
            c.expect(absentDefault && zeroDefault && negativeDefault && nanDefault && infDefault
                     && stringDefault && validAccepted && tinyAccepted,
                     "resolvedSpoofTextureFloor: absent/0/negative/NaN/inf/non-numeric → default; positive → that (ND-041/FIX#6)")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        } else {
            c.expect(true, "resolvedSpoofTextureFloor: throwaway suite unavailable, skipped")
        }
    }
}

/// ND-056 / ND-021 Phase 2 — threshold analysis.
@MainActor
func runThresholdAnalysisChecks(_ c: Checks) async {
    // MARK: ND-056 / ND-021 Phase 2 — threshold analysis (ThresholdAnalysis.swift)
    //
    // These back the FaceScore harness's recommendation. A shipped `matchThreshold` is a
    // security parameter, so the arithmetic under it is pinned here.
    do {
        // Percentiles are nearest-rank over SORTED input, and the input need not arrive
        // sorted (FaceScore appends scores in directory order).
        let d = ScoreDistribution([0.9, 0.1, 0.5, 0.7, 0.3])
        let basics = d.count == 5 && d.minimum == 0.1 && d.maximum == 0.9
            && d.sorted == [0.1, 0.3, 0.5, 0.7, 0.9]
        let meanOK = (d.mean.map { abs($0 - 0.5) < 1e-9 }) ?? false
        // Nearest-rank: p50 of 5 samples → index floor(0.5*5)=2 → 0.5.
        let percentileOK = d.percentile(0.5) == 0.5 && d.percentile(0.0) == 0.1 && d.percentile(1.0) == 0.9
        c.expect(basics && meanOK && percentileOK,
                 "ScoreDistribution: sorts unsorted input; min/max/mean/nearest-rank percentiles")

        // Empty → nil everywhere, never a NaN that could be mistaken for a real statistic.
        let empty = ScoreDistribution([])
        c.expect(empty.isEmpty && empty.minimum == nil && empty.maximum == nil
                 && empty.mean == nil && empty.standardDeviation == nil && empty.percentile(0.5) == nil,
                 "ScoreDistribution: empty set → nil statistics (never NaN)")

        // Single sample → spread is undefined, not zero.
        c.expect(ScoreDistribution([0.42]).standardDeviation == nil,
                 "ScoreDistribution: single sample → nil standard deviation")
    }

    do {
        // FRR/FAR must mirror IdentityRecognizer's `maxSim >= threshold` accept test
        // EXACTLY: a score EQUAL to the threshold is accepted, so it is not a false
        // reject, and it IS a false accept. An off-by-one here biases every recommendation.
        let genuine = ScoreDistribution([0.4, 0.5, 0.6])
        let impostor = ScoreDistribution([0.2, 0.5, 0.8])
        let frr = falseRejectRate(genuine: genuine, at: 0.5)
        let far = falseAcceptRate(impostor: impostor, at: 0.5)
        let boundaryOK = (frr.map { abs($0 - 1.0 / 3.0) < 1e-9 }) ?? false
            && (far.map { abs($0 - 2.0 / 3.0) < 1e-9 }) ?? false
        c.expect(boundaryOK, "FRR/FAR: score == threshold is ACCEPTED, matching IdentityRecognizer's >=")

        // Empty class → nil, so a missing class can never read as "0% error".
        c.expect(falseRejectRate(genuine: ScoreDistribution([]), at: 0.5) == nil
                 && falseAcceptRate(impostor: ScoreDistribution([]), at: 0.5) == nil,
                 "FRR/FAR: empty class → nil (never a spurious 0%)")
    }

    do {
        // Deterministic synthetic score sets that clear (or deliberately miss) the
        // ND-094 evidence bar. `spread(n, from:, to:)` = n evenly spaced scores.
        func spread(_ n: Int, from lo: Double, to hi: Double) -> [Double] {
            guard n > 1 else { return n == 1 ? [lo] : [] }
            return (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
        }
        let req = ThresholdStudyRequirements.standard
        c.expect(req.minimumGenuineSamples == 30 && req.minimumImpostorSamples == 30
                 && req.minimumImpostorIdentities == 2 && abs(req.minimumSeparationMargin - 0.05) < 1e-12,
                 "ThresholdStudyRequirements.standard: 30 genuine, 30 impostor, 2 identities, 0.05 margin (ND-094)")

        func shortfalls(_ r: ThresholdRecommendation) -> [ThresholdShortfall] {
            if case let .insufficientData(_, s) = r { return s }
            return []
        }

        // Genuine-only data — the exact state this project was in before FaceScore —
        // must be refused, not turned into a number.
        let genuineOnly = recommendThreshold(
            genuine: ScoreDistribution(spread(40, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution([]),
            impostorIdentityCount: 0
        )
        var refusedGenuineOnly = false
        if case let .insufficientData(reason, _) = genuineOnly {
            refusedGenuineOnly = reason.contains("genuine-only")
        }
        c.expect(refusedGenuineOnly && !genuineOnly.justifiesTunedFlag && genuineOnly.refusalReason != nil,
                 "recommendThreshold: genuine-only data → insufficientData, never a threshold (ND-056)")

        // PASSING case: 30 genuine in [0.80, 0.95], 30 impostor in [0.20, 0.60] from 3
        // people → margin 0.20, midpoint 0.70, and it justifies thresholdIsTuned.
        let separated = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        var separationOK = false
        if case let .cleanSeparation(threshold, margin, impostorMaximum, genuineMinimum) = separated {
            separationOK = abs(threshold - 0.70) < 1e-9 && abs(margin - 0.20) < 1e-9
                && abs(impostorMaximum - 0.60) < 1e-9 && abs(genuineMinimum - 0.80) < 1e-9
        }
        c.expect(separationOK && separated.justifiesTunedFlag && separated.refusalReason == nil,
                 "recommendThreshold: 30+30 samples, 3 impostors, margin 0.20 → gap midpoint, justifies thresholdIsTuned")

        // ND-094 regression: the OLD verdict endorsed "clean separation" from 1+1 samples.
        let tiny = recommendThreshold(
            genuine: ScoreDistribution([0.90]),
            impostor: ScoreDistribution([0.20]),
            impostorIdentityCount: 2
        )
        c.expect(!tiny.justifiesTunedFlag
                 && shortfalls(tiny).contains(.genuineSamples(have: 1, need: 30))
                 && shortfalls(tiny).contains(.impostorSamples(have: 1, need: 30)),
                 "recommendThreshold: 1 genuine + 1 impostor, cleanly apart → REFUSED with both count shortfalls (ND-094)")

        // Each criterion refuses on its own, and names itself with the amount short.
        let fewGenuine = recommendThreshold(
            genuine: ScoreDistribution(spread(29, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        c.expect(shortfalls(fewGenuine) == [.genuineSamples(have: 29, need: 30)] && !fewGenuine.justifiesTunedFlag
                 && (fewGenuine.refusalReason?.contains("need 1 more") ?? false),
                 "recommendThreshold: 29 genuine → refused on genuine count only, 'need 1 more'")

        let fewImpostor = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(10, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        c.expect(shortfalls(fewImpostor) == [.impostorSamples(have: 10, need: 30)] && !fewImpostor.justifiesTunedFlag,
                 "recommendThreshold: 10 impostor → refused on impostor count only (need 20 more)")

        let oneStranger = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 1
        )
        c.expect(shortfalls(oneStranger) == [.impostorIdentities(have: 1, need: 2)] && !oneStranger.justifiesTunedFlag,
                 "recommendThreshold: 30 impostor scores from ONE person → refused on identity count (EC-03)")

        let unknownIdentities = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60))
        )
        c.expect(shortfalls(unknownIdentities) == [.impostorIdentities(have: nil, need: 2)]
                 && !unknownIdentities.justifiesTunedFlag,
                 "recommendThreshold: impostor identity count not supplied → refused, never assumed")

        // Margin 0.03 (< 0.05): cleanly apart on this sample, but too narrow to trust.
        let narrow = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.63, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.60)),
            impostorIdentityCount: 3
        )
        var narrowOK = false
        if case let .separationMargin(have, need)? = shortfalls(narrow).first, shortfalls(narrow).count == 1 {
            narrowOK = abs(have - 0.03) < 1e-9 && abs(need - 0.05) < 1e-12
        }
        c.expect(narrowOK && !narrow.justifiesTunedFlag
                 && (narrow.refusalReason?.contains("short by 0.0200") ?? false),
                 "recommendThreshold: margin 0.03 < 0.05 → refused on margin, 'short by 0.0200'")

        // Everything short at once → every shortfall listed, so one run says all to fix.
        let allShort = recommendThreshold(
            genuine: ScoreDistribution([0.62, 0.70]),
            impostor: ScoreDistribution([0.60]),
            impostorIdentityCount: 1
        )
        c.expect(shortfalls(allShort).count == 4 && !allShort.justifiesTunedFlag,
                 "recommendThreshold: all four criteria unmet → all four shortfalls reported")

        // A custom (looser) bar is honored — the bar is a parameter, not magic.
        let loose = recommendThreshold(
            genuine: ScoreDistribution([0.80, 0.90, 0.95]),
            impostor: ScoreDistribution([0.20, 0.40, 0.60]),
            impostorIdentityCount: 2,
            requirements: ThresholdStudyRequirements(minimumGenuineSamples: 3, minimumImpostorSamples: 3)
        )
        c.expect(loose.justifiesTunedFlag,
                 "recommendThreshold: explicit looser requirements are honored")

        // Overlap → report the equal-error point but REFUSE to bless it — even on a
        // small sample (an impostor that matched is a finding, not noise).
        let overlapping = recommendThreshold(
            genuine: ScoreDistribution([0.30, 0.60, 0.90]),
            impostor: ScoreDistribution([0.25, 0.65, 0.85]),
            impostorIdentityCount: 2
        )
        var overlapOK = false
        if case let .overlap(equalError, _, _) = overlapping {
            overlapOK = equalError > 0.0 && equalError < 1.0
        }
        c.expect(overlapOK && !overlapping.justifiesTunedFlag
                 && (overlapping.refusalReason?.contains("overlap") ?? false),
                 "recommendThreshold: overlap → equal-error point reported, tuned flag REFUSED")

        // A single impostor above the genuine floor is enough to deny separation — the
        // conservative direction (one look-alike that matches is the EC-03 failure).
        let oneBadImpostor = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.80, to: 0.95)),
            impostor: ScoreDistribution(spread(29, from: 0.10, to: 0.40) + [0.85]),
            impostorIdentityCount: 3
        )
        var oneBadIsOverlap = false
        if case .overlap = oneBadImpostor { oneBadIsOverlap = true }
        c.expect(oneBadIsOverlap && !oneBadImpostor.justifiesTunedFlag,
                 "recommendThreshold: one impostor above the genuine floor denies clean separation (EC-03)")

        // Boundary: impostor max EQUAL to genuine min is overlap (IdentityRecognizer's
        // `>=` would accept that impostor).
        let touching = recommendThreshold(
            genuine: ScoreDistribution(spread(30, from: 0.70, to: 0.95)),
            impostor: ScoreDistribution(spread(30, from: 0.20, to: 0.70)),
            impostorIdentityCount: 3
        )
        var touchingIsOverlap = false
        if case .overlap = touching { touchingIsOverlap = true }
        c.expect(touchingIsOverlap, "recommendThreshold: impostor max == genuine min → overlap (matches >= accept)")
    }
}

// MARK: - ND-095: deferred (off-main) model load

/// One-shot gate a fake `load` closure waits on, so a check controls when "loading" ends.
final class LoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); k.resume(); return }
            waiters.append(k)
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

private func vector(_ o: FaceEmbeddingOutcome) -> [Float]? {
    if case let .embedding(v) = o { return v }
    return nil
}
private func isFailure(_ o: FaceEmbeddingOutcome) -> Bool {
    if case .failure = o { return true }
    return false
}

/// Short real-time pause so a spawned task reaches its `await` on the load.
private func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }

@MainActor
func runDeferredEmbedderChecks(_ c: Checks) async {
    print("\nDeferred model load checks (ND-095):")
    let presumed = FaceEmbeddingModelDescriptor.uniqueFake()
    let fallbackDesc = FaceEmbeddingModelDescriptor.uniqueFake()

    // Load succeeds: descriptor is the presumed one while loading, an in-flight embed
    // WAITS (no placeholder answer), then gets the loaded embedder's vector.
    do {
        let gate = LoadGate()
        let real = FakeEmbedder([1, 0, 0, 0], descriptor: presumed)
        let d = DeferredFaceEmbedder(presumed: presumed, fallback: FakeEmbedder([0, 1, 0, 0], descriptor: fallbackDesc),
                                     load: { await gate.wait(); return real })
        c.expect(d.descriptor.version == presumed.version && !d.isResolved,
                 "ND-095: while loading, descriptor = presumed model (no identity flap)")
        let pending = Task { await d.embeddingWithLiveness(for: CapturedFrame()).outcome }
        await settle()
        c.expect(!d.isResolved, "ND-095: an embed call during load waits for the model")
        gate.open()
        let first = await pending.value
        c.expect(vector(first) == [1, 0, 0, 0], "ND-095: the waiting call is answered by the LOADED model")
        c.expect(d.isResolved && d.descriptor.version == presumed.version,
                 "ND-095: after a successful load, descriptor stays the loaded model's")
        let later = await d.embedding(for: CapturedFrame())
        c.expect(vector(later) == [1, 0, 0, 0], "ND-095: later calls delegate to the loaded model")
    }

    // Load fails: permanent Vision-style fallback; the call that straddled the switch
    // gets .failure (never a vector from another embedding space).
    do {
        let gate = LoadGate()
        let d = DeferredFaceEmbedder(presumed: presumed, fallback: FakeEmbedder([0, 1, 0, 0], descriptor: fallbackDesc),
                                     load: { await gate.wait(); return nil })
        let pending = Task { await d.embeddingWithLiveness(for: CapturedFrame()).outcome }
        await settle()
        gate.open()
        let straddling = await pending.value
        c.expect(isFailure(straddling),
                 "ND-095: load failure → the in-flight call returns .failure, not a cross-model vector")
        c.expect(d.descriptor.version == fallbackDesc.version,
                 "ND-095: load failure → descriptor switches to the fallback (loud ND-073 identity-off)")
        let later = await d.embedding(for: CapturedFrame())
        c.expect(vector(later) == [0, 1, 0, 0], "ND-095: after a load failure, calls use the fallback")
    }

    // ND-073 no-flap: enrolled under the presumed model → identity is .active DURING the
    // load (status is published before the embed awaits), and after a failed load it is
    // .off(.modelMismatch) (the loud fallback state).
    do {
        let gate = LoadGate()
        let d = DeferredFaceEmbedder(presumed: presumed, fallback: FakeEmbedder([0, 1, 0, 0], descriptor: fallbackDesc),
                                     load: { await gate.wait(); return nil })
        let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: presumed.version)
        let r = IdentityRecognizer(embedder: d, store: store, marker: InMemoryEnrollmentMarker(presumed.version))
        let pending = Task { await r.recognize(CapturedFrame()) }
        await settle()
        c.expect(r.lastIdentityStatus == .active, "ND-095: identity status is .active while the model loads")
        gate.open()
        let during = await pending.value
        c.expect(during == .error("face embedding failed"),
                 "ND-095: the tick that straddled a failed load holds (.error), never matches cross-model")
        _ = await r.recognize(CapturedFrame())
        c.expect(r.lastIdentityStatus == .off(.modelMismatch(stored: presumed.version, active: fallbackDesc.version)),
                 "ND-095: after a failed load identity is loudly OFF (model mismatch)")
    }

    // Load timeout (security-review hardening): a load that never completes must not
    // hang every tick in recognize() (no reading → no absence → never locks). After the
    // timeout it resolves to the fallback (loud identity-off), like a failed load.
    do {
        let gate = LoadGate()   // never opened before the timeout: the load hangs
        let real = FakeEmbedder([1, 0, 0, 0], descriptor: presumed)
        let d = DeferredFaceEmbedder(presumed: presumed, fallback: FakeEmbedder([0, 1, 0, 0], descriptor: fallbackDesc),
                                     loadTimeout: 0.2,
                                     load: { await gate.wait(); return real })
        let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: presumed.version)
        let r = IdentityRecognizer(embedder: d, store: store, marker: InMemoryEnrollmentMarker(presumed.version))
        let started = Date()
        let during = await r.recognize(CapturedFrame())
        let waited = Date().timeIntervalSince(started)
        c.expect(waited < 5, "load timeout: a never-completing load releases the tick after the timeout (waited \(String(format: "%.2f", waited))s)")
        c.expect(during == .error("face embedding failed"),
                 "load timeout: the straddling tick holds (.error), never matches cross-model")
        c.expect(d.isResolved && d.descriptor.version == fallbackDesc.version,
                 "load timeout: resolves to the fallback descriptor")
        _ = await r.recognize(CapturedFrame())
        c.expect(r.lastIdentityStatus == .off(.modelMismatch(stored: presumed.version, active: fallbackDesc.version)),
                 "load timeout: identity is loudly OFF (model mismatch), not silently on")
        gate.open()          // the load finally completes — too late
        await settle()
        c.expect(d.descriptor.version == fallbackDesc.version,
                 "load timeout: a load completing after the timeout is discarded (fallback stays)")
    }

    // Explicit compute units (ND-095): CPU + Neural Engine, never the GPU.
    c.expect(CoreMLFaceEmbedder.modelConfiguration().computeUnits == .cpuAndNeuralEngine,
             "ND-095: Core ML model configured for .cpuAndNeuralEngine")

    // The real model, when present locally (not in CI): async load succeeds.
    let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/Models/FaceNetVGGFace2.mlmodelc").standardizedFileURL
    if FileManager.default.fileExists(atPath: local.path) {
        let loaded = await CoreMLFaceEmbedder.load(compiledModelURL: local)
        c.expect(loaded?.descriptor.version == FaceEmbeddingModelDescriptor.facenetVGGFace2.version,
                 "ND-095: CoreMLFaceEmbedder.load(compiledModelURL:) loads the bundled FaceNet model async")
    } else {
        print("  (skipped: local FaceNet model not present)")
    }
}

/// ND-110: the Core ML embedder's pure post-processing helpers — `l2Normalized` and
/// `coreMLFirstMultiArrayOutput` — exercised without a model file.
@MainActor
func runCoreMLEmbeddingHelperChecks(_ c: Checks) async {
    print("\nND-110 Core ML embedding helper checks:")

    // l2Normalized: unit length, direction kept; degenerate input → [] (→ .failure).
    do {
        let n = l2Normalized([3, 4])
        c.expect(n.count == 2 && abs(n[0] - 0.6) < 1e-6 && abs(n[1] - 0.8) < 1e-6,
                 "ND-110 l2Normalized: [3,4] → [0.6,0.8] (unit length, direction kept)")
        let unit = l2Normalized([0, 1, 0])
        c.expect(unit == [0, 1, 0], "ND-110 l2Normalized: an already-unit vector is unchanged")
        let big = l2Normalized([Float](repeating: 1e30, count: 512))
        let norm = big.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        c.expect(big.count == 512 && abs(norm - 1) < 1e-4 && big.allSatisfy { $0.isFinite },
                 "ND-110 l2Normalized: huge components (Float² would overflow) → finite unit vector")
        let tiny = l2Normalized([1e-30, 0])
        c.expect(tiny.count == 2 && abs(tiny[0] - 1) < 1e-6,
                 "ND-110 l2Normalized: tiny non-zero components still normalize")
        c.expect(l2Normalized([]).isEmpty && l2Normalized([0, 0, 0]).isEmpty,
                 "ND-110 l2Normalized: empty or zero-norm vector → [] (failure, not NaN)")
        c.expect(l2Normalized([1, .nan]).isEmpty && l2Normalized([.infinity, 1]).isEmpty
                 && l2Normalized([-.infinity]).isEmpty,
                 "ND-110 l2Normalized: any NaN / ±inf component → [] (never a poisoned vector)")
        let a = l2Normalized([2, 0, 0]), b = l2Normalized([5, 0, 0])
        c.expect(a == b && abs(cosineSimilarity(a, b) - 1) < 1e-6,
                 "ND-110 l2Normalized: scale-invariant (2x and 5x the same direction match)")
    }

    // coreMLFirstMultiArrayOutput: picks the multi-array, skips other outputs, handles
    // element types, refuses empty / missing outputs.
    func multiArray(_ values: [Double], _ type: MLMultiArrayDataType) -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: type) else { return nil }
        for (i, v) in values.enumerated() { arr[i] = NSNumber(value: v) }
        return arr
    }
    func provider(_ dict: [String: Any]) -> MLFeatureProvider? {
        try? MLDictionaryFeatureProvider(dictionary: dict)
    }
    do {
        if let f32 = multiArray([0.5, -1, 2], .float32), let p = provider(["embedding": f32]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == [0.5, -1, 2],
                     "ND-110 firstMultiArrayOutput: float32 [1,3] output → its 3 values, in order")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: float32 fixture could not be built") }

        if let f64 = multiArray([0.25, 4], .double), let p = provider(["out": f64]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == [0.25, 4],
                     "ND-110 firstMultiArrayOutput: double output → converted to Float")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: double fixture could not be built") }

        if let f16 = multiArray([1, 0.5, -2], .float16), let p = provider(["out": f16]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == [1, 0.5, -2],
                     "ND-110 firstMultiArrayOutput: float16 output → converted to Float")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: float16 fixture could not be built") }

        // A non-multi-array output (e.g. a string label) alongside the embedding is skipped,
        // whichever order the provider reports its names in.
        if let emb = multiArray([1, 2], .float32), let p = provider(["aaa_label": "face", "zzz_emb": emb]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == [1, 2],
                     "ND-110 firstMultiArrayOutput: non-multi-array outputs are skipped")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: mixed-output fixture could not be built") }

        if let p = provider(["label": "face", "score": 0.9]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == nil,
                     "ND-110 firstMultiArrayOutput: no multi-array output → nil (failure)")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: no-array fixture could not be built") }

        if let empty = try? MLMultiArray(shape: [0], dataType: .float32), let p = provider(["out": empty]) {
            c.expect(coreMLFirstMultiArrayOutput(p) == nil,
                     "ND-110 firstMultiArrayOutput: empty multi-array → nil (failure)")
        } else {
            // Core ML may refuse a zero-length array outright; that is also a non-output.
            c.expect(true, "ND-110 firstMultiArrayOutput: zero-length MLMultiArray not constructible, skipped")
        }

        // Deterministic pick: two multi-arrays → the one with the lexically first name,
        // on every call (featureNames is an unordered Set).
        if let a = multiArray([1], .float32), let b = multiArray([2], .float32),
           let p = provider(["b_out": b, "a_out": a]) {
            let picks = (0..<5).map { _ in coreMLFirstMultiArrayOutput(p) }
            c.expect(picks.allSatisfy { $0 == [1] },
                     "ND-110 firstMultiArrayOutput: several multi-arrays → deterministic (sorted-name) pick")
        } else { c.expect(false, "ND-110 firstMultiArrayOutput: two-array fixture could not be built") }
    }
}
