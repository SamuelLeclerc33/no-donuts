import Foundation

// Owner: wiggum — screen locking + fail-safe enforcement + anti-spoofing hooks.
// Backlog: ND-014, ND-041. We LOCK only; unlock stays with macOS (Touch ID/password).

/// Locks the screen. Implementations must be reliable under sandbox/entitlements.
public protocol ScreenLocking {
    func lock()
}

/// macOS screen-lock implementation. Stub.
public final class ScreenLocker: ScreenLocking {
    public init() {}

    public func lock() {
        // TODO(wiggum): validate a reliable mechanism under our entitlements (ND-014).
        // Candidates to evaluate: SACLockScreenImmediate (login.framework),
        // `pmset displaysleepnow` + require-password, or a vetted IOKit path.
        // Must NOT fail open silently — log + surface status on failure.
    }
}
