import Foundation

// Owner: cooper — enrolled embeddings, encrypted at rest. Backlog: ND-022, ND-023.
// Privacy: store embeddings (not raw images) where possible; encrypted; never transmitted.

/// Persists the enrolled user's face embeddings.
public protocol EnrollmentStoring: Sendable {
    var isEnrolled: Bool { get }
    func enrolledEmbeddings() -> [[Float]]
    func enroll(embeddings: [[Float]]) throws
    func reset() throws
}

/// Keychain / encrypted-file backed store. Stub.
///
/// `Sendable`: reached transitively via `FaceRecognizing` from the main-actor
/// presence loop (ADR-0005). No mutable stored state yet, so this compiles as-is.
/// The real encrypted-store implementation (ND-023) MUST remain `Sendable` —
/// i.e. thread-safe access to the Keychain / encrypted file.
public final class EnrollmentStore: EnrollmentStoring, Sendable {
    public init() {}

    public var isEnrolled: Bool {
        // TODO(cooper): true if encrypted store has at least one embedding.
        false
    }

    public func enrolledEmbeddings() -> [[Float]] {
        // TODO(cooper): load + decrypt.
        []
    }

    public func enroll(embeddings: [[Float]]) throws {
        // TODO(cooper): persist encrypted at rest (Keychain or encrypted file).
    }

    public func reset() throws {
        // TODO(cooper): wipe all enrolled data.
    }
}
