import Foundation
import os

// Owner: cooper — launch-time model loading off the main thread (ND-095).
// Privacy: no I/O of its own; wraps on-device embedders only. No network.

private let deferredLog = Logger(subsystem: Log.subsystem, category: Log.Category.recognition)

/// A `FaceEmbedding` whose real embedder is still loading (ND-095).
///
/// The Core ML model (~45 MB) used to load synchronously on the main thread at launch.
/// This wrapper lets the app wire the recognizer + enrollment coordinator immediately
/// and load the model in the background, without changing identity semantics while it
/// loads:
///
/// - **While loading**, `descriptor` is the `presumed` descriptor (the model we are
///   loading), so the ND-073 identity status computes against the right version and does
///   NOT flap to OFF during the load. `embeddingWithLiveness` **awaits** the load. It never
///   answers from a placeholder: no Vision fallback, no `.failure` (which would count
///   toward the EC-10 error-to-absence escalation). A tick just takes longer, once.
/// - **Load succeeded**: everything delegates to the loaded embedder.
/// - **Load failed** (`load` returned `nil`): permanent switch to `fallback` (the Vision
///   embedder), exactly as a synchronous launch failure did before. `descriptor` becomes
///   the fallback's, so an enrolled user sees the loud ND-073 `.off(.modelMismatch)` on the
///   next tick.
/// - **Load timed out** (no result within `loadTimeout`, default 20s): treated exactly
///   like a failed load — permanent switch to `fallback`, logged at `.error`. Without
///   this, an `MLModel.load` that never returns would leave every tick awaiting inside
///   `recognize()` forever: no reading → no absence → the Mac never locks (a silent
///   fail-open). A load that completes after the timeout is logged and discarded.
///
/// **No cross-model comparison.** A call that STARTED while loading may have been paired
/// by its caller with the presumed descriptor (the recognizer reads the threshold before
/// embedding; enrollment reads its policy at capture start). If the load resolves to an
/// embedder with a DIFFERENT version, that one call returns `.failure` (one conservative
/// EC-10 hold tick) rather than a vector from another embedding space. Later calls read the
/// resolved descriptor first, so they are consistent. The recognizer also re-checks the
/// stored-vs-active version after embedding.
///
/// Note: unlike the other embedders, `descriptor` can change ONCE (presumed → resolved).
/// Code that snapshots it at launch (e.g. the Settings store's per-model threshold key)
/// keeps the presumed model if a late load failure switches to the fallback.
public final class DeferredFaceEmbedder: FaceEmbedding, @unchecked Sendable {
    private enum State {
        case loading
        case resolved(FaceEmbedding)
    }

    private let presumed: FaceEmbeddingModelDescriptor
    private let state: OSAllocatedUnfairLock<State>
    private let loadTask: Task<FaceEmbedding, Never>

    /// Default bound on the model load. A cold Core ML load of the ~45 MB model is a
    /// few seconds even at a busy login; 20s leaves wide margin without holding
    /// ticks for long if the load is wedged.
    public static let defaultLoadTimeout: TimeInterval = 20

    /// - Parameters:
    ///   - presumed: descriptor of the embedder `load` is expected to produce.
    ///   - fallback: used permanently if `load` returns `nil` or times out.
    ///   - loadTimeout: seconds to wait for `load` before falling back for good.
    ///     Non-finite or ≤ 0 uses `defaultLoadTimeout`.
    ///   - load: produces the real embedder off the calling thread (runs in a detached
    ///     task, `.userInitiated`). Started immediately.
    public init(presumed: FaceEmbeddingModelDescriptor,
                fallback: FaceEmbedding,
                loadTimeout: TimeInterval = DeferredFaceEmbedder.defaultLoadTimeout,
                load: @escaping @Sendable () async -> FaceEmbedding?) {
        let state = OSAllocatedUnfairLock<State>(initialState: .loading)
        let timeout = (loadTimeout.isFinite && loadTimeout > 0) ? loadTimeout : Self.defaultLoadTimeout
        self.presumed = presumed
        self.state = state
        self.loadTask = Task.detached(priority: .userInitiated) {
            let resolved: FaceEmbedding = await Self.load(load, timeout: timeout) ?? fallback
            // Publish BEFORE the task's value is visible, so anyone who awaited the load
            // sees the resolved state (and descriptor) afterwards.
            state.withLock { $0 = .resolved(resolved) }
            return resolved
        }
    }

    /// Race `load` against `timeout`; nil on failure or timeout. Deliberately NOT a
    /// task group: a group waits for every child, so a load that ignores cancellation
    /// would still hang it. Whichever side finishes first resumes the continuation
    /// (exactly once); the loser is cancelled or ignored.
    private static func load(_ load: @escaping @Sendable () async -> FaceEmbedding?,
                             timeout: TimeInterval) async -> FaceEmbedding? {
        let claimed = OSAllocatedUnfairLock<Bool>(initialState: false)
        let claim: @Sendable () -> Bool = {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<FaceEmbedding?, Never>) in
            let timer = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if Task.isCancelled { return }
                if claim() {
                    deferredLog.error("face model load did not finish within \(timeout, format: .fixed(precision: 0), privacy: .public)s; using the fallback embedder for this run (identity will show as off)")
                    cont.resume(returning: nil)
                }
            }
            Task.detached(priority: .userInitiated) {
                let embedder = await load()
                if claim() {
                    timer.cancel()
                    cont.resume(returning: embedder)
                } else {
                    deferredLog.notice("face model load finished after the timeout; discarded (the fallback stays in use until relaunch)")
                }
            }
        }
    }

    /// `true` once the load has finished (successfully or by falling back).
    public var isResolved: Bool {
        state.withLock { if case .resolved = $0 { return true } else { return false } }
    }

    /// Wait for the load to finish; returns the embedder now in use (the loaded one, or
    /// the fallback when loading failed).
    public func resolvedEmbedder() async -> FaceEmbedding {
        await loadTask.value
    }

    public var descriptor: FaceEmbeddingModelDescriptor {
        switch state.withLock({ $0 }) {
        case .loading: return presumed
        case .resolved(let embedder): return embedder.descriptor
        }
    }

    public func embeddingWithLiveness(for frame: CapturedFrame) async -> FaceEmbeddingResult {
        switch state.withLock({ $0 }) {
        case .resolved(let embedder):
            return await embedder.embeddingWithLiveness(for: frame)
        case .loading:
            let embedder = await loadTask.value
            // This call began under the presumed descriptor: never hand back a vector
            // from another embedding space (see the type doc).
            guard embedder.descriptor.version == presumed.version else { return .failure }
            return await embedder.embeddingWithLiveness(for: frame)
        }
    }
}
