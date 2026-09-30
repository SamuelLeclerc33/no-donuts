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
/// 1. `VNDetectFaceRectanglesRequest` → faces ranked by area; `selectFace` embeds the
///    largest, and the second largest only when the selection allows it (ND-059).
/// 2. Quality gate (ND-085): a face whose shorter side is under `minimumFaceSideFraction`
///    of the frame is dropped; none left is reported as `.noFace` (too far away).
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
/// so the main actor is never blocked. The synchronous initializers LOAD the model on
/// the calling thread; the app uses the async `load(...)` factory (ND-095) through a
/// `DeferredFaceEmbedder`, so launch never blocks the main thread. FaceScore (a CLI)
/// keeps the synchronous `compiledModelURL:` init.
public final class CoreMLFaceEmbedder: FaceEmbedding, @unchecked Sendable {

    public let descriptor: FaceEmbeddingModelDescriptor

    private let model: MLModel
    private let inputFeatureName: String
    private let queue = DispatchQueue(label: "com.nodonuts.coreml-face-embedding")
    private let ciContext = CIContext(options: nil)
    private let paddingFraction: CGFloat
    private let log = Logger(subsystem: Log.subsystem, category: "recognition")

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
        // Expected in the current repo when the model isn't bundled: log and fail so the
        // app falls back to the Vision embedder — never crash, never no-op silently.
        guard let url = Self.compiledModelURL(resourceName: resourceName, bundle: bundle) else { return nil }
        self.init(descriptor: descriptor, compiledModelURL: url, paddingFraction: paddingFraction)
    }

    /// Load a compiled Core ML model from an explicit **file URL**, bypassing bundle
    /// resource lookup.
    ///
    /// Same contract as the `resourceName:` initializer (which delegates here) — `nil` on
    /// a model that is absent, unloadable, has no image input, or the wrong output size.
    ///
    /// Exists so off-app tools can drive the EXACT production embedder rather than a
    /// reimplementation of it: `FaceScore` (the ND-056 threshold-tuning harness) scores
    /// image files through this same pipeline, so measured thresholds transfer to the app
    /// unchanged. A tuning number produced by a parallel implementation would not.
    public convenience init?(
        descriptor: FaceEmbeddingModelDescriptor = .facenetVGGFace2,
        compiledModelURL url: URL,
        paddingFraction: CGFloat = 0.25
    ) {
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: url, configuration: Self.modelConfiguration())
        } catch {
            Logger(subsystem: Log.subsystem, category: "recognition")
                .error("failed to load Core ML face model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let inputName = Self.validatedImageInputName(of: loaded, descriptor: descriptor) else { return nil }
        self.init(descriptor: descriptor, model: loaded, inputFeatureName: inputName,
                  paddingFraction: paddingFraction)
    }

    /// ND-095: load the compiled model OFF the calling thread (`MLModel.load(contentsOf:
    /// configuration:)`, async) — the launch path uses this so the main thread never
    /// blocks on the ~45 MB model (a cold Neural-Engine load is ~0.8 s on an M5 Pro;
    /// warm ~50 ms once Core ML has cached the compiled plan).
    ///
    /// Same contract as the synchronous initializers: `nil` (logged) when the resource
    /// is absent, fails to load, has no image input, or has the wrong output size (ND-087).
    public static func load(
        descriptor: FaceEmbeddingModelDescriptor = .facenetVGGFace2,
        resourceName: String,
        bundle: Bundle = .main,
        paddingFraction: CGFloat = 0.25
    ) async -> CoreMLFaceEmbedder? {
        guard let url = compiledModelURL(resourceName: resourceName, bundle: bundle) else { return nil }
        return await load(descriptor: descriptor, compiledModelURL: url, paddingFraction: paddingFraction)
    }

    /// ND-095: async load from an explicit compiled-model URL (see `load(resourceName:)`).
    public static func load(
        descriptor: FaceEmbeddingModelDescriptor = .facenetVGGFace2,
        compiledModelURL url: URL,
        paddingFraction: CGFloat = 0.25
    ) async -> CoreMLFaceEmbedder? {
        let loaded: MLModel
        do {
            loaded = try await MLModel.load(contentsOf: url, configuration: modelConfiguration())
        } catch {
            Logger(subsystem: Log.subsystem, category: "recognition")
                .error("failed to load Core ML face model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let inputName = validatedImageInputName(of: loaded, descriptor: descriptor) else { return nil }
        return CoreMLFaceEmbedder(descriptor: descriptor, model: loaded, inputFeatureName: inputName,
                                  paddingFraction: paddingFraction)
    }

    /// URL of the bundled compiled model, or `nil` (logged) when it isn't bundled. Cheap
    /// (a bundle lookup, no model load) — the launch path uses it to decide SYNCHRONOUSLY
    /// between "Core ML is coming" and the Vision fallback (ND-095).
    public static func compiledModelURL(resourceName: String, bundle: Bundle = .main) -> URL? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else {
            Logger(subsystem: Log.subsystem, category: "recognition")
                .notice("Core ML face model '\(resourceName, privacy: .public).mlmodelc' not bundled — falling back to the Vision embedder (ND-021 Phase 1)")
            return nil
        }
        return url
    }

    /// ND-095: explicit compute units. `.cpuAndNeuralEngine`, not the default `.all`:
    /// measured on an M5 Pro with this model, CPU+ANE gives the lowest steady inference
    /// (~0.6 ms vs ~2 ms CPU-only and ~5 ms CPU+GPU) and keeps the GPU out of the picture
    /// entirely — a 1 fps background app shouldn't wake the GPU, and the GPU path paid a
    /// ~3.6 s shader compile on its first inference. `.all` picked the ANE here too, but
    /// leaves Core ML free to route to the GPU; pinning it makes the power profile
    /// deterministic. Macs without a Neural Engine run on the CPU (~2 ms, still fine).
    public static func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    /// Validate a loaded model and return its image input feature name, or `nil` (logged)
    /// if it has no image input or its output doesn't match the descriptor (ND-087).
    private static func validatedImageInputName(of loaded: MLModel,
                                                descriptor: FaceEmbeddingModelDescriptor) -> String? {
        // Discover the single image input feature name so we don't hardcode it — a
        // later model swap may name it differently.
        guard let imageInput = loaded.modelDescription.inputDescriptionsByName.first(where: {
            $0.value.type == .image
        }) else {
            Logger(subsystem: Log.subsystem, category: "recognition")
                .error("Core ML face model has no image input feature — cannot use it")
            return nil
        }

        // ND-087: the model must produce the embedding size the descriptor claims
        // (512 for FaceNet). A different model shipped under the same descriptor
        // would store and compare vectors from another embedding space, so a
        // mismatch refuses the model here. The caller then falls back, and the
        // ND-073 identity-off state makes that visible.
        let multiArrayShapes = loaded.modelDescription.outputDescriptionsByName.values
            .filter { $0.type == .multiArray }
            .map { ($0.multiArrayConstraint?.shape ?? []).map { $0.intValue } }
        guard coreMLOutputDimensionMatches(multiArrayOutputShapes: multiArrayShapes,
                                           expected: descriptor.outputDimension) else {
            let found = multiArrayShapes.map { "\($0)" }.joined(separator: ", ")
            Logger(subsystem: Log.subsystem, category: Log.Category.recognition)
                .error("Core ML face model output shape [\(found, privacy: .public)] does not match the expected \(descriptor.outputDimension, privacy: .public)-d embedding for \(descriptor.version, privacy: .public) — refusing the model (ND-087)")
            return nil
        }
        return imageInput.key
    }

    private init(descriptor: FaceEmbeddingModelDescriptor, model: MLModel,
                 inputFeatureName: String, paddingFraction: CGFloat) {
        self.descriptor = descriptor
        self.model = model
        self.inputFeatureName = inputFeatureName
        self.paddingFraction = paddingFraction
    }

    public func embeddingWithLiveness(for frame: CapturedFrame,
                                      selecting selection: FaceSelection) async -> FaceEmbeddingResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<FaceEmbeddingResult, Never>) in
            queue.async { [self] in
                continuation.resume(returning: computeEmbedding(frame, selection: selection))
            }
        }
    }

    /// Synchronous pipeline — only ever called on `queue`. Same tri-state contract as
    /// `VisionFeaturePrintEmbedder`: `.noFace` only when detection ran and found no usable
    /// face; `.failure` for any error (EC-10); `.embedding` on success. Never crashes,
    /// never blocks the main actor. Which face(s) get embedded is the shared `selectFace`
    /// loop (ND-059). The liveness texture score (ND-072) comes from the shared
    /// `innerFaceTextureScore` when anti-spoof is enabled, else `.infinity`.
    private func computeEmbedding(_ frame: CapturedFrame, selection: FaceSelection) -> FaceEmbeddingResult {
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
        guard !faces.isEmpty else { return .noFace }

        // Work in the ORIENTED image space (same approach as the Vision embedder — see
        // its computeEmbedding for the orientation rationale).
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let orientedExtent = ciImage.extent

        // ND-059 + ND-085: the largest face(s) by area, THEN the quality gate. A face too
        // small in frame (user ~2 m+ away) is not embedded; none left counts as `.noFace`
        // (absence), not as a stranger.
        let boxes = faces.map(\.boundingBox)
        let ranked = rankedFaceCandidates(boxes: boxes, orientedExtent: orientedExtent,
                                          maxFaces: selection.maxFaces)

        return selectFace(
            facesDetected: faces.count,
            candidateCount: ranked.count,
            selection: selection,
            embed: { rank in
                let box = boxes[ranked[rank]]
                guard let vector = embedFace(box: box, ciImage: ciImage, orientedExtent: orientedExtent) else {
                    return .failure
                }
                // ND-116: the chosen face's box binds liveness evidence to its track.
                return .embedding(vector, textureScore: .infinity, faceBox: box)
            },
            texture: { rank in
                // ND-072 / ND-041 liveness (EC-12): score the INNER face region of the
                // ORIGINAL frame via the shared helper — the SAME pixels, crop geometry,
                // and ≤128px grayscale working scale as the Vision path, so
                // `spoofTextureFloor` means the same thing on both embedders. Deliberately
                // NOT computed from the model input (the black-padded square scaled to
                // 160×160, a different scale and region). Gated behind the cheap toggle
                // check. Any extraction failure inside the helper → `.infinity` (LIVE),
                // never a spoof. `selectFace` calls this at most once per face, twice per call (ND-059 confirmation).
                guard resolvedAntiSpoofEnabled() else { return .infinity }
                return innerFaceTextureScore(frame: pixelBuffer,
                                             faceBoundingBox: boxes[ranked[rank]],
                                             orientation: orientation,
                                             paddingFraction: paddingFraction,
                                             ciContext: ciContext)
            })
    }

    /// Square-crop one face, run the model, L2-normalize. `nil` on any error (the caller
    /// maps it to `.failure`, EC-10 — never "no face").
    private func embedFace(box: CGRect, ciImage: CIImage, orientedExtent: CGRect) -> [Float]? {
        // ND-085 undistorted crop: a square around the padded face, black-padded where
        // it leaves the frame, scaled uniformly to the model's input size. The model
        // folds its own normalization ((x-127.5)/128 for FaceNet), so we render plain
        // 0–255 RGB pixels. Changing this crop changed the embedding space, so the
        // descriptor version was bumped (facenet-vggface2-v2).
        guard let crop = squareFaceCrop(faceBoundingBox: box,
                                        paddingFraction: paddingFraction,
                                        orientedExtent: orientedExtent) else { return nil }
        let side = descriptor.inputSize > 0 ? descriptor.inputSize : 160
        guard let inputBuffer = renderRGBBuffer(squareFaceInputImage(from: ciImage, crop: crop, side: side),
                                                side: side) else { return nil }

        // Run the model.
        let vector: [Float]
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                inputFeatureName: MLFeatureValue(pixelBuffer: inputBuffer)
            ])
            let output = try model.prediction(from: provider)
            guard let emb = coreMLFirstMultiArrayOutput(output) else {
                log.error("Core ML face model produced no multi-array output")
                return nil
            }
            vector = emb
        } catch {
            log.error("Core ML face embedding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Defensive L2-normalize (FaceNet already normalizes; a swapped model may not).
        let normalized = l2Normalized(vector)
        return normalized.isEmpty ? nil : normalized
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
}

/// Extract the first `MLMultiArray` output of a Core ML prediction as a `[Float]`
/// (float32 / float16 / double / int32 element types all go through `floatValue`).
/// Non-multi-array outputs are skipped. Feature names are visited in sorted order so
/// the pick is deterministic (ND-087 already refuses a model with more than one
/// multi-array output, so in practice there is exactly one candidate). Returns `nil`
/// when there is no multi-array output or the first one is empty (→ `.failure`).
/// Public and pure so EngineCheck covers it with an `MLDictionaryFeatureProvider` (ND-110).
public func coreMLFirstMultiArrayOutput(_ output: MLFeatureProvider) -> [Float]? {
    for name in output.featureNames.sorted() {
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

/// L2-normalize a vector. Returns `[]` (the caller maps it to `.failure`) for an
/// empty vector, a zero norm, or any non-finite component — never a NaN-filled vector
/// that would poison every cosine score. Accumulates in `Double` so a 512-d float
/// vector with large components can't overflow the sum. Pure (ND-110).
public func l2Normalized(_ v: [Float]) -> [Float] {
    var sum = 0.0
    for x in v {
        let d = Double(x)
        guard d.isFinite else { return [] }
        sum += d * d
    }
    guard sum > 0, sum.isFinite else { return [] }
    let inv = 1.0 / sum.squareRoot()
    return v.map { Float(Double($0) * inv) }
}

/// ND-087: does a Core ML model's declared output match the embedding size the
/// descriptor expects? Pure, so EngineCheck covers it without a model file.
///
/// - `multiArrayOutputShapes`: the declared shape of each multi-array output (e.g.
///   `[[1, 512]]`). An empty shape means the model declares none (flexible).
/// - `expected`: `descriptor.outputDimension`. `0` means "no fixed size" and always
///   passes.
///
/// Passes only when there is exactly one multi-array output (the embedder reads the
/// first one it finds, so two would make the choice arbitrary) and the product of its
/// declared dimensions equals `expected`. An undeclared or non-positive shape fails:
/// the size can't be checked, so the model is not trusted.
public func coreMLOutputDimensionMatches(multiArrayOutputShapes: [[Int]], expected: Int) -> Bool {
    guard expected > 0 else { return true }
    guard multiArrayOutputShapes.count == 1, let shape = multiArrayOutputShapes.first,
          !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else { return false }
    return shape.reduce(1, *) == expected
}
