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
/// 2. Crop the padded face box (same crop path as the Vision embedder).
/// 3. Resize the crop to the model's `inputSize`×`inputSize` and feed it as an image
///    input. Preprocessing (`(x-127.5)/128` for FaceNet) is **folded into the Core ML
///    model** at conversion time (`ct.ImageType(scale:1/128, bias:-127.5/128)`), so we
///    hand the model raw 0–255 RGB pixels and it normalizes internally.
/// 4. Read the model's float output, L2-normalize DEFENSIVELY (FaceNet already
///    normalizes; a permissive-model swap might not), return the vector.
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
    /// never blocks the main actor. Liveness texture score is left as the `.infinity`
    /// "live/unknown" sentinel here (anti-spoof scoring stays with the Vision path for
    /// now; wiring texture scoring into this model is a follow-up with wiggum).
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

        // Crop to the padded face box in the ORIENTED image space (same approach as the
        // Vision embedder — see its computeEmbedding for the orientation rationale).
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let orientedExtent = ciImage.extent
        let width = Int(orientedExtent.width)
        let height = Int(orientedExtent.height)

        let bb = largest.boundingBox
        let padX = bb.width * paddingFraction
        let padY = bb.height * paddingFraction
        var normRect = CGRect(
            x: bb.origin.x - padX,
            y: bb.origin.y - padY,
            width: bb.width + 2 * padX,
            height: bb.height + 2 * padY
        )
        normRect = normRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normRect.isNull, normRect.width > 0, normRect.height > 0 else { return .failure }

        let pixelRect = VNImageRectForNormalizedRect(normRect, width, height)
        let cropRect = pixelRect.integral.intersection(orientedExtent)
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return .failure }

        let cropped = ciImage.cropped(to: cropRect)

        // Resize the crop to the model's expected square input. The model folds its own
        // normalization ((x-127.5)/128 for FaceNet), so we render plain 0–255 RGB pixels.
        let side = descriptor.inputSize > 0 ? descriptor.inputSize : 160
        guard let inputBuffer = resizedRGBBuffer(from: cropped, cropRect: cropRect, side: side) else {
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
        return .embedding(normalized, textureScore: .infinity)
    }

    /// Render `image` (cropped to `cropRect`) into a `side`×`side` 32-bit BGRA
    /// CVPixelBuffer suitable as a Core ML image input. Core Image handles the resize.
    private func resizedRGBBuffer(from image: CIImage, cropRect: CGRect, side: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        // Scale the crop's extent to fill side×side (translate to origin, then scale).
        let sx = CGFloat(side) / cropRect.width
        let sy = CGFloat(side) / cropRect.height
        let transformed = image
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(transformed, to: buffer)
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
