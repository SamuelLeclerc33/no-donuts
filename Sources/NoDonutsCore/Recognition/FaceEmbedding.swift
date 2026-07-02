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
    /// Detect the (largest) face in `frame` and return its embedding outcome. Runs off
    /// the main actor.
    func embedding(for frame: CapturedFrame) async -> FaceEmbeddingOutcome
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

    public func embedding(for frame: CapturedFrame) async -> FaceEmbeddingOutcome {
        // Hop off the (main) actor onto our serial queue and suspend until done.
        // We capture the `@unchecked Sendable` `CapturedFrame` (not its non-Sendable
        // `CVPixelBuffer`) into the `@Sendable` closure and unwrap inside.
        await withCheckedContinuation { (continuation: CheckedContinuation<FaceEmbeddingOutcome, Never>) in
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
    private func computeEmbedding(_ frame: CapturedFrame) -> FaceEmbeddingOutcome {
        // No pixel buffer is a capture/pipeline error, NOT "no face" (EC-10).
        guard let pixelBuffer = frame.pixelBuffer else { return .failure }

        // 1) Detect faces. TODO(recognition-orientation follow-up): front-camera
        // buffer orientation may need tuning; `.up` is a reasonable default and
        // matches FaceDetectionRecognizer. Detection + crop + feature print all use
        // the SAME orientation so the crop stays consistent.
        let orientation: CGImagePropertyOrientation = .up

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

        // 2) Crop the pixel buffer to the padded face box.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Vision bounding boxes are normalized with origin bottom-left. Convert to
        // pixel coordinates for the .up-oriented buffer.
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

        // VNImageRectForNormalizedRect maps a normalized rect (bottom-left origin)
        // to pixel coordinates (also bottom-left origin) — which matches CIImage's
        // coordinate space, so we can crop the CIImage directly.
        let pixelRect = VNImageRectForNormalizedRect(normRect, width, height)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropRect = pixelRect.integral.intersection(ciImage.extent)
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return .failure }

        let cropped = ciImage.cropped(to: cropRect)
        // Render into a concrete CGImage so the feature-print handler operates on the
        // crop alone (a lazily-cropped CIImage keeps the full extent otherwise).
        // Render failure → error, not "no face" (EC-10).
        guard let cgCrop = ciContext.createCGImage(cropped, from: cropRect) else { return .failure }

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
        return .embedding(vector)
    }
}
