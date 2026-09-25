import Foundation
import NoDonutsCore

// Owner: krusty — enrollment capture UX (ND-022). Depends on cooper's Round-1 types:
// FaceEmbedding + EnrollmentStoring. Camera reuse via blart's CameraController.capture().
//
// Trust rule: enrollment is a deliberate, user-initiated capture. This coordinator
// does ONE thing — run cooper's `runEnrollmentCapture` (distinct frames, consistency
// gate, store write). It embeds no policy and drives NO pause/loop itself: the
// AppDelegate gates enforcement around it (treats "enrolling" as an enforcement-disabled
// reason so nothing locks mid-capture) and gives the coordinator exclusive use of
// capture() by stopping the presence loop while keeping the camera resumed.
//
// Privacy: frames are analyzed in memory and discarded; only embeddings (never
// images) are handed to the store, which persists them encrypted at rest.

/// Drives an auto-capture enrollment (ND-063): samples the camera until it has 5
/// DISTINCT frames with a usable face (~5–6 s at the camera's ~1 fps; 10 s timeout),
/// drops outlier vectors, and stores the set only if it is self-consistent.
@MainActor
public final class EnrollmentCoordinator {
    /// Outcome of an enrollment attempt, surfaced to the user via an NSAlert. Every case
    /// except `.success` leaves the existing enrollment (if any) untouched:
    /// `.notEnoughFaces`, `.inconsistent` (ND-063: faces didn't agree — second person,
    /// blur, lighting change), `.cameraUnavailable`, `.saveFailed`, `.cancelled`.
    public typealias Result = EnrollmentCaptureOutcome

    private let camera: CameraController
    private let embedder: FaceEmbedding
    private let store: EnrollmentStoring

    public init(camera: CameraController, embedder: FaceEmbedding, store: EnrollmentStoring) {
        self.camera = camera
        self.embedder = embedder
        self.store = store
    }

    /// Capture + embed + store. The AppDelegate must have stopped the presence loop
    /// (so we have exclusive use of `capture()`) and resumed the camera before
    /// calling this. Never touches pause/loop state itself. Cancellation-aware: a
    /// cancelled capture returns `.cancelled` without writing anything.
    public func enroll() async -> Result {
        await runEnrollmentCapture(camera: camera, embedder: embedder, store: store)
    }
}
