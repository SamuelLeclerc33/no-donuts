import Foundation
import Security
import os

// Owner: cooper — enrolled embeddings, encrypted at rest. Backlog: ND-022, ND-023. ADR-0012.
// Privacy: stores EMBEDDINGS ONLY (never raw images), encrypted at rest in the Keychain,
// device-only (never syncs to iCloud), never transmitted over any network.

/// Tri-state enrollment status — distinguishes "not enrolled" from "read failed".
///
/// **Security-critical (S1, fail-safe):** the recognizer must NEVER downgrade to
/// presence-only (any face passes) just because a Keychain read failed. A read failure
/// (e.g. `errSecInteractionNotAllowed` before first unlock) is `.unavailable`, which the
/// recognizer surfaces as `.error` → the presence engine holds (EC-10) and sustained
/// unavailability escalates to lock. Only `.notEnrolled` (genuinely no item) allows the
/// presence-only fallback.
public enum EnrollmentState: Sendable {
    /// No enrollment item exists (or it decoded to an empty set) — presence-only OK.
    case notEnrolled
    /// A valid non-empty set of reference embeddings.
    case enrolled([[Float]])
    /// The Keychain read failed or the blob was undecodable — DO NOT downgrade to
    /// presence-only. Treat conservatively (fail-safe).
    case unavailable
}

/// Persists the enrolled user's face embeddings.
public protocol EnrollmentStoring: Sendable {
    /// Single source of truth for enrollment status. All reads go through here so
    /// there is ONE Keychain read path (no double-read).
    func enrollmentState() -> EnrollmentState
    var isEnrolled: Bool { get }
    func enrolledEmbeddings() -> [[Float]]
    func enroll(embeddings: [[Float]]) throws
    func reset() throws
}

/// Errors surfaced by `EnrollmentStore` for genuine Keychain failures (not "not found").
public enum EnrollmentStoreError: Error {
    /// A `SecItem*` call failed with an unexpected `OSStatus`.
    case keychain(OSStatus)
}

/// Keychain-backed enrollment store — encrypted at rest (ND-023, ADR-0012).
///
/// Stores the enrolled reference embeddings as a single generic-password item whose
/// data blob is a serialized `[[Float]]`. **Embeddings only** — no raw images ever
/// touch this store. The item uses
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it is available in the
/// background after first unlock (the presence loop needs it) but is **device-only**:
/// it never syncs to iCloud Keychain and never leaves this Mac.
///
/// `@unchecked Sendable`: all state lives in the Keychain (thread-safe `SecItem*`
/// calls); this type holds only immutable configuration.
public final class EnrollmentStore: EnrollmentStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let log = Logger(subsystem: "com.nodonuts.app", category: "recognition")

    /// Human-friendly item name/description. macOS shows the item's LABEL in the
    /// Keychain-access prompt (there's no custom-text hook), so a clear label makes the
    /// dialog read "…information stored in 'No Donuts — your face signature'…" instead of
    /// the raw account. Set on add AND update so an existing unlabeled item gets relabeled
    /// on the next enroll.
    private let itemLabel = "No Donuts — your face signature"
    private let itemDescription = "Encrypted face signature used to keep this Mac unlocked only for you. Stored on this device; never a photo, never uploaded."

    /// In-memory cache of the last DEFINITIVE read (`.enrolled` / `.notEnrolled`).
    /// The presence loop asks for `enrollmentState()` every tick (~1/s); without this
    /// cache each tick hits the Keychain, and on an ad-hoc-signed build macOS shows a
    /// Keychain-access prompt on every read → a prompt storm. The enrolled set only
    /// changes via `enroll()`/`reset()` (both app-initiated), so we read the Keychain
    /// at most once and update the cache in place on write. `.unavailable` (a transient
    /// read failure) is deliberately NOT cached, so it can self-recover on a later tick.
    /// Guarded by `cacheLock`.
    private let cacheLock = NSLock()
    private var cached: EnrollmentState?

    /// - Parameters:
    ///   - service: Keychain `kSecAttrService` (default `com.nodonuts.app`).
    ///   - account: Keychain `kSecAttrAccount` (default `enrollment`).
    ///     Overridable so tests can use a throwaway item.
    public init(service: String = "com.nodonuts.app", account: String = "enrollment") {
        self.service = service
        self.account = account
    }

    /// Enrollment status, served from the in-memory cache when available so the
    /// per-tick recognizer doesn't hammer the Keychain (see `cached`). Falls through to
    /// a single Keychain read on a cache miss; caches only definitive results.
    public func enrollmentState() -> EnrollmentState {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let state = readEnrollmentStateFromKeychain()
        switch state {
        case .enrolled, .notEnrolled:
            cacheLock.lock(); cached = state; cacheLock.unlock()
        case .unavailable:
            break   // don't cache a transient failure — allow a later tick to recover
        }
        return state
    }

    /// SINGLE Keychain read path (S1 fail-safe): distinguishes "genuinely not enrolled"
    /// from "read failed". `errSecItemNotFound` (or a decoded-empty set) → `.notEnrolled`;
    /// a valid non-empty blob → `.enrolled`; ANY other `OSStatus` OR a decode failure →
    /// `.unavailable` (the recognizer must treat this conservatively, never presence-only).
    private func readEnrollmentStateFromKeychain() -> EnrollmentState {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecItemNotFound:
            return .notEnrolled
        case errSecSuccess:
            guard let data = item as? Data else {
                // Success but no data is anomalous → don't fail open.
                log.error("enrollment read returned no data despite success")
                return .unavailable
            }
            do {
                let embeddings = try JSONDecoder().decode([[Float]].self, from: data)
                return embeddings.isEmpty ? .notEnrolled : .enrolled(embeddings)
            } catch {
                // Corrupt/undecodable blob → conservative, NOT presence-only.
                log.error("failed to decode enrollment blob: \(error.localizedDescription, privacy: .public)")
                return .unavailable
            }
        default:
            // e.g. errSecInteractionNotAllowed (before first unlock), errSecAuthFailed —
            // a genuine read failure. Fail SAFE: unavailable, never "not enrolled".
            log.error("enrollment read failed: OSStatus \(status)")
            return .unavailable
        }
    }

    // isEnrolled / enrolledEmbeddings derive from the single read path above.
    public var isEnrolled: Bool {
        if case .enrolled = enrollmentState() { return true }
        return false
    }

    public func enrolledEmbeddings() -> [[Float]] {
        if case .enrolled(let e) = enrollmentState() { return e }
        return []
    }

    public func enroll(embeddings: [[Float]]) throws {
        let data = try JSONEncoder().encode(embeddings)

        // Non-destructive replace (S2): UPDATE an existing item in place, and only ADD
        // when none exists. NEVER delete-then-add — a failed add after a successful
        // delete would wipe a valid enrollment and silently drop to presence-only.
        let existsStatus = SecItemCopyMatching(baseQuery() as CFDictionary, nil)
        if existsStatus == errSecSuccess {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrLabel as String: itemLabel,           // relabel legacy items
                    kSecAttrDescription as String: itemDescription,
                ] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EnrollmentStoreError.keychain(updateStatus)
            }
        } else {
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String] = itemLabel        // shown in the access prompt
            attributes[kSecAttrDescription as String] = itemDescription
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw EnrollmentStoreError.keychain(addStatus)
            }
        }
        // Update the cache in place so the next tick doesn't re-read the Keychain
        // (avoids a fresh access prompt) — we already know the new value.
        cacheLock.lock(); cached = .enrolled(embeddings); cacheLock.unlock()
    }

    public func reset() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EnrollmentStoreError.keychain(status)
        }
        // Reflect the wipe in the cache immediately (no re-read / prompt).
        cacheLock.lock(); cached = .notEnrolled; cacheLock.unlock()
    }

    // MARK: - Private

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory enrollment store for tests and as a safe fallback.
///
/// Not persistent — data lives only for the process lifetime. Useful for EngineCheck
/// (no Keychain in a headless toolchain) and as a graceful degrade if the Keychain is
/// unavailable. `@unchecked Sendable`: guards its array with a lock.
public final class InMemoryEnrollmentStore: EnrollmentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [[Float]] = []
    /// Test hook: when true, reads report `.unavailable` (simulates a Keychain read
    /// failure) so the recognizer's fail-safe path can be exercised in EngineCheck.
    private var simulateUnavailable: Bool

    public init(embeddings: [[Float]] = [], simulateUnavailable: Bool = false) {
        self.embeddings = embeddings
        self.simulateUnavailable = simulateUnavailable
    }

    /// Flip the simulated-unavailable state (tests only).
    public func setSimulateUnavailable(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        simulateUnavailable = value
    }

    public func enrollmentState() -> EnrollmentState {
        lock.lock(); defer { lock.unlock() }
        if simulateUnavailable { return .unavailable }
        return embeddings.isEmpty ? .notEnrolled : .enrolled(embeddings)
    }

    public var isEnrolled: Bool {
        if case .enrolled = enrollmentState() { return true }
        return false
    }

    public func enrolledEmbeddings() -> [[Float]] {
        if case .enrolled(let e) = enrollmentState() { return e }
        return []
    }

    public func enroll(embeddings: [[Float]]) throws {
        lock.lock(); defer { lock.unlock() }
        self.embeddings = embeddings
    }

    public func reset() throws {
        lock.lock(); defer { lock.unlock() }
        embeddings = []
    }
}
