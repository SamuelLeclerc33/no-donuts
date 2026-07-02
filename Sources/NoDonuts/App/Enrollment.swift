import Foundation
import NoDonutsCore

// Owner: krusty — enrollment capture UX (ND-022). Depends on cooper's Round-1 types:
// FaceEmbedding + EnrollmentStoring. Camera reuse via blart's CameraController.capture().
//
// Trust rule: enrollment is a deliberate, user-initiated capture. This coordinator
// does ONE thing — grab a handful of frames, embed the face in each, and persist the
// vectors. It embeds no policy and drives NO pause/loop itself: the AppDelegate gates
// enforcement around it (treats "enrolling" as an enforcement-disabled reason so
// nothing locks mid-capture) and gives the coordinator exclusive use of capture()
// by stopping the presence loop while keeping the camera resumed.
//
// Privacy: frames are analyzed in memory and discarded; only embeddings (never
// images) are handed to the store, which persists them encrypted at rest.

/// Drives a quick auto-capture enrollment: ~10 frames over ~2–3s, embedding the
/// face in each, then storing the collected vectors.
@MainActor
public final class EnrollmentCoordinator {
    /// Outcome of an enrollment attempt, surfaced to the user via an NSAlert.
    public enum Result: Sendable {
        /// Enrolled successfully with `count` reference embeddings.
        case success(count: Int)
        /// Frames were captured but too few contained a usable face — existing
        /// enrollment (if any) is left untouched so a bad attempt can't wipe it.
        case notEnoughFaces
        /// The camera never delivered a frame (denied/unavailable/suspended).
        case cameraUnavailable
        /// Frames + faces were fine, but persisting the embeddings failed (e.g. a
        /// Keychain write error). Distinct from `.cameraUnavailable` so the alert is
        /// honest: this is a save problem, not a camera problem.
        case saveFailed
        /// The capture was cancelled mid-flight (session suspended / app terminating).
        /// Existing enrollment (if any) is left untouched.
        case cancelled
    }

    private let camera: CameraController
    private let embedder: FaceEmbedding
    private let store: EnrollmentStoring

    /// Number of capture attempts across the enrollment window.
    private let attempts = 10
    /// Spacing between capture attempts (~200 ms → ~2s window over `attempts`).
    private let attemptSpacing: Duration = .milliseconds(200)
    /// Minimum usable face embeddings required to commit an enrollment.
    private let minimumVectors = 3

    public init(camera: CameraController, embedder: FaceEmbedding, store: EnrollmentStoring) {
        self.camera = camera
        self.embedder = embedder
        self.store = store
    }

    /// Capture + embed + store. The AppDelegate must have stopped the presence loop
    /// (so we have exclusive use of `capture()`) and resumed the camera before
    /// calling this. Never touches pause/loop state itself.
    public func enroll() async -> Result {
        var vectors: [[Float]] = []
        var frames = 0

        for attempt in 0..<attempts {
            // Cancellation-aware (code-review #6/#5): if the session suspended or the
            // app is terminating, bail immediately without committing anything — a
            // partial/aborted capture must never wipe or overwrite existing enrollment.
            if Task.isCancelled { return .cancelled }

            switch await camera.capture() {
            case .frame(let frame):
                frames += 1
                // Embedder is now tri-state (cooper): collect only successful
                // embeddings; ignore `.noFace` and `.failure` attempts — a hiccup or a
                // frame without a face just means "try again next attempt".
                switch await embedder.embedding(for: frame) {
                case .embedding(let vector):
                    vectors.append(vector)
                case .noFace, .failure:
                    break
                }
            case .cameraBusyNoFrames, .suspended, .unavailable:
                // No usable frame this attempt; keep trying — a transient hiccup
                // shouldn't abort the whole window. If we NEVER get a frame we bail
                // to .cameraUnavailable below.
                break
            }

            // Space out attempts (skip the wait after the final one). Cooperative
            // sleep — never Thread.sleep — so the main actor stays responsive.
            if attempt < attempts - 1 {
                try? await Task.sleep(for: attemptSpacing)
            }
        }

        // A cancel that landed after the loop's final iteration (during the last
        // sleep or capture) — still honor it before touching the store.
        if Task.isCancelled { return .cancelled }

        // Not a single frame arrived → the camera is genuinely unavailable.
        guard frames > 0 else { return .cameraUnavailable }

        // Frames arrived but too few had a usable face → don't wipe existing
        // enrollment; ask the user to try again.
        guard vectors.count >= minimumVectors else { return .notEnoughFaces }

        do {
            try store.enroll(embeddings: vectors)
            return .success(count: vectors.count)
        } catch {
            // A genuine store failure (e.g. Keychain write error). This is NOT a
            // camera problem (code-review #9) — surface it honestly as .saveFailed so
            // the alert tells the user to retry the save, not to check the camera.
            return .saveFailed
        }
    }
}
