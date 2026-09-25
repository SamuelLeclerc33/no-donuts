import Foundation
@preconcurrency import Vision
import CoreVideo
import CoreImage
import CoreML
import os

// Owner: cooper — Core ML face-identity embedder (ADR-0014, ND-021 Phase 1).
// Privacy: all on-device (Vision detection + a bundled Core ML model); frames analyzed
// in memory and discarded; NEVER any network, image, or embedding off the device.

/// `FaceEmbedding` backed by a **bundled Core ML face-recognition model** (ADR-0014),
/// the durable EC-03 fix: unlike `VisionFeaturePrintEmbedder`'s general image feature
/// print, this produces a face-IDENTITY embedding, so a look-alike colleague ("Marco")
/// no longer matches as the enrolled user (once the real model is bundled + tuned).
///
/// Pipeline (all on-device, in memory):
/// 1. `VNDetectFaceRectanglesRequest` → largest face (shared with the Vision embedder).
/// 2. Quality gate (ND-085): a largest face whose shorter side is under
///    `minimumFaceSideFraction` of the frame is reported as `.noFace` (too far away).
/// 3. Take an undistorted SQUARE crop (`squareFaceCrop`, ND-085) around the padded face.
///    Any part outside the frame is black-padded, never stretched. Scale it uniformly
///    to the model's `inputSize`×`inputSize` and feed it as an image input.
///    Preprocessing (`(x-127.5)/128` for FaceNet) is **folded into the Core ML model**
///    at conversion time (`ct.ImageType(scale:1/128, bias:-127.5/128)`), so we
///    hand the model raw 0–255 RGB pixels and it normalizes internally.
/// 4. Read the model's float output, L2-normalize DEFENSIVELY (FaceNet already
///    normalizes; a permissive-model swap might not), return the vector.
/// 5. Liveness (ND-072, EC-12): the shared `innerFaceTextureScore` on the ORIGINAL frame's
///    inner face region, gated by `resolvedAntiSpoofEnabled()`; failure → `.infinity`.
///
/// **Model-file independence (CRITICAL, ND-021 Phase 1).** The Core ML model is NOT in
/// the repo and CANNOT be downloaded/converted in the build environment. So this type is
/// a **failable initializer**: if the compiled model resource is absent (or fails to
/// load), `init?` returns `nil` and logs — the app must keep running with the wired
/// `VisionFeaturePrintEmbedder` default (main.swift). This whole file compiles and links
/// WITHOUT any `.mlmodelc` present. Bundling the real model + switching the default is a
/// Phase-2 follow-up (with gordon), gated on the user producing the converted file.
///
/// Alignment reality: we feed Vision face-RECTANGLE crops, NOT MTCNN 5-point aligned
/// faces (as `facenet-pytorch` normally expects). This is an accepted v1 approximation —
/// it costs some accuracy vs proper alignment and is part of why the threshold must be
/// re-tuned on device before this model is trusted for distribution (see the descriptor's
/// `thresholdIsTuned == false`).
///
/// Concurrency: `@unchecked Sendable`, mirroring `VisionFeaturePrintEmbedder` — the
/// synchronous Vision/Core ML calls run on a dedicated serial queue via a continuation,
/// so the main actor is never blocked.
public final class CoreMLFaceEmbedder: FaceEmbedding, @unchecked Sendable {

    public let descriptor: FaceEmbeddingModelDescriptor

    private let model: MLModel
    private let inputFeatureName: String
    private let queue = DispatchQueue(label: "com.nodonuts.coreml-face-embedding")
    private let ciContext = CIContext(options: nil)
    private let paddingFraction: CGFloat
    private let log = Logger(subsystem: "com.nodonuts.app", category: "recognition")

    /// Load a compiled Core ML model bundled as a resource.
    ///
    /// - Parameters:
    ///   - descriptor: the model this embedder implements (default `.facenetVGGFace2`).
    ///     Supplies the version tag, input size, and (un-tuned) default threshold.
    ///   - resourceName: base name of the bundled COMPILED model (`.mlmodelc`), e.g.
    ///     `"FaceNetVGGFace2"`. Compiling `.mlpackage`/`.mlmodel` → `.mlmodelc` happens at
    ///     build time; only the compiled form is loaded at runtime.
    ///   - bundle: where to look for the resource. Defaults to `.main` (the app bundle,
    ///     where the packaged `.app` will carry the compiled model). Kept as `.main`
    ///     rather than `Bundle.module` so this compiles WITHOUT a resources declaration
    ///     in Package.swift — gordon wires the actual bundling in Phase 2.
    ///   - paddingFraction: face-box margin, matching `VisionFeaturePrintEmbedder`.
    ///
    /// Returns `nil` (graceful failure, logged) when the model resource is ABSENT or fails
    /// to load — the caller keeps using `VisionFeaturePrintEmbedder`. This is the expected
    /// path in the current repo (no model file present).
    public convenience init?(
        descriptor: FaceEmbeddingModelDescriptor = .facenetVGGFace2,
        resourceName: String,
        bundle: Bundle = .main,
        paddingFraction: CGFloat = 0.25
    ) {
        guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else {
            // Expected in the current repo: the model isn't bundled. Log and fail so the
            // app falls back to the Vision embedder — never crash, never no-op silently.
            Logger(subsystem: "com.nodonuts.app", category: "recognition")
                .notice("Core ML face model '\(resourceName, privacy: .public).mlmodelc' not bundled — falling back to the Vision embedder (ND-021 Phase 1)")
            return nil
        }
        self.init(descriptor: descriptor, compiledModelURL: url, paddingFraction: paddingFraction)
    }

    /// Load a compiled Core ML model from an explicit **file URL**, bypassing bundle
    /// resource lookup.
    ///
    /// Same contract as the `resourceName:` initializer (this is the designated one it
    /// delegates to) — `nil` on a model that is absent, unloadable, or has no image input.
    ///
    /// Exists so off-app tools can drive the EXACT production embedder rather than a
    /// reimplementation of it: `FaceScore` (the ND-056 threshold-tuning harness) scores
    /// image files through this same pipeline, so measured thresholds transfer to the app
    /// unchanged. A tuning number produced by a parallel implementation would not.
    public init?(
        descriptor: FaceEmbeddingModelDescriptor = .facenetVGGFace2,
        compiledModelURL url: URL,
        paddingFraction: CGFloat = 0.25
    ) {
        self.descriptor = descriptor
        self.paddingFraction = paddingFraction

        do {
            let configuration = MLModelConfiguration()
            let loaded = try MLModel(contentsOf: url, configuration: configuration)
            self.model = loaded
            // Discover the single image input feature name so we don't hardcode it — a
            // later model swap may name it differently.
            guard let imageInput = loaded.modelDescription.inputDescriptionsByName.first(where: {
                $0.value.type == .image
            }) else {
                Logger(subsystem: "com.nodonuts.app", category: "recognition")
                    .error("Core ML face model has no image input feature — cannot use it")
                return nil
            }
            self.inputFeatureName = imageInput.key
        } catch {
            Logger(subsystem: "com.nodonuts.app", category: "recognition")
                .error("failed to load Core ML face model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<FaceEmbeddingResult, Never>) in
            queue.async { [self] in
                continuation.resume(returning: computeEmbedding(frame))
            }
        }
    }

    /// Synchronous pipeline — only ever called on `queue`. Same tri-state contract as
    /// `VisionFeaturePrintEmbedder`: `.noFace` only when detection ran and found zero
    /// faces; `.failure` for any error (EC-10); `.embedding` on success. Never crashes,
    /// never blocks the main actor. The liveness texture score (ND-072) comes from the
    /// shared `innerFaceTextureScore` when anti-spoof is enabled, else `.infinity`.
    private func computeEmbedding(_ frame: CapturedFrame) -> FaceEmbeddingResult {
        guard let pixelBuffer = frame.pixelBuffer else { return .failure }

        let orientation = resolvedVisionOrientation()
        let detect = VNDetectFaceRectanglesRequest()
        let detectHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try detectHandler.perform([detect])
        } catch {
            log.error("face detection failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }

        let faces = detect.results ?? []
        guard let largest = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return .noFace
        }

        // Work in the ORIENTED image space (same approach as the Vision embedder — see
        // its computeEmbedding for the orientation rationale).
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let orientedExtent = ciImage.extent

        // ND-085 quality gate: a face too small in frame (user ~2 m+ away) is not
        // embedded. It counts as `.noFace` (absence), not as a stranger.
        guard faceIsLargeEnough(faceBoundingBox: largest.boundingBox,
                                orientedExtent: orientedExtent) else { return .noFace }

        // ND-085 undistorted crop: a square around the padded face, black-padded where
        // it leaves the frame, scaled uniformly to the model's input size. The model
        // folds its own normalization ((x-127.5)/128 for FaceNet), so we render plain
        // 0–255 RGB pixels. Changing this crop changed the embedding space, so the
        // descriptor version was bumped (facenet-vggface2-v2).
        guard let crop = squareFaceCrop(faceBoundingBox: largest.boundingBox,
                                        paddingFraction: paddingFraction,
                                        orientedExtent: orientedExtent) else { return .failure }
        let side = descriptor.inputSize > 0 ? descriptor.inputSize : 160
        guard let inputBuffer = renderRGBBuffer(squareFaceInputImage(from: ciImage, crop: crop, side: side),
                                                side: side) else {
            return .failure
        }

        // Run the model.
        let vector: [Float]
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                inputFeatureName: MLFeatureValue(pixelBuffer: inputBuffer)
            ])
            let output = try model.prediction(from: provider)
            guard let emb = firstMultiArrayOutput(output) else {
                log.error("Core ML face model produced no multi-array output")
                return .failure
            }
            vector = emb
        } catch {
            log.error("Core ML face embedding failed: \(error.localizedDescription, privacy: .public)")
            return .failure
        }

        // Defensive L2-normalize (FaceNet already normalizes; a swapped model may not).
        let normalized = l2Normalized(vector)
        guard !normalized.isEmpty else { return .failure }

        // ND-072 / ND-041 liveness (EC-12): score the INNER face region of the ORIGINAL
        // frame via the shared helper — the SAME pixels, crop geometry, and ≤128px
        // grayscale working scale as the Vision path, so `spoofTextureFloor` means the
        // same thing on both embedders. Deliberately NOT computed from `inputBuffer`: that
        // is the black-padded square scaled to 160×160, a different scale and region.
        // Gated behind the cheap toggle check (skip the render when anti-spoof is off).
        // Any extraction failure inside the helper → `.infinity` (LIVE), never a spoof.
        let textureScore: Double
        if resolvedAntiSpoofEnabled() {
            textureScore = innerFaceTextureScore(frame: pixelBuffer,
                                                 faceBoundingBox: largest.boundingBox,
                                                 orientation: orientation,
                                                 paddingFraction: paddingFraction,
                                                 ciContext: ciContext)
        } else {
            textureScore = .infinity
        }
        return .embedding(normalized, textureScore: textureScore)
    }

    /// Render `image` (already placed at the origin and scaled to `side`×`side` by
    /// `squareFaceInputImage`) into a `side`×`side` 32-bit BGRA CVPixelBuffer suitable
    /// as a Core ML image input.
    private func renderRGBBuffer(_ image: CIImage, side: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }

    /// Extract the first `MLMultiArray` output as a `[Float]`. Handles the common float32
    /// / float16 / double element types.
    private func firstMultiArrayOutput(_ output: MLFeatureProvider) -> [Float]? {
        for name in output.featureNames {
            guard let value = output.featureValue(for: name),
                  value.type == .multiArray,
                  let arr = value.multiArrayValue else { continue }
            let count = arr.count
            guard count > 0 else { return nil }
            var result = [Float](repeating: 0, count: count)
            for i in 0..<count { result[i] = arr[i].floatValue }
            return result
        }
        return nil
    }

    /// L2-normalize a vector; returns `[]` (→ failure) if the norm is zero/non-finite.
    private func l2Normalized(_ v: [Float]) -> [Float] {
        var sum = 0.0
        for x in v {
            let d = Double(x)
            guard d.isFinite else { return [] }
            sum += d * d
        }
        guard sum > 0 else { return [] }
        let inv = 1.0 / sum.squareRoot()
        return v.map { Float(Double($0) * inv) }
    }
}
