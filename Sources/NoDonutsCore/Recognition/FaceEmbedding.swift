import Foundation
@preconcurrency import Vision
import CoreVideo
import CoreImage
import os

// Owner: cooper — face → embedding vector. Backlog: ND-021, ND-024. ADR-0012 (amends ADR-0002).
// Privacy: all on-device (Apple Vision); frames analyzed in memory and discarded; no network.

/// Tri-state outcome of one embedding pass — distinguishes "no face" from "failure".
///
/// This distinction is **security-critical** (EC-10, fail-safe): a transient Vision
/// glitch must NOT look like a genuine "no face", or repeated glitches would advance
/// the presence engine's absence consensus and lock a present user. `.failure` maps to
/// `RecognitionResult.error(...)`, which the engine holds conservatively (never
/// fail-open); `.noFace` maps to absence.
public enum FaceEmbeddingOutcome: Sendable {
    /// A face was found and successfully embedded.
    case embedding([Float])
    /// Vision ran and found no face in the frame. → absence.
    case noFace
    /// Detection / crop / feature-print / pixel-buffer error — the caller must treat
    /// this conservatively (EC-10): surface `.error`, hold, never fail-open.
    case failure
}

/// Richer outcome that ALSO carries a liveness/texture score for the chosen face
/// (ND-041, EC-12). Same tri-state semantics as `FaceEmbeddingOutcome`, but the
/// `.embedding` case additionally reports `textureScore` (variance-of-Laplacian on
/// the face crop — see `faceTextureScore`). Used by `IdentityRecognizer` for the
/// conservative anti-spoof check.
///
/// This is a SEPARATE type on purpose: `FaceEmbeddingOutcome` (and the App's switch
/// on `.embedding([Float])`) stays source-compatible. The App keeps calling
/// `embedding(for:)`; only the recognizer opts into `embeddingWithLiveness(for:)`.
public enum FaceEmbeddingResult: Sendable {
    /// A face was found + embedded, with its crop's texture score for liveness.
    case embedding([Float], textureScore: Double)
    /// Vision ran and found no face in the frame. → absence.
    case noFace
    /// Detection / crop / feature-print / pixel-buffer error (EC-10 conservative hold).
    case failure

    /// Project to the score-free `FaceEmbeddingOutcome` so the existing protocol
    /// method and App call sites keep working unchanged.
    public var outcome: FaceEmbeddingOutcome {
        switch self {
        case let .embedding(vector, _): return .embedding(vector)
        case .noFace: return .noFace
        case .failure: return .failure
        }
    }
}

/// Turns a captured frame into a face-identity embedding vector.
///
/// This is the **seam** that lets a future Core ML face-optimized model replace the
/// current Apple Vision feature-print embedder without touching the recognizer or the
/// enrollment store (ADR-0012 / the real ND-021). Anything conforming here must run
/// **entirely on-device** and never touch the network.
///
/// Returns a `FaceEmbeddingOutcome` tri-state: `.embedding` on success, `.noFace` when
/// Vision ran but found no face, and `.failure` on any error. The recognizer maps
/// `.failure` → `.error` (EC-10 conservative hold) and `.noFace` → absence — failures
/// are **never** conflated with "no face".
public protocol FaceEmbedding: Sendable {
    /// Detect the (largest) face in `frame` and return its embedding + liveness
    /// outcome (ND-041). Runs off the main actor. This is the sole requirement;
    /// `embedding(for:)` is derived from it by default.
    func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult
}

public extension FaceEmbedding {
    /// Score-free convenience that projects `embeddingWithLiveness(for:)` down to the
    /// original `FaceEmbeddingOutcome`. Keeps the App's `switch` on `.embedding([Float])`
    /// (Enrollment.swift) source-compatible — callers that don't need the liveness
    /// signal (enrollment) use this unchanged.
    func embedding(for frame: CapturedFrame) async -> FaceEmbeddingOutcome {
        await embeddingWithLiveness(for: frame).outcome
    }
}

/// Resolve the Vision source orientation to apply to the **RAW camera pixel buffer**
/// fed to `VNDetectFaceRectanglesRequest`.
///
/// Default is `CGImagePropertyOrientation.up`. It can be overridden **without a rebuild**
/// via `UserDefaults.standard` key `"visionOrientation"`, read as an `Int` rawValue:
///
/// - Valid values are `1...8` (`CGImagePropertyOrientation` rawValues), e.g.
///   `1` = `.up` (default), `6` = `.right` (90° CW), `8` = `.left`, `3` = `.down`.
/// - If the key is **absent**, or the value is **not** a valid rawValue (outside `1...8`,
///   e.g. `0` or `99`), we fall back to `.up`.
///
/// Tune on-device with, e.g. `defaults write com.nodonuts.app visionOrientation 6`.
///
/// This is a shared resolver so BOTH the identity embedder's detection pass and the
/// presence-only `FaceDetectionRecognizer` use the SAME orientation. Within one embed
/// call, detection + crop must use one resolved value so enrollment and matching stay
/// consistent. The already-upright cropped image feature print stays `.up` regardless.
///
/// Cheap (a single `UserDefaults` read); safe to call per detection pass.
public func resolvedVisionOrientation(
    defaults: UserDefaults = .standard,
    key: String = "visionOrientation"
) -> CGImagePropertyOrientation {
    // `object(forKey:)` distinguishes "absent" from a stored 0; `integer(forKey:)`
    // would map absent → 0 (an invalid rawValue), which also falls back to .up.
    guard defaults.object(forKey: key) != nil else { return .up }
    let raw = defaults.integer(forKey: key)
    guard raw >= 1, raw <= 8, let orientation = CGImagePropertyOrientation(rawValue: UInt32(raw)) else {
        return .up
    }
    return orientation
}

/// Resolve the cosine-similarity **match threshold** for identity recognition,
/// validating any user override before trusting it.
///
/// Mirrors `resolvedVisionOrientation`: a pure, testable resolver that reads a single
/// `UserDefaults` value and falls back to a safe `def` when the stored value is absent
/// or nonsensical. The App calls this instead of reading `matchThreshold` raw.
///
/// Validation — an override is accepted ONLY if it is a number strictly in `(0.0, 1.0)`:
/// - A threshold of `0.0` (or negative) is effectively **fail-open for identity**: any
///   face — including a stranger's — clears it, so identity checks stop meaning anything.
/// - A threshold of `1.0` (or above) demands a *perfect* cosine match, which live camera
///   frames never produce → the enrolled user never matches → **permanent lockout**.
///
/// Both extremes defeat the whole point, so either is rejected in favor of the safe
/// default `def` (typically `Config().matchThreshold`). Absent / non-numeric values also
/// fall back to `def`.
///
/// Cheap (a single `UserDefaults` read); safe to call per recognition pass.
public func resolvedMatchThreshold(
    default def: Double,
    defaults: UserDefaults = .standard,
    key: String = "matchThreshold"
) -> Double {
    // `object(forKey:)` distinguishes "absent" from a stored 0, and lets us reject
    // non-numeric junk (a stored String, etc.) rather than coercing it to 0.
    guard let value = defaults.object(forKey: key) as? NSNumber else { return def }
    let threshold = value.doubleValue
    // Reject the fail-open (<= 0) and permanent-lockout (>= 1) extremes; accept only
    // the safe open interval.
    guard threshold > 0.0, threshold < 1.0 else { return def }
    return threshold
}

/// `FaceEmbedding` backed by Apple Vision's `VNGenerateImageFeaturePrint` (ADR-0012).
///
/// Pipeline (all on-device, in memory):
/// 1. `VNDetectFaceRectanglesRequest` on the frame → pick the **largest** face by
///    bounding-box area. No faces → `nil`.
/// 2. Crop the pixel buffer to that face's box (with padding), via Core Image.
/// 3. `VNGenerateImageFeaturePrintRequest` on the crop → first `VNFeaturePrintObservation`.
/// 4. Extract a `[Float]` from the observation's `data` (only `.float32` prints).
///
/// Accuracy caveat: `VNGenerateImageFeaturePrint` is a **general** image feature print,
/// not a face-optimized embedding — separation is weaker than a dedicated face model.
/// Mitigated by a lenient threshold, multiple reference embeddings, and the presence
/// engine's debounce. The protocol seam lets a Core ML face model swap in later (ND-021).
///
/// Concurrency: `@unchecked Sendable`, mirroring `FaceDetectionRecognizer` — the
/// synchronous Vision `perform(_:)` calls are offloaded onto a dedicated serial
/// `DispatchQueue` via `withCheckedContinuation`, so the main actor is never blocked.
public final class VisionFeaturePrintEmbedder: FaceEmbedding, @unchecked Sendable {

    /// Dedicated serial queue so Vision's synchronous `perform` never runs on the
    /// main actor (mirrors `FaceDetectionRecognizer`).
    private let queue = DispatchQueue(label: "com.nodonuts.face-embedding")

    /// Reused Core Image context for cropping (creating one per call is expensive).
    private let ciContext = CIContext(options: nil)

    /// Fraction of the face box added as margin on each side before cropping, so the
    /// embedding sees a little context (hair/jaw) rather than a tight face-only crop.
    private let paddingFraction: CGFloat

    private let log = Logger(subsystem: "com.nodonuts.app", category: "recognition")

    public init(paddingFraction: CGFloat = 0.25) {
        self.paddingFraction = paddingFraction
    }

    public func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult {
        // Hop off the (main) actor onto our serial queue and suspend until done.
        // We capture the `@unchecked Sendable` `CapturedFrame` (not its non-Sendable
        // `CVPixelBuffer`) into the `@Sendable` closure and unwrap inside. All the
        // heavy image work (detect, crop, feature print, AND the liveness texture
        // score) happens here on the off-main queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<FaceEmbeddingResult, Never>) in
            queue.async { [self] in
                continuation.resume(returning: computeEmbedding(frame))
            }
        }
    }

    /// Synchronous embedding pipeline — only ever called on `queue`. Returns a
    /// `FaceEmbeddingOutcome`: `.noFace` only when detection ran and found zero faces;
    /// `.failure` for any error (no pixel buffer, thrown error, unexpected element
    /// type, crop failure); `.embedding` on success. Never crashes, never blocks the
    /// main actor.
    private func computeEmbedding(_ frame: CapturedFrame) -> FaceEmbeddingResult {
        // No pixel buffer is a capture/pipeline error, NOT "no face" (EC-10).
        guard let pixelBuffer = frame.pixelBuffer else { return .failure }

        // 1) Detect faces. Resolve the RAW-buffer source orientation ONCE per call
        // (default `.up`, overridable via the `visionOrientation` UserDefaults key —
        // see `resolvedVisionOrientation`). Shared with FaceDetectionRecognizer so
        // presence + identity agree. Detection + crop use the SAME resolved value so
        // enrollment and matching stay consistent.
        let orientation = resolvedVisionOrientation()

        let detect = VNDetectFaceRectanglesRequest()
        let detectHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        do {
            try detectHandler.perform([detect])
        } catch {
            // Detection threw → error, NOT "no face" (EC-10).
            log.error("face detection failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }

        let faces = detect.results ?? []
        // Largest face by normalized bounding-box area (EC-06: match against the
        // most prominent face in frame).
        guard let largest = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return .noFace  // detection ran, genuinely zero faces
        }

        // 2) Crop to the padded face box.
        //
        // CRITICAL (false-lock fix): detection ran in the ORIENTED coordinate space
        // (we passed `orientation` to the detect handler), so `largest.boundingBox`
        // is normalized against the ORIENTED image, not the raw pixel buffer. The
        // crop must therefore be taken from an image in that SAME oriented space, or
        // (for any non-.up override) the box maps onto the wrong region/rotation, the
        // feature print is garbage, and the enrolled user scores as a stranger → the
        // Mac false-locks on them.
        //
        // So: build the crop base by applying the SAME resolved `orientation` to the
        // buffer via `.oriented(_:)`. The oriented CIImage's coordinate space now
        // matches detection's, so the normalized bbox maps correctly. With the default
        // `.up`, `.oriented(.up)` is a no-op → behavior is byte-for-byte identical to
        // before (regression-safe); with e.g. `.right` the crop tracks the rotated
        // detection.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        // Extent of the ORIENTED image — the space the bbox and mapping live in.
        let orientedExtent = ciImage.extent
        let width = Int(orientedExtent.width)
        let height = Int(orientedExtent.height)

        // Vision bounding boxes are normalized with origin bottom-left. Convert to
        // pixel coordinates in the oriented image's space.
        let bb = largest.boundingBox
        let padX = bb.width * paddingFraction
        let padY = bb.height * paddingFraction
        var normRect = CGRect(
            x: bb.origin.x - padX,
            y: bb.origin.y - padY,
            width: bb.width + 2 * padX,
            height: bb.height + 2 * padY
        )
        // Clamp to [0,1] so padding can't push us off the buffer.
        normRect = normRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // Crop geometry failure → error, not "no face" (EC-10).
        guard !normRect.isNull, normRect.width > 0, normRect.height > 0 else { return .failure }

        // VNImageRectForNormalizedRect maps a normalized rect (bottom-left origin) to
        // pixel coordinates (also bottom-left origin) using the ORIENTED image's
        // dimensions — which matches the oriented CIImage's coordinate space, so we can
        // crop the oriented image directly.
        let pixelRect = VNImageRectForNormalizedRect(normRect, width, height)
        let cropRect = pixelRect.integral.intersection(orientedExtent)
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return .failure }

        let cropped = ciImage.cropped(to: cropRect)
        // Render into a concrete CGImage so the feature-print handler operates on the
        // crop alone (a lazily-cropped CIImage keeps the full extent otherwise).
        // Render failure → error, not "no face" (EC-10).
        guard let cgCrop = ciContext.createCGImage(cropped, from: cropRect) else { return .failure }

        // ND-041 liveness: compute the crop's texture score (variance-of-Laplacian)
        // on this same off-main queue. A flat photo / screen reproduction scores low;
        // a live face scores high.
        //
        // FIX #7 (compute-gating): the texture score costs a 128px grayscale render +
        // Laplacian pass on EVERY embed. It is only ever CONSUMED by the recognizer
        // when anti-spoof is enabled AND the face is enrolled AND it matches. The
        // embedder can't know "enrolled"/"matched", but it CAN cheaply check the
        // anti-spoof toggle — the common case (anti-spoof off, or the not-enrolled
        // presence-only path with the toggle off) then pays nothing. When disabled we
        // return the `.infinity` sentinel = "live/unknown", which `isLikelySpoof`
        // treats as LIVE (never flags). When enabled we compute for real, since a
        // match still needs it.
        //
        // FIX #5 (tighter region): the texture score must be computed on the INNER
        // face region, NOT the 0.25-padded embedding crop. Padding pulls in hair, jaw
        // edges, and background — high-frequency detail that varies wildly and can
        // DILUTE a live face's per-pixel skin detail below the floor (a plain
        // background under modest light collapses the average), risking a false
        // spoof-lock of the real user. The EMBEDDING keeps the padded crop (context
        // helps the feature print's separation); only the LIVENESS score uses the
        // face-only central region. We recover that region by cropping the central
        // portion of the already-rendered crop back to (approximately) the un-padded
        // Vision face box before scoring.
        let textureScore: Double
        if resolvedAntiSpoofEnabled() {
            textureScore = luminanceTextureScore(faceCoreRegion(of: cgCrop)) ?? .infinity
        } else {
            textureScore = .infinity   // anti-spoof off → skip the render+Laplacian entirely
        }

        // 3) Feature print on the cropped face. The crop is already upright pixels,
        // so use .up here regardless of the source orientation.
        let printRequest = VNGenerateImageFeaturePrintRequest()
        let printHandler = VNImageRequestHandler(cgImage: cgCrop, orientation: .up, options: [:])
        do {
            try printHandler.perform([printRequest])
        } catch {
            // Feature print threw → error, not "no face" (EC-10).
            log.error("feature print failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }

        guard let obs = printRequest.results?.first as? VNFeaturePrintObservation else {
            // A cropped face produced no feature print → error, not "no face" (EC-10).
            return .failure
        }

        // 4) Extract the vector. `VNElementType.float` is the 32-bit float layout.
        // Only handle float32 prints; never guess for other element types.
        // An unexpected element type is a failure (EC-10), not "no face".
        guard obs.elementType == .float, obs.elementCount > 0 else {
            log.error("unexpected feature-print element type; skipping")
            return .failure
        }

        let count = obs.elementCount
        var vector = [Float](repeating: 0, count: count)
        obs.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<count { vector[i] = base[i] }
        }
        return .embedding(vector, textureScore: textureScore)
    }

    /// Crop the central "face core" out of the padded embedding crop for the LIVENESS
    /// texture score (FIX #5). The embedding crop was built by expanding the Vision
    /// face box by `paddingFraction` on each side, so the un-padded face box occupies
    /// the central `1 / (1 + 2·paddingFraction)` fraction of the crop, centered. We cut
    /// that central window back out so the texture score sees face-only detail (skin,
    /// eyes, pores) rather than hair / jaw edges / background — which are high-frequency
    /// but identity-irrelevant and can dilute a live face's score below the floor.
    ///
    /// Note: the crop may have been clamped at the buffer edge (padding can't push off
    /// the image), so the real padded fraction is sometimes less than `paddingFraction`.
    /// Cutting the theoretical central window is still a strictly TIGHTER-or-equal region
    /// than the full crop, which is exactly the conservative direction we want here (it
    /// never enlarges the scored area, only shrinks toward the face). Returns the
    /// original image if the geometry degenerates (tiny crops) so we never lose the
    /// signal entirely.
    private func faceCoreRegion(of cgImage: CGImage) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        // Fraction of the crop occupied by the un-padded face box on each axis.
        let coreFraction = 1.0 / (1.0 + 2.0 * Double(paddingFraction))
        // Guard against a nonsensical (non-positive) padding making this a no-op or worse.
        guard coreFraction > 0, coreFraction < 1 else { return cgImage }
        let coreW = Int((Double(w) * coreFraction).rounded())
        let coreH = Int((Double(h) * coreFraction).rounded())
        // Need at least a 3x3 for the Laplacian; if the core is too small, keep the
        // full crop rather than return something un-scoreable (→ .infinity = live).
        guard coreW >= 3, coreH >= 3 else { return cgImage }
        let originX = (w - coreW) / 2
        let originY = (h - coreH) / 2
        let rect = CGRect(x: originX, y: originY, width: coreW, height: coreH)
        return cgImage.cropping(to: rect) ?? cgImage
    }

    /// Render `cgImage` to an 8-bit grayscale luminance buffer and return its
    /// variance-of-Laplacian texture score (see `faceTextureScore`). Returns `nil`
    /// if the grayscale draw fails — the caller then treats the frame as LIVE
    /// (conservative, never a spoof flag on our own failure). Runs on `queue`.
    private func luminanceTextureScore(_ cgImage: CGImage) -> Double? {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 3, height >= 3 else { return nil }

        // Downsize huge crops so the metric is cheap and roughly scale-stable; a
        // ~128px working size keeps enough high-frequency detail to separate flat
        // reproductions from live faces without per-pixel cost exploding.
        let maxDim = 128
        let scale = min(1.0, Double(maxDim) / Double(max(width, height)))
        let w = max(3, Int((Double(width) * scale).rounded()))
        let h = max(3, Int((Double(height) * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        let luminance = pixels.map(Double.init)
        return faceTextureScore(luminance: luminance, width: w, height: h)
    }
}
