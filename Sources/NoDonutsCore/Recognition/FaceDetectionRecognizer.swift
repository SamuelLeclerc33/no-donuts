import Foundation
@preconcurrency import Vision
import CoreVideo

// Owner: cooper — Vision face detection (presence-only). Backlog: ND-020. ADR-0002.

/// Presence-only face recognizer (MVP, ND-020).
///
/// Detects whether **any** face is in the frame using Apple Vision
/// (`VNDetectFaceRectanglesRequest`). For this MVP, *any* detected face counts as
/// the enrolled user being present — there is **no identity check, no embeddings,
/// and no enrollment**. Identity matching (cosine similarity vs enrolled
/// embeddings, EC-03 stranger handling) is deferred to v1.1; see the
/// `VisionCoreMLRecognizer` stub and ND-021+.
///
/// Privacy (ADR-0002 / SECURITY_PRIVACY): Vision runs **entirely on-device**.
/// Each frame is analyzed in memory and discarded immediately; no image, frame,
/// or derived data is persisted or sent over any network.
///
/// Concurrency: `Sendable`. The presence engine (ADR-0005, `@MainActor`) awaits
/// `recognize()` from the main actor, so the synchronous Vision `perform(_:)` call
/// is offloaded onto a dedicated serial `DispatchQueue` via
/// `withCheckedContinuation` — the main actor is never blocked by detection work.
public final class FaceDetectionRecognizer: FaceRecognizing, Sendable {

    /// Dedicated serial queue so Vision's synchronous `perform` never runs on the
    /// main actor (ADR-0005). Serial keeps per-tick work cheap and ordered.
    private let detectionQueue = DispatchQueue(label: "com.nodonuts.face-detection")

    public init() {}

    public func recognize(_ frame: CapturedFrame) async -> RecognitionResult {
        // Hop off the (main) actor: dispatch the blocking Vision work onto our
        // dedicated queue and suspend until it completes. We capture the
        // `@unchecked Sendable` `CapturedFrame` (not its non-Sendable
        // `CVPixelBuffer`) into the `@Sendable` closure, and unwrap inside.
        return await withCheckedContinuation { (continuation: CheckedContinuation<RecognitionResult, Never>) in
            detectionQueue.async {
                guard let pixelBuffer = frame.pixelBuffer else {
                    continuation.resume(returning: .error("no pixel buffer"))
                    return
                }

                // TODO(ND-042): per-tick VNRequest alloc is cheap; revisit if profiling shows cost
                let request = VNDetectFaceRectanglesRequest()

                // TODO(cooper): front-camera orientation may need tuning; `.up`
                // is a reasonable default for presence-only and is out of scope
                // for ND-020.
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: .up,
                    options: [:]
                )

                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: .error("face detection failed: \(error.localizedDescription)"))
                    return
                }

                let observations = request.results ?? []
                guard !observations.isEmpty else {
                    continuation.resume(returning: .noFace)
                    return
                }

                // Presence-only: any face means present. Report the highest
                // detection confidence among the observations.
                let highest = observations.map { Double($0.confidence) }.max() ?? 0
                // Presence-only MVP: this is Vision's face-DETECTION confidence,
                // NOT an identity-match score. The presence engine ignores this
                // value — it switches on the case alone, never on the magnitude.
                // When identity matching lands (ND-021/ND-024), this MUST become
                // the cosine-similarity match score against the enrolled embedding.
                continuation.resume(returning: .enrolledUserPresent(confidence: highest))
            }
        }
    }
}
