import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
@preconcurrency import Vision

// Owner: cooper (with wiggum's security hat). Basic anti-spoofing / liveness.
// Backlog: ND-041. Edge case: EC-12. Privacy: pure computation on in-memory
// luminance samples; no image or embedding is stored or transmitted, no network.

// MARK: - Threat model & rationale (wiggum)
//
// A printed photo, or a face shown on a phone/monitor, held up to the camera tends
// to have LOWER high-frequency texture detail and flatter micro-contrast than a live
// face at the same crop size: paper/print halftoning and screen reproduction lose
// fine skin/pore/eyelash detail, add blur, and (for screens) low-pass the image.
//
// We exploit that with a single, cheap, CONSERVATIVE signal: the variance of a
// discrete-Laplacian high-pass over the face crop's luminance ("focus"/sharpness
// metric). A live face crop has meaningful high-frequency energy; a clearly
// degraded/flat reproduction has very little.
//
// CONSERVATIVE bias (non-negotiable, EC-12): we only ever FLAG a spoof when the
// texture score is below a VERY LOW floor — i.e. the crop is unambiguously flat.
// When in doubt we treat the input as LIVE and do NOT flag. The cost of a false
// spoof flag is a false lock of the real user (unacceptable); the cost of a missed
// spoof is that a high-quality photo passes (acceptable for a v1 that is explicitly
// NOT hardened). This check is defeatable by a sharp, high-resolution photo or a
// high-DPI screen at the right size — it is a speed-bump, not a guarantee. See EC-12.

/// Default texture floor below which a face crop is treated as a likely spoof.
///
/// Deliberately VERY LOW: this is the variance of an 8-bit-luminance Laplacian
/// response (units are luminance² in `[0, 255]` space). A normally-lit live face
/// crop produces scores in the hundreds-to-thousands range; a flat print/screen
/// reproduction collapses toward single/low-double digits. A floor of `12.0` sits
/// well under any plausible live face while still catching clearly flat inputs.
///
/// This value is a defensible STARTING POINT and MUST be tuned on real on-device
/// data (lighting, camera, crop size all shift the absolute scale). It — and the
/// whole check — is user-toggleable via the `antiSpoofEnabled` default (Settings).
/// Bias tuning ALWAYS toward a lower floor: never risk flagging a live face.
public let defaultSpoofTextureFloor: Double = 12.0

/// Resolve whether anti-spoofing is enabled, from `UserDefaults`.
///
/// Defaults to **true** (ND-041 decision: anti-spoof ON by default, conservative).
/// Absent key → enabled. Only an explicit stored `false` disables it. Mirrors the
/// other resolvers in this module: a single cheap `UserDefaults` read, safe per call.
public func resolvedAntiSpoofEnabled(
    defaults: UserDefaults = .standard,
    key: String = "antiSpoofEnabled"
) -> Bool {
    // Absent → default ON. `object(forKey:)` distinguishes "absent" from a stored
    // `false`, so we don't accidentally disable when the key was never written.
    guard defaults.object(forKey: key) != nil else { return true }
    return defaults.bool(forKey: key)
}

/// Resolve the spoof texture **floor** for the liveness check, from `UserDefaults`.
///
/// Mirrors `resolvedMatchThreshold` / `resolvedVisionOrientation` / `resolvedAntiSpoofEnabled`:
/// a pure, testable resolver that reads a single `UserDefaults` value and falls back
/// to a safe `def` (typically `defaultSpoofTextureFloor` = 12.0) when the stored value
/// is absent or nonsensical. The recognizer calls this PER CALL so the floor is tunable
/// live (no relaunch) via `defaults write com.nodonuts.app spoofTextureFloor <n>`.
///
/// Validation — an override is accepted ONLY if it is a **finite, strictly-positive**
/// number:
/// - Absent / non-numeric → `def` (safe default).
/// - `0`, negative, NaN, ±infinity → `def`. A floor of `0` or below could never flag
///   anything anyway (scores are `>= 0`); we normalize such junk back to the tuned
///   default rather than silently disable the whole check via a malformed value.
///
/// To effectively DISABLE the check without the toggle, set a very LOW positive floor
/// (e.g. `defaults write com.nodonuts.app spoofTextureFloor 0.0001`): a valid tiny
/// positive value is accepted, and no real crop scores below it, so nothing is flagged.
/// (Setting `0` or negative is rejected → default, so a *tiny positive* is the escape
/// hatch, on purpose — it keeps the "reject fail-open junk" rule intact.)
///
/// Cheap (a single `UserDefaults` read); safe to call per recognition pass.
public func resolvedSpoofTextureFloor(
    default def: Double = defaultSpoofTextureFloor,
    defaults: UserDefaults = .standard,
    key: String = "spoofTextureFloor"
) -> Double {
    // `object(forKey:)` distinguishes "absent" from a stored 0, and lets us reject
    // non-numeric junk (a stored String, etc.) rather than coercing it to 0.
    guard let value = defaults.object(forKey: key) as? NSNumber else { return def }
    let floor = value.doubleValue
    // Accept only a finite, strictly-positive floor; else fall back to the safe default.
    guard floor.isFinite, floor > 0.0 else { return def }
    return floor
}

/// Compute a texture / sharpness score for a face crop from its luminance samples.
///
/// Pure and testable: takes a row-major buffer of 8-bit luminance values (`0...255`
/// as `Double`) plus its `width`/`height`, and returns the variance of a discrete
/// Laplacian (`4·center − up − down − left − right`) over all interior pixels. This
/// is the classic "variance of Laplacian" focus/detail metric — higher means more
/// high-frequency texture (a live, in-focus face); near-zero means flat/blurred
/// (a degraded photo or screen reproduction).
///
/// Defensive: returns `0` (which, being below any sane floor, biases toward a spoof
/// flag ONLY under conservative gating — see how the recognizer never flags on the
/// not-enrolled path and only on a genuine match) when the input is too small or
/// malformed. Non-finite samples are treated as `0` contribution. The caller decides
/// what a `0` means via `isLikelySpoof`; on a real crop this function never returns 0.
public func faceTextureScore(luminance: [Double], width: Int, height: Int) -> Double {
    // Need at least a 3x3 so there is one interior pixel with all four neighbors.
    guard width >= 3, height >= 3, luminance.count == width * height else { return 0 }

    var sum = 0.0
    var sumSq = 0.0
    var n = 0

    // Interior pixels only (skip the 1-px border so every neighbor exists).
    for y in 1..<(height - 1) {
        let row = y * width
        let up = row - width
        let down = row + width
        for x in 1..<(width - 1) {
            let c = luminance[row + x]
            let l = luminance[row + x - 1]
            let r = luminance[row + x + 1]
            let u = luminance[up + x]
            let d = luminance[down + x]
            let lap = 4.0 * c - l - r - u - d
            guard lap.isFinite else { continue }
            sum += lap
            sumSq += lap * lap
            n += 1
        }
    }

    guard n > 0 else { return 0 }
    let mean = sum / Double(n)
    let variance = sumSq / Double(n) - mean * mean
    // Numerical floor: variance is non-negative by definition; clamp tiny negatives
    // from float error to 0.
    return variance.isFinite && variance > 0 ? variance : 0
}

/// Decide whether a texture score indicates a likely spoof (flat photo / screen).
///
/// Pure, total, and the SINGLE place the conservative bias lives: a crop is flagged
/// ONLY when its `textureScore` is STRICTLY below `floor`. A score exactly at or
/// above the floor is treated as LIVE (not flagged). Callers gate this further
/// (enrolled + matching only) so a live face is never false-locked (EC-12).
public func isLikelySpoof(textureScore: Double, floor: Double = defaultSpoofTextureFloor) -> Bool {
    // Strictly-below → flag. `>=` (incl. exactly-at-floor) → live. Non-finite floor
    // is treated as "no floor" (never flag) to fail toward LIVE.
    guard floor.isFinite else { return false }
    return textureScore < floor
}

// MARK: - Shared inner-face texture extraction (ND-072)
//
// ONE implementation of "which pixels does the liveness score look at", used by BOTH
// embedders (`VisionFeaturePrintEmbedder` and `CoreMLFaceEmbedder`). Scoring the same
// pixels at the same working scale on both paths is what keeps `defaultSpoofTextureFloor`
// meaningful regardless of which embedder is active: the score is taken from the ORIGINAL
// frame (never from the Core ML model's resized/stretched input buffer), cropped to the
// Vision face box in the same oriented space detection ran in.

/// Pixel-space crop rect for a Vision face box expanded by `paddingFraction` on each
/// side, in the ORIENTED image space (bottom-left origin, like Core Image).
///
/// Shared by both embedders (their embedding crops) and by `innerFaceTextureScore`, so
/// the liveness score's geometry can never drift from the embedding crop's. The padded
/// normalized rect is clamped to `[0,1]` (padding can't push off the buffer), mapped via
/// `VNImageRectForNormalizedRect` against the oriented dimensions, snapped to integral
/// pixels, and clamped to `orientedExtent`. Returns `nil` when the geometry degenerates
/// (callers map that to `.failure` for the embedding, `.infinity` for liveness).
public func paddedFaceCropRect(
    faceBoundingBox bb: CGRect,
    paddingFraction: CGFloat,
    orientedExtent: CGRect
) -> CGRect? {
    let padX = bb.width * paddingFraction
    let padY = bb.height * paddingFraction
    var normRect = CGRect(
        x: bb.origin.x - padX,
        y: bb.origin.y - padY,
        width: bb.width + 2 * padX,
        height: bb.height + 2 * padY
    )
    normRect = normRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !normRect.isNull, normRect.width > 0, normRect.height > 0 else { return nil }

    let pixelRect = VNImageRectForNormalizedRect(normRect, Int(orientedExtent.width), Int(orientedExtent.height))
    let cropRect = pixelRect.integral.intersection(orientedExtent)
    guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return nil }
    return cropRect
}

/// Liveness texture score of the INNER face region of an already-rendered PADDED face
/// crop (the crop produced from `paddedFaceCropRect` with the same `paddingFraction`).
///
/// Cuts the central "face core" back out of the padded crop (FIX #5: hair / jaw edges /
/// background are high-frequency but identity-irrelevant and can dilute a live face's
/// per-pixel skin detail below the floor), renders it to 8-bit grayscale at a ≤128px
/// working size, and returns `faceTextureScore` of that. Returns `nil` if the grayscale
/// render fails or the crop is too small — callers map `nil` to `.infinity` (LIVE).
///
/// `VisionFeaturePrintEmbedder` calls this directly on the `CGImage` it already renders
/// for the feature print (no second render); `innerFaceTextureScore` wraps it for callers
/// that only have the frame + face box.
public func faceCoreTextureScore(paddedCrop: CGImage, paddingFraction: CGFloat) -> Double? {
    luminanceTextureScore(faceCoreRegion(of: paddedCrop, paddingFraction: paddingFraction))
}

/// Liveness texture score for the Vision face `faceBoundingBox` in `frame`, computed on
/// the INNER face region of the ORIGINAL frame (ND-072).
///
/// - Parameters:
///   - frame: the raw camera pixel buffer (the same one detection ran on).
///   - faceBoundingBox: Vision's normalized (bottom-left origin) face box, as returned
///     by a `VNDetectFaceRectanglesRequest` run with `orientation`.
///   - orientation: the SAME resolved orientation detection used, so the box maps onto
///     the right pixels (see `resolvedVisionOrientation`).
///   - paddingFraction: the embedder's padding; the padded crop is rebuilt exactly as the
///     embedding crop is, then its core is scored — identical pixels to the Vision path.
///   - ciContext: a reusable Core Image context (callers pass their per-embedder one).
///
/// **Conservative (EC-12, non-negotiable):** ANY extraction failure or ambiguity —
/// non-finite / empty box, degenerate crop geometry, render failure, too-small region,
/// non-finite score — returns `.infinity`, the "live/unknown" sentinel that
/// `isLikelySpoof` never flags. Our own failure must never false-lock the real user.
/// A genuinely flat face region still returns its real (low) score.
public func innerFaceTextureScore(
    frame: CVPixelBuffer,
    faceBoundingBox bb: CGRect,
    orientation: CGImagePropertyOrientation,
    paddingFraction: CGFloat = 0.25,
    ciContext: CIContext = CIContext(options: nil)
) -> Double {
    guard bb.origin.x.isFinite, bb.origin.y.isFinite,
          bb.width.isFinite, bb.height.isFinite,
          bb.width > 0, bb.height > 0,
          paddingFraction.isFinite, paddingFraction >= 0 else { return .infinity }

    let ciImage = CIImage(cvPixelBuffer: frame).oriented(orientation)
    guard let cropRect = paddedFaceCropRect(faceBoundingBox: bb,
                                            paddingFraction: paddingFraction,
                                            orientedExtent: ciImage.extent),
          let cgCrop = ciContext.createCGImage(ciImage.cropped(to: cropRect), from: cropRect),
          let score = faceCoreTextureScore(paddedCrop: cgCrop, paddingFraction: paddingFraction),
          score.isFinite else { return .infinity }
    return score
}

/// Crop the central "face core" out of the padded embedding crop (FIX #5). The crop was
/// built by expanding the Vision face box by `paddingFraction` on each side, so the
/// un-padded face box occupies the central `1 / (1 + 2·paddingFraction)` fraction of the
/// crop, centered.
///
/// If the crop was clamped at the buffer edge the real padded fraction is smaller, so the
/// theoretical central window is a strictly TIGHTER-or-equal region than the full crop —
/// the conservative direction (it only shrinks toward the face). Returns the original
/// image if the geometry degenerates (tiny crops) so the signal is never lost entirely.
private func faceCoreRegion(of cgImage: CGImage, paddingFraction: CGFloat) -> CGImage {
    let w = cgImage.width
    let h = cgImage.height
    let coreFraction = 1.0 / (1.0 + 2.0 * Double(paddingFraction))
    guard coreFraction > 0, coreFraction < 1 else { return cgImage }
    let coreW = Int((Double(w) * coreFraction).rounded())
    let coreH = Int((Double(h) * coreFraction).rounded())
    // Need at least a 3x3 for the Laplacian; if the core is too small, keep the full crop.
    guard coreW >= 3, coreH >= 3 else { return cgImage }
    let originX = (w - coreW) / 2
    let originY = (h - coreH) / 2
    let rect = CGRect(x: originX, y: originY, width: coreW, height: coreH)
    return cgImage.cropping(to: rect) ?? cgImage
}

/// Render `cgImage` to an 8-bit grayscale luminance buffer at a ≤128px working size and
/// return its variance-of-Laplacian texture score (see `faceTextureScore`). Returns `nil`
/// if the image is too small or the grayscale draw fails (caller → LIVE).
private func luminanceTextureScore(_ cgImage: CGImage) -> Double? {
    let width = cgImage.width
    let height = cgImage.height
    guard width >= 3, height >= 3 else { return nil }

    // Downsize huge crops so the metric is cheap and roughly scale-stable.
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
