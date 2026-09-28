import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// ND-085 face quality gate + square crop.
@MainActor
func runFaceQualityGateChecks(_ c: Checks) async {
    // MARK: ND-085 face quality gate + square crop (cooper)
    do {
        let hd = CGRect(x: 0, y: 0, width: 1280, height: 720)
        // 12% of the 720 px shorter side = 86.4 px.
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.08),
                                    orientedExtent: hd),
                 "ND-085 min size: tiny face (64×58 px in 720p) → too small (embedders return .noFace)")
        c.expect(faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.35, y: 0.3, width: 0.2, height: 0.4),
                                   orientedExtent: hd),
                 "ND-085 min size: seated-distance face (256×288 px) → large enough")
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.0671, height: 0.2),
                                    orientedExtent: hd)
                 && faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.0676, height: 0.2),
                                      orientedExtent: hd),
                 "ND-085 min size: the SHORTER face side decides, at 12% of the frame's shorter side (86.4 px)")
        let portrait = CGRect(x: 0, y: 0, width: 720, height: 1280)
        c.expect(faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.125, height: 0.0703),
                                   orientedExtent: portrait)
                 == faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.0703, height: 0.125),
                                      orientedExtent: hd),
                 "ND-085 min size: same verdict for the same pixel face under a portrait orientation")
        c.expect(!faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3),
                                    orientedExtent: .zero)
                 && !faceIsLargeEnough(faceBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0, height: 0.3),
                                       orientedExtent: hd),
                 "ND-085 min size: degenerate frame or box → too small (never toward a match)")
        c.expect(abs(Double(minimumFaceSideFraction) - 0.12) < 1e-9, "ND-085 min size: documented default is 12%")

        // Square crop inside the frame: 200×200 face, 0.25 padding → 300 square, centered.
        let inside = squareFaceCrop(faceBoundingBox: CGRect(x: 500.0 / 1280, y: 260.0 / 720,
                                                            width: 200.0 / 1280, height: 200.0 / 720),
                                    paddingFraction: 0.25, orientedExtent: hd)
        c.expect(inside?.square == CGRect(x: 450, y: 210, width: 300, height: 300)
                 && inside?.visible == inside?.square && inside?.needsPadding == false,
                 "ND-085 square crop: face well inside → 300×300 square centered on the face, no padding")

        // Non-square face box: the LONGER padded side wins, the crop stays square.
        let tall = squareFaceCrop(faceBoundingBox: CGRect(x: 600.0 / 1280, y: 200.0 / 720,
                                                          width: 100.0 / 1280, height: 200.0 / 720),
                                  paddingFraction: 0.25, orientedExtent: hd)
        c.expect(tall?.square == CGRect(x: 500, y: 150, width: 300, height: 300),
                 "ND-085 square crop: 100×200 face → 300×300 square (longer side), never a 150×300 rect")

        // Near the left/bottom edge: square keeps its full size and center, visible part is clipped.
        let edge = squareFaceCrop(faceBoundingBox: CGRect(x: 0, y: 0, width: 200.0 / 1280, height: 200.0 / 720),
                                  paddingFraction: 0.25, orientedExtent: hd)
        c.expect(edge?.square == CGRect(x: -50, y: -50, width: 300, height: 300)
                 && edge?.visible == CGRect(x: 0, y: 0, width: 250, height: 250)
                 && edge?.needsPadding == true,
                 "ND-085 square crop: face at the corner → square extends past the frame, padded not stretched")
        c.expect(squareFaceCrop(faceBoundingBox: CGRect(x: 3, y: 3, width: 0.1, height: 0.1),
                                paddingFraction: 0.25, orientedExtent: hd) == nil
                 && squareFaceCrop(faceBoundingBox: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.1),
                                   paddingFraction: 0.25, orientedExtent: hd) == nil,
                 "ND-085 square crop: off-frame or degenerate box → nil (caller maps to .failure)")

        // Render the edge crop: the out-of-frame part is BLACK, the in-frame part is the
        // frame's pixels, and the scale is uniform (no stretch).
        if let frame = makeGrayBGRAFrame(width: 320, height: 180, luma: { _, _ in 200 }) {
            let ci = CIImage(cvPixelBuffer: frame)
            let crop = squareFaceCrop(faceBoundingBox: CGRect(x: 0, y: 0.2, width: 0.25, height: 80.0 / 180),
                                      paddingFraction: 0.25, orientedExtent: ci.extent)
            var out: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                          kCVPixelBufferCGBitmapContextCompatibilityKey: true]
            if let crop, CVPixelBufferCreate(kCFAllocatorDefault, 40, 40, kCVPixelFormatType_32BGRA,
                                             attrs as CFDictionary, &out) == kCVReturnSuccess, let out {
                CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                    .render(squareFaceInputImage(from: ci, crop: crop, side: 40), to: out)
                CVPixelBufferLockBaseAddress(out, .readOnly)
                let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(out)
                // The square is 120 px wide starting at x = -20, so the left 1/6 (≈6.7 of
                // 40 px) is padding; take columns 1 and 30 on the middle row.
                let mid = 20 * row
                let padded = base[mid + 1 * 4 + 1]
                let inFrame = base[mid + 30 * 4 + 1]
                CVPixelBufferUnlockBaseAddress(out, .readOnly)
                c.expect(crop.square.width == crop.square.height && crop.square.minX == -20,
                         "ND-085 square crop render: square geometry near the left edge (x = -20, 120×120)")
                c.expect(padded < 10 && abs(Int(inFrame) - 200) <= 3,
                         "ND-085 square crop render: out-of-frame columns are black, in-frame keep the pixels (\(padded), \(inFrame))")
            } else {
                c.expect(false, "ND-085 square crop render: could not build the test buffers")
            }
        } else {
            c.expect(false, "ND-085 square crop render: could not build the test frame")
        }
    }
}

/// ND-085 version bump.
@MainActor
func runFaceQualityVersionChecks(_ c: Checks) async {
    // MARK: ND-085 version bump (cooper)
    do {
        let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
        c.expect(fn.version == "facenet-vggface2-v2",
                 "ND-085 version bump: FaceNet descriptor is facenet-vggface2-v2 (square crop changed embeddings)")
        let v1 = identityStatus(for: .enrolled([[1, 0, 0, 0]], modelVersion: "facenet-vggface2-v1"),
                                activeVersion: fn.version, markerVersion: "facenet-vggface2-v1")
        c.expect(v1 == .off(.modelMismatch(stored: "facenet-vggface2-v1", active: "facenet-vggface2-v2")),
                 "ND-085 version bump: a v1 enrollment reads as identity off (model mismatch) → re-enroll")
        let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: "fake-test-v0-precrop")
        let r = IdentityRecognizer(embedder: FakeEmbedder([0, 1, 0, 0]), store: store)
        _ = await r.recognize(CapturedFrame())
        c.expect(r.lastIdentityStatus.isOff,
                 "ND-085 version bump: recognizer never compares vectors from the old crop (identity off)")
        c.expect(fn.enrollmentOutlierFloor == 0.5 && fn.enrollmentConsistencyFloor == 0.6
                 && FaceEmbeddingModelDescriptor.visionFeaturePrint.enrollmentOutlierFloor == 0.6
                 && FaceEmbeddingModelDescriptor.visionFeaturePrint.enrollmentConsistencyFloor == 0.7
                 && FaceEmbeddingModelDescriptor.fakeTest.enrollmentOutlierFloor == 0.6
                 && abs(FaceEmbeddingModelDescriptor.fakeTest.enrollmentConsistencyFloor - 0.7) < 1e-9,
                 "ND-063 floors: FaceNet 0.5/0.6, Vision 0.6/0.7, default = threshold / threshold+0.1")
    }
}

/// ND-063 enrollment quality.
@MainActor
func runEnrollmentQualityChecks(_ c: Checks) async {
    // MARK: ND-063 enrollment quality (cooper)
    do {
        // Dedupe.
        var d = EnrollmentFrameDeduper()
        let a = d.isNew(CapturedFrame(captureTime: 10))
        let aAgain = d.isNew(CapturedFrame(captureTime: 10))
        let b = d.isNew(CapturedFrame(captureTime: 11))
        let n1 = d.isNew(CapturedFrame())
        let n2 = d.isNew(CapturedFrame())
        c.expect(a && !aAgain && b && n1 && n2,
                 "ND-063 dedupe: same captureTime counted once; new time is new; no time (fakes) → distinct")
        if let buf = makeGrayBGRAFrame(width: 4, height: 4, luma: { _, _ in 1 }) {
            var d2 = EnrollmentFrameDeduper()
            let first = d2.isNew(CapturedFrame(pixelBuffer: buf, captureTime: 20))
            let sameBufNewTime = d2.isNew(CapturedFrame(pixelBuffer: buf, captureTime: 21))
            c.expect(first && !sameBufNewTime,
                     "ND-063 dedupe: the same pixel buffer object again is a repeat even with a different time")
        }

        // Consistency gate (pure).
        let user: [[Float]] = [[1, 0.02, 0, 0], [1, 0, 0.03, 0], [0.98, 0.01, 0, 0.02],
                               [1, 0.03, 0.01, 0], [0.99, 0, 0, 0.01]]
        let stranger: [Float] = [0, 1, 0.1, 0]
        let withPhotobomb = [user[0], user[1], stranger, user[2], user[3], user[4]]
        let r1 = evaluateEnrollmentConsistency(withPhotobomb, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(r1.droppedIndices == [2] && r1.kept.count == 5 && r1.isConsistent && r1.medianPairwise > 0.99,
                 "ND-063 consistency: one photobomb vector dropped as an outlier, the rest kept → consistent")

        let r2 = evaluateEnrollmentConsistency(Array(user.prefix(4)) + [stranger], requiredVectors: 5,
                                               outlierFloor: 0.6, consistencyFloor: 0.7,
                                               maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r2.isConsistent && r2.droppedIndices == [4] && r2.kept.count == 4,
                 "ND-063 consistency: outlier dropped leaves fewer than N → not consistent (keep sampling)")

        let alternating: [[Float]] = (0..<10).map { (i: Int) -> [Float] in i % 2 == 0 ? user[i / 2] : stranger }
        let r3 = evaluateEnrollmentConsistency(alternating, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r3.isConsistent && r3.droppedIndices.count > 3,
                 "ND-063 consistency: two faces taking turns → too many outliers → inconsistent (never enrolls either)")

        // All pairs at cos 0.65: above the outlier floor (none dropped), below the median floor.
        let aa = Float(0.65).squareRoot(), bb = Float(0.35).squareRoot()
        let mushy: [[Float]] = (1...5).map { i in (0..<6).map { $0 == 0 ? aa : ($0 == i ? bb : 0) } }
        let r4 = evaluateEnrollmentConsistency(mushy, requiredVectors: 5, outlierFloor: 0.6,
                                               consistencyFloor: 0.7, maxOutlierFraction: 1.0 / 3.0)
        c.expect(!r4.isConsistent && r4.droppedIndices.isEmpty && abs(r4.medianPairwise - 0.65) < 1e-3,
                 "ND-063 consistency: median pairwise 0.65 < floor 0.7 → inconsistent")

        // End to end: distinct frames. Each frame served 3× (≈ 1 fps polled at 200 ms).
        do {
            let clock = FakeClock()
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(100 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(100 + $0), user[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames, repeats: 3), embedder: embedder,
                                                 store: store, now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .success(count: 5) && embedder.callCount == 5,
                     "ND-063 capture: 5 distinct frames, each served 3× → each embedded once → success(5)")
            c.expect(store.enrolledEmbeddings().count == 5
                     && identityStatus(for: store.enrollmentState(), activeVersion: FaceEmbeddingModelDescriptor.fakeTest.version,
                                       markerVersion: nil) == .active,
                     "ND-063 capture: stored 5 vectors stamped with the active model version")
        }

        // One frame repeated forever (frozen camera) never becomes 5 references.
        do {
            let clock = FakeClock()
            let embedder = TimeKeyedEmbedder([7: user[0]])
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera([CapturedFrame(captureTime: 7)]),
                                                 embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .notEnoughFaces && embedder.callCount == 1 && !store.isEnrolled,
                     "ND-063 capture: one frame served for 10 s is embedded once → notEnoughFaces, nothing stored")
        }

        // Photobombed capture recovers: an outlier is replaced by a later good frame.
        do {
            let clock = FakeClock()
            let seq: [[Float]] = [user[0], stranger, user[1], user[2], user[3], user[4]]
            let frames = seq.indices.map { CapturedFrame(captureTime: TimeInterval(200 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: seq.indices.map {
                (TimeInterval(200 + $0), seq[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            let stored = store.enrolledEmbeddings()
            c.expect(out == .success(count: 5) && stored.count == 5 && !stored.contains(stranger),
                     "ND-063 capture: photobomb vector dropped, capture continues, the stranger is never stored")
        }

        // Inconsistent capture: existing enrollment untouched.
        do {
            let clock = FakeClock()
            let frames = (0..<12).map { CapturedFrame(captureTime: TimeInterval(300 + $0)) }
            var altMap: [TimeInterval: [Float]] = [:]
            for i in 0..<12 { altMap[TimeInterval(300 + i)] = i % 2 == 0 ? user[(i / 2) % 5] : stranger }
            let embedder = TimeKeyedEmbedder(altMap)
            let original: [[Float]] = [[0, 0, 1, 0]]
            let store = InMemoryEnrollmentStore(embeddings: original, modelVersion: "fake-test-v1")
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .inconsistent, "ND-063 capture: two faces alternating → .inconsistent")
            c.expect(store.enrolledEmbeddings() == original
                     && identityStatus(for: store.enrollmentState(), activeVersion: "fake-test-v1", markerVersion: nil) == .active,
                     "ND-063 capture: .inconsistent leaves the existing enrollment and its version untouched")
            c.expect(embedder.callCount == 10, "ND-063 capture: stops at the 10-vector cap")
        }

        // Median below floor end to end → .inconsistent, store untouched.
        do {
            let clock = FakeClock()
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(400 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(400 + $0), mushy[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(out == .inconsistent && !store.isEnrolled && clock.now - 1_000 >= 10,
                     "ND-063 capture: low median pairwise → keeps trying to the 10 s timeout → .inconsistent, nothing stored")
        }

        // No camera → .cameraUnavailable at the short no-frame timeout, not the full 10 s.
        do {
            let clock = FakeClock()
            let store = InMemoryEnrollmentStore(embeddings: [[1, 0, 0, 0]], modelVersion: "fake-test-v1")
            let out = await runEnrollmentCapture(camera: SequenceCamera([]), embedder: TimeKeyedEmbedder([:]),
                                                 store: store, now: { clock.now }, sleep: { clock.advance($0) })
            let waited = clock.now - 1_000
            c.expect(out == .cameraUnavailable && waited >= 4 && waited < 5 && store.enrolledEmbeddings().count == 1,
                     "ND-063 capture: no frames → .cameraUnavailable after ~4 s, store untouched")
        }

        // Policy defaults.
        let p = EnrollmentCapturePolicy(descriptor: .facenetVGGFace2)
        c.expect(p.requiredVectors == 5 && p.maxCollectedVectors == 10 && p.timeout == 10
                 && p.outlierFloor == 0.5 && p.consistencyFloor == 0.6,
                 "ND-063 policy: 5 distinct vectors, cap 10, 10 s timeout, FaceNet floors from the descriptor")
    }
}

/// ND-093 / ND-110 enrollment input validation + blob decode.
@MainActor
func runEnrollmentInputValidationChecks(_ c: Checks) async {
    print("\nND-093 / ND-110 — enrollment input validation + blob decode")
    do {
        func rejects(_ e: [[Float]], _ dim: Int?, _ reason: InvalidEmbeddingsReason) -> Bool {
            let store = InMemoryEnrollmentStore(embeddings: [[0, 0, 1, 0]], modelVersion: "fake-test-v1")
            do {
                try store.enroll(embeddings: e, modelVersion: "fake-test-v2", expectedDimension: dim)
                return false
            } catch let err as EnrollmentStoreError {
                // Rejected AND the existing enrollment (vectors + version) is untouched.
                return err == .invalidEmbeddings(reason)
                    && store.enrolledEmbeddings() == [[0, 0, 1, 0]]
                    && identityStatus(for: store.enrollmentState(), activeVersion: "fake-test-v1",
                                      markerVersion: nil) == .active
            } catch { return false }
        }
        c.expect(rejects([], 4, .emptySet),
                 "ND-093 enroll: empty set throws .emptySet, existing enrollment untouched")
        c.expect(rejects([[1, 0, 0, 0], []], nil, .emptyVector(index: 1)),
                 "ND-093 enroll: an empty vector throws .emptyVector")
        c.expect(rejects([[1, 0, 0, 0], [1, 0, 0]], nil, .mixedDimensions(index: 1, expected: 4, found: 3)),
                 "ND-093 enroll: mixed vector lengths throw .mixedDimensions")
        c.expect(rejects([[1, 0, 0, 0], [1, .nan, 0, 0]], nil, .nonFinite(index: 1)),
                 "ND-093 enroll: a NaN component throws .nonFinite")
        c.expect(rejects([[.infinity, 0, 0, 0]], nil, .nonFinite(index: 0)),
                 "ND-093 enroll: an infinite component throws .nonFinite")
        c.expect(rejects([[1, 0, 0]], 4, .wrongDimension(expected: 4, found: 3)),
                 "ND-093 enroll: vectors not matching the model's dimension throw .wrongDimension")

        let ok = InMemoryEnrollmentStore()
        let accepted = (try? ok.enroll(embeddings: [[1, 0, 0, 0], [0.9, 0.1, 0, 0]],
                                       modelVersion: "fake-test-v1", expectedDimension: 4)) != nil
        let acceptedUnknownDim = (try? InMemoryEnrollmentStore()
            .enroll(embeddings: [[1, 0, 0]], modelVersion: "vision", expectedDimension: nil)) != nil
        let acceptedZeroDim = (try? InMemoryEnrollmentStore()
            .enroll(embeddings: [[1, 0, 0]], modelVersion: "vision", expectedDimension: 0)) != nil
        c.expect(accepted && ok.enrolledEmbeddings().count == 2 && acceptedUnknownDim && acceptedZeroDim,
                 "ND-093 enroll: a valid set is stored; nil/0 expected dimension (Vision fallback) skips only the dimension check")

        // runEnrollmentCapture passes the descriptor's dimension through: 3-d vectors from
        // a 4-d model → .saveFailed, nothing stored.
        do {
            let clock = FakeClock()
            let v3: [[Float]] = [[1, 0.02, 0], [1, 0, 0.03], [0.98, 0.01, 0], [1, 0.03, 0.01], [0.99, 0, 0.01]]
            let frames = (0..<5).map { CapturedFrame(captureTime: TimeInterval(500 + $0)) }
            let embedder = TimeKeyedEmbedder(Dictionary(uniqueKeysWithValues: (0..<5).map {
                (TimeInterval(500 + $0), v3[$0]) }))
            let store = InMemoryEnrollmentStore()
            let out = await runEnrollmentCapture(camera: SequenceCamera(frames), embedder: embedder, store: store,
                                                 now: { clock.now }, sleep: { clock.advance($0) })
            c.expect(embedder.descriptor.outputDimension == 4 && out == .saveFailed && !store.isEnrolled,
                     "ND-093 capture: vectors of the wrong dimension for the model → .saveFailed, nothing stored")
        }

        // Blob decode (ND-110 coverage). Blobs are hand-written JSON, as the Keychain holds.
        func decode(_ json: String) -> EnrollmentState { EnrollmentStore.decodeEnrollment(Data(json.utf8)) }
        func isUnavailable(_ s: EnrollmentState) -> Bool { if case .unavailable = s { return true }; return false }
        if case .enrolled(let e, let v) = decode(#"{"modelVersion":"m1","embeddings":[[1,0],[0,1]]}"#) {
            c.expect(e == [[1, 0], [0, 1]] && v == "m1", "ND-110 decode: versioned blob → .enrolled with its version")
        } else { c.expect(false, "ND-110 decode: versioned blob → .enrolled with its version") }
        if case .enrolled(let e, let v) = decode("[[1,0,0],[0,1,0]]") {
            c.expect(e.count == 2 && v == nil, "ND-110 decode: legacy bare array → .enrolled, version nil (stale)")
        } else { c.expect(false, "ND-110 decode: legacy bare array → .enrolled, version nil (stale)") }
        c.expect(isNotEnrolled(decode(#"{"modelVersion":"m1","embeddings":[]}"#)) && isNotEnrolled(decode("[]")),
                 "ND-110 decode: empty set (versioned or legacy) → .notEnrolled")
        c.expect(isUnavailable(decode("not json")) && isUnavailable(decode(#"{"embeddings":"x"}"#))
                 && isUnavailable(decode("")),
                 "ND-110 decode: corrupt / undecodable blob → .unavailable (fail-safe)")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1,0,0],[1,0]]}"#))
                 && isUnavailable(decode("[[1,0,0],[1,0]]")),
                 "ND-093 decode: mixed vector lengths (versioned or legacy) → .unavailable, never presence-only")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1,0],[]]}"#)),
                 "ND-093 decode: an empty vector inside the set → .unavailable")
        c.expect(isUnavailable(decode(#"{"modelVersion":"m1","embeddings":[[1e39,0]]}"#)),
                 "ND-093 decode: an out-of-range (non-finite as Float) component → .unavailable")
    }
}
