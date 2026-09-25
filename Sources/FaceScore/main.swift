import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import NoDonutsCore

// Owner: cooper (metric) + gordon (target). Backlog: ND-021 Phase 2, ND-056.
// Privacy: reads ONLY the local image files you point it at, embeds them in memory,
// prints numbers. No network, no image or embedding ever written anywhere.
//
// Offline face-scoring harness — the measurement substrate for a DATA-DRIVEN
// `matchThreshold` (ND-056) and for flipping `thresholdIsTuned` on a descriptor.
//
// Why this exists: live per-tick logging (ND-024) gives a rich GENUINE score
// distribution for free, but it can never produce the IMPOSTOR distribution — that
// needs other people's faces in front of the camera on cue. Genuine-only data bounds
// the false-REJECT rate and says nothing about where false-ACCEPT begins, so it cannot
// justify a threshold. This harness scores still images instead, so an impostor set is
// a folder of photos rather than a scheduling problem.
//
// CRITICAL: it drives the REAL `CoreMLFaceEmbedder` (via `compiledModelURL:`), not a
// reimplementation — same Vision detection, same padded crop, same resize, same
// L2-normalize, same `cosineSimilarity`. Numbers measured here therefore transfer to
// the running app unchanged. A parallel implementation would silently measure a
// different pipeline.
//
// Usage:
//   swift run FaceScore --model <path/to/FaceNetVGGFace2.mlmodelc> face-data
//   swift run FaceScore --model <...> --enrolled <label> face-data
//
// Layout — one subdirectory per person, any number of images each. Keep photos in
// `face-data/` at the repo root: it is GIT-IGNORED (ND-105), so other people's faces
// can't be committed by accident (`faces/` is ignored too, as an alias):
//   face-data/sam/*.jpg        <- the enrolled user
//   face-data/marco/*.jpg      <- the EC-03 look-alike
//   face-data/stranger-1/*.jpg
//
// Parity with the app (ND-094): each file's EXIF orientation is baked in at decode so
// the buffer is upright, then the embedder applies the APP's `visionOrientation`
// (read from the `com.nodonuts.app` defaults domain, not FaceScore's own), exactly as
// it does to a raw camera frame. The "current threshold" reported is the app's
// effective one (`resolvedMatchThreshold(for:)`, per-model override validated, ND-076).
//
// Modes:
//   pairwise (default) — every image vs every other. GENUINE = same label, IMPOSTOR =
//     different label. Maximum data from a small set; the symmetric view of the space.
//   --enrolled <label> — mimics PRODUCTION exactly: take that label's first
//     `--references N` images as the enrolled reference set, then score every remaining
//     image as `max(cosine vs each reference)`, which is what `IdentityRecognizer` does.
//     This is the mode whose threshold you should actually ship.

// MARK: - CLI

struct Options {
    var modelPath: String?
    var imageDir: String?
    var enrolledLabel: String?
    var referenceCount: Int = 5
    var verbose = false
}

func parseArguments(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--model":
            i += 1; opts.modelPath = i < argv.count ? argv[i] : nil
        case "--enrolled":
            i += 1; opts.enrolledLabel = i < argv.count ? argv[i] : nil
        case "--references":
            i += 1; opts.referenceCount = i < argv.count ? (Int(argv[i]) ?? 5) : 5
        case "--verbose", "-v":
            opts.verbose = true
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            if opts.imageDir == nil { opts.imageDir = argv[i] }
        }
        i += 1
    }
    return opts
}

func printUsage() {
    print("""
    FaceScore — offline face-embedding scoring harness (ND-056 threshold tuning)

      swift run FaceScore --model <FaceNetVGGFace2.mlmodelc> [options] <imageDir>

    Options:
      --model <path>       compiled .mlmodelc to load (required)
      --enrolled <label>   production-shaped run: <label> is the enrolled user
      --references <n>     reference vectors for --enrolled mode (default 5)
      --verbose            per-image and per-pair detail

    <imageDir> holds ONE SUBDIRECTORY PER PERSON. Use face-data/ at the repo root —
    it is git-ignored (ND-105; faces/ is ignored too), so photos are never committed:
      face-data/sam/*.jpg  face-data/marco/*.jpg  face-data/stranger-1/*.jpg

    A threshold is endorsed only with >= \(ThresholdStudyRequirements.defaultMinimumGenuineSamples) genuine and >= \(ThresholdStudyRequirements.defaultMinimumImpostorSamples) impostor scores,
    >= \(ThresholdStudyRequirements.defaultMinimumImpostorIdentities) distinct impostor people, and a gap (genuine min - impostor max) >= \(ThresholdStudyRequirements.defaultMinimumSeparationMargin).

    EXIF orientation is applied per file; the app's visionOrientation and per-model
    threshold override are read from the com.nodonuts.app defaults domain.
    """)
}

// MARK: - Async bridge

/// Run an async operation to completion from this straight-line script and return its
/// value.
///
/// Safe here specifically because `CoreMLFaceEmbedder` does its work on its OWN serial
/// queue and never hops back to the main actor — so blocking the main thread on the
/// semaphore cannot deadlock against it. This shortcut belongs to a batch tool, not to
/// the app: the app must never block the main actor (that's the whole reason the
/// embedder is async in the first place).
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

// MARK: - Image loading

/// The shared Core Image context used to render decoded files into pixel buffers.
/// Purely local rendering; intermediates are not cached (no image data lingers).
let renderContext = CIContext(options: [.cacheIntermediates: false])

/// A decoded, upright image file plus the EXIF orientation that was applied to it.
struct LoadedImage {
    let buffer: CVPixelBuffer
    let exifOrientation: CGImagePropertyOrientation
}

/// Decode an image file to a `CVPixelBuffer` in the SAME 32BGRA format the camera
/// delivers (`CameraController`), so the embedder's Core Image path behaves identically
/// on a file and on a live frame. Anything ImageIO can read works (jpg/png/heic/tiff).
///
/// EXIF orientation (ND-094): `CGImageSourceCreateImageAtIndex` returns the SENSOR
/// pixels, ignoring `kCGImagePropertyOrientation` — a portrait phone photo arrives
/// sideways, Vision finds no face (or a rotated one), and the study silently measures
/// a different pipeline from the app. So the orientation is read from the file's
/// properties and baked into the buffer, which comes out upright. The embedder then
/// applies the app's `visionOrientation` on top, as it does to a raw camera frame.
///
/// Returns `nil` on an unreadable/undecodable file — the caller reports and skips it
/// rather than silently scoring fewer images than you think.
func loadPixelBuffer(_ url: URL) -> LoadedImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }

    var exif = CGImagePropertyOrientation.up
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
       let parsed = CGImagePropertyOrientation(rawValue: raw) {
        exif = parsed
    }

    var image = CIImage(cgImage: cgImage).oriented(exif)
    // Normalize the extent to the origin so rendering covers the buffer exactly.
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                    y: -image.extent.minY))
    let width = Int(image.extent.width.rounded())
    let height = Int(image.extent.height.rounded())
    guard width > 0, height > 0 else { return nil }

    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    renderContext.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
    return LoadedImage(buffer: buffer, exifOrientation: exif)
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]

/// One embedded image: which person it belongs to, where it came from, its vector.
struct Sample {
    let label: String
    let path: String
    let vector: [Float]
}

// MARK: - Reporting
//
// The statistics and the threshold recommendation itself live in NoDonutsCore
// (`ThresholdAnalysis.swift`) so `EngineCheck` covers them — a shipped threshold rests
// on that arithmetic. Everything below is presentation only.

func format(_ value: Double?) -> String {
    guard let value else { return "   n/a" }
    return String(format: "%6.4f", value)
}

func describe(_ name: String, _ dist: ScoreDistribution) {
    let label = name.padding(toLength: 10, withPad: " ", startingAt: 0)
    guard !dist.isEmpty else {
        print("    \(label) — none")
        return
    }
    print("    \(label) n=\(String(dist.count).padding(toLength: 6, withPad: " ", startingAt: 0))"
          + " min=\(format(dist.minimum))  p1=\(format(dist.percentile(0.01)))"
          + "  p5=\(format(dist.percentile(0.05)))  mean=\(format(dist.mean))"
          + "  p95=\(format(dist.percentile(0.95)))  max=\(format(dist.maximum))"
          + "  sd=\(format(dist.standardDeviation))")
}

func printSweep(genuine: ScoreDistribution, impostor: ScoreDistribution) {
    print("\n  threshold sweep")
    print("    thresh    FRR (false lock)    FAR (stranger accepted)")
    var threshold = 0.20
    while threshold <= 0.951 {
        let frr = falseRejectRate(genuine: genuine, at: threshold)
        let far = falseAcceptRate(impostor: impostor, at: threshold)
        let clean = (frr == 0 && far == 0) ? "   <- no measured error" : ""
        print(String(format: "    %5.2f     %@             %@%@",
                     threshold,
                     frr.map { String(format: "%6.2f%%", $0 * 100) } ?? "   n/a",
                     far.map { String(format: "%6.2f%%", $0 * 100) } ?? "   n/a",
                     clean))
        threshold += 0.05
    }
}

func report(
    _ recommendation: ThresholdRecommendation,
    descriptor: FaceEmbeddingModelDescriptor,
    effectiveThreshold: Double
) {
    print("\n  recommendation")
    let current = String(format: "    App's current threshold: %.2f effective (model default %.2f, tuned=%@)",
                         effectiveThreshold, descriptor.defaultMatchThreshold,
                         descriptor.thresholdIsTuned ? "yes" : "no")
    switch recommendation {
    case let .insufficientData(_, shortfalls):
        print("    ================================================================")
        print("    REFUSED — NO THRESHOLD ENDORSED (insufficient evidence)")
        print("    ================================================================")
        if shortfalls.isEmpty, let reason = recommendation.refusalReason {
            print("    - \(reason)")
        }
        for shortfall in shortfalls { print("    - \(shortfall)") }
        print(current)
        print("    DO NOT set `thresholdIsTuned = true`. Fix every item above and re-run.")

    case let .cleanSeparation(threshold, margin, impostorMaximum, genuineMinimum):
        print(String(format: "    CLEAN SEPARATION — impostor max %.4f < genuine min %.4f (margin %.4f)",
                     impostorMaximum, genuineMinimum, margin))
        print(String(format: "    Suggested matchThreshold: %.2f  (midpoint of the gap)", threshold))
        print(current)
        print("    This DOES justify `thresholdIsTuned = true` — provided the image set")
        print("    covers your real conditions: lighting, glasses on/off, angle, distance,")
        print("    and the closest look-alike you can get hold of (EC-03).")

    case .overlap:
        print("    ================================================================")
        print("    REFUSED — NO THRESHOLD ENDORSED (distributions overlap)")
        print("    ================================================================")
        if let reason = recommendation.refusalReason { print("    - \(reason)") }
        print(current)
        print("    DO NOT set `thresholdIsTuned = true` on this. Overlap means no scalar")
        print("    threshold separates the two classes: every value trades a false lock")
        print("    against a stranger being accepted. Improve the data first — more images")
        print("    per person, conditions matching real use — and inspect the low-scoring")
        print("    genuine images for bad crops before trusting any number here.")
    }
}

// MARK: - Main

let opts = parseArguments(Array(CommandLine.arguments.dropFirst()))

guard let modelPath = opts.modelPath, let imageDir = opts.imageDir else {
    printUsage()
    exit(2)
}

let modelURL = URL(fileURLWithPath: modelPath)
guard FileManager.default.fileExists(atPath: modelURL.path) else {
    print("error: no compiled model at \(modelURL.path)")
    print("hint: scripts/make-app.sh bundles one at build/NoDonuts.app/Contents/Resources/")
    exit(1)
}

guard let embedder = CoreMLFaceEmbedder(compiledModelURL: modelURL) else {
    print("error: failed to load the Core ML model at \(modelURL.path)")
    exit(1)
}

// Read tunables from the APP's defaults domain (ND-094): FaceScore's own domain is not
// what the running app sees, so measuring with it would measure a different pipeline.
let appDefaultsDomain = "com.nodonuts.app"
guard let appDefaults = UserDefaults(suiteName: appDefaultsDomain) else {
    print("error: cannot open the \(appDefaultsDomain) defaults domain")
    exit(1)
}
let appOrientation = resolvedVisionOrientation(defaults: appDefaults)
// The embedder resolves orientation from `UserDefaults.standard`. Seed FaceScore's
// registration domain with the app's value (in memory only, nothing written), then
// verify the embedder will actually see it — a stray `defaults write FaceScore
// visionOrientation …` or `-visionOrientation` argument would outrank it.
UserDefaults.standard.register(defaults: ["visionOrientation": Int(appOrientation.rawValue)])
guard resolvedVisionOrientation() == appOrientation else {
    print("error: FaceScore's own defaults override visionOrientation "
          + "(\(resolvedVisionOrientation().rawValue)) and disagree with the app's "
          + "(\(appOrientation.rawValue)). Remove it: defaults delete FaceScore visionOrientation")
    exit(1)
}
let effectiveThreshold = resolvedMatchThreshold(for: embedder.descriptor, defaults: appDefaults)

print("FaceScore — model \(embedder.descriptor.displayName)")
print("  version \(embedder.descriptor.version), \(embedder.descriptor.outputDimension)-d, "
      + "default threshold \(embedder.descriptor.defaultMatchThreshold) "
      + "(tuned=\(embedder.descriptor.thresholdIsTuned ? "yes" : "no"))")
print("  app (\(appDefaultsDomain)): effective threshold " + String(format: "%.2f", effectiveThreshold)
      + (effectiveThreshold != embedder.descriptor.defaultMatchThreshold
         ? " (per-model override \(embedder.descriptor.thresholdOverrideKey))" : " (model default)")
      + ", visionOrientation \(appOrientation.rawValue)")
if appOrientation != .up {
    print("  WARNING: the app's visionOrientation is \(appOrientation.rawValue), not 1 (.up). It is applied")
    print("  on top of each file's EXIF orientation, as for a raw camera frame. That is right for")
    print("  frames saved raw from the Mac's camera and WRONG for already-upright phone photos.")
}

// Discover <imageDir>/<label>/<image files>.
let rootURL = URL(fileURLWithPath: imageDir)
let fm = FileManager.default
guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
    print("error: cannot read \(rootURL.path)")
    exit(1)
}

let labelDirectories = entries
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !labelDirectories.isEmpty else {
    print("error: \(rootURL.path) has no per-person subdirectories.")
    printUsage()
    exit(1)
}

// Embed everything. Report skips loudly: a silently-skipped image is a silently
// smaller sample, and the whole point here is knowing what the numbers rest on.
var samples: [Sample] = []
var skipped: [(String, String)] = []
var undecodableCount = 0
var noFaceCount = 0
var failedCount = 0
var reorientedCount = 0

for directory in labelDirectories {
    let label = directory.lastPathComponent
    let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for file in files {
        guard let loaded = loadPixelBuffer(file) else {
            skipped.append((label + "/" + file.lastPathComponent, "undecodable"))
            undecodableCount += 1
            continue
        }
        if loaded.exifOrientation != .up { reorientedCount += 1 }
        let frame = CapturedFrame(pixelBuffer: loaded.buffer)
        // The embedder is async; this tool is a straight-line script, so block on each.
        let outcome = runBlocking { await embedder.embedding(for: frame) }
        switch outcome {
        case let .embedding(vector):
            samples.append(Sample(label: label, path: file.path, vector: vector))
            if opts.verbose { print("  embedded \(label)/\(file.lastPathComponent) (\(vector.count)-d)") }
        case .noFace:
            // Includes faces the embedder's quality gate rejects (e.g. too small, ND-085).
            skipped.append((label + "/" + file.lastPathComponent, "no usable face"))
            noFaceCount += 1
        case .failure:
            skipped.append((label + "/" + file.lastPathComponent, "embedding failed"))
            failedCount += 1
        }
    }
}

print("\nembedded \(samples.count) image(s) across \(Set(samples.map(\.label)).count) label(s)")
for label in labelDirectories.map(\.lastPathComponent) {
    let n = samples.filter { $0.label == label }.count
    print("  \(label): \(n)")
}
print("  EXIF-reoriented: \(reorientedCount)")
print("skipped \(skipped.count): no usable face \(noFaceCount), undecodable \(undecodableCount), "
      + "embedding failed \(failedCount)")
if noFaceCount > 0 {
    print("  (\"no usable face\" = none detected, or rejected by the embedder's face-quality gate,")
    print("   e.g. a face too small in frame — ND-085. Those images are NOT in the statistics.)")
}
for (name, reason) in skipped { print("  \(name) — \(reason)") }

guard samples.count >= 2 else {
    print("\nerror: need at least 2 embedded images.")
    exit(1)
}

// MARK: Mode — production-shaped (--enrolled) or pairwise

if let enrolledLabel = opts.enrolledLabel {
    let enrolledSamples = samples.filter { $0.label == enrolledLabel }
    guard !enrolledSamples.isEmpty else {
        print("\nerror: no embedded images for --enrolled label '\(enrolledLabel)'")
        exit(1)
    }
    let referenceCount = min(opts.referenceCount, enrolledSamples.count)
    guard enrolledSamples.count > referenceCount else {
        print("""

        error: '\(enrolledLabel)' has \(enrolledSamples.count) image(s) and \
        --references is \(referenceCount) — no genuine images left to TEST with.
        Add more photos of \(enrolledLabel), or lower --references.
        """)
        exit(1)
    }

    let references = Array(enrolledSamples.prefix(referenceCount))
    let probes = samples.filter { sample in !references.contains { $0.path == sample.path } }

    print("\n=== production-shaped run ===")
    print("  enrolled '\(enrolledLabel)' with \(references.count) reference vector(s);"
          + " scoring \(probes.count) probe image(s) as max-cosine vs references")
    print("  (this mirrors IdentityRecognizer: max over reference vectors, `>=` threshold)")

    var genuineScores: [Double] = []
    var impostorScores: [Double] = []
    var perLabel: [String: [Double]] = [:]

    for probe in probes {
        let score = references.reduce(0.0) { best, reference in
            max(best, cosineSimilarity(probe.vector, reference.vector))
        }
        if probe.label == enrolledLabel { genuineScores.append(score) } else { impostorScores.append(score) }
        perLabel[probe.label, default: []].append(score)
        if opts.verbose {
            print(String(format: "    %@  %.4f  %@", probe.label == enrolledLabel ? "GEN" : "IMP",
                         score, (probe.path as NSString).lastPathComponent))
        }
    }

    let genuine = ScoreDistribution(genuineScores)
    let impostor = ScoreDistribution(impostorScores)

    print("\n  distributions")
    describe("genuine", genuine)
    describe("impostor", impostor)

    print("\n  per impostor label (max score = the one that matters — the closest look-alike)")
    for (label, scores) in perLabel.sorted(by: { $0.key < $1.key }) where label != enrolledLabel {
        let dist = ScoreDistribution(scores)
        print("    " + label.padding(toLength: 16, withPad: " ", startingAt: 0)
              + " n=" + String(dist.count).padding(toLength: 5, withPad: " ", startingAt: 0)
              + " mean=" + format(dist.mean) + "  max=" + format(dist.maximum))
    }

    // Distinct OTHER people who produced impostor scores against the enrolled references.
    let impostorIdentities = Set(probes.map(\.label).filter { $0 != enrolledLabel }).count

    printSweep(genuine: genuine, impostor: impostor)
    report(recommendThreshold(genuine: genuine, impostor: impostor,
                              impostorIdentityCount: impostorIdentities),
           descriptor: embedder.descriptor, effectiveThreshold: effectiveThreshold)

} else {
    print("\n=== pairwise run ===")
    print("  every image vs every other; genuine = same label, impostor = different label")

    var genuineScores: [Double] = []
    var impostorScores: [Double] = []
    var pairMax: [String: Double] = [:]

    for i in 0..<samples.count {
        for j in (i + 1)..<samples.count {
            let score = cosineSimilarity(samples[i].vector, samples[j].vector)
            if samples[i].label == samples[j].label {
                genuineScores.append(score)
            } else {
                impostorScores.append(score)
                let key = [samples[i].label, samples[j].label].sorted().joined(separator: " vs ")
                pairMax[key] = max(pairMax[key] ?? -1, score)
            }
        }
    }

    let genuine = ScoreDistribution(genuineScores)
    let impostor = ScoreDistribution(impostorScores)

    print("\n  distributions")
    describe("genuine", genuine)
    describe("impostor", impostor)

    if !pairMax.isEmpty {
        print("\n  worst-case per label pair (highest impostor score seen)")
        for (pair, score) in pairMax.sorted(by: { $0.value > $1.value }) {
            print(String(format: "    %-32@ %.4f", pair as NSString, score))
        }
    }

    // Pairwise: relative to any one person, every OTHER embedded label is an impostor
    // identity — so the count is (labels − 1). Two labels = one stranger per person.
    // Note genuine/impostor counts here are PAIRS, not independent images; prefer the
    // --enrolled run for the number you ship.
    let impostorIdentities = max(0, Set(samples.map(\.label)).count - 1)

    printSweep(genuine: genuine, impostor: impostor)
    report(recommendThreshold(genuine: genuine, impostor: impostor,
                              impostorIdentityCount: impostorIdentities),
           descriptor: embedder.descriptor, effectiveThreshold: effectiveThreshold)
}

print("")
