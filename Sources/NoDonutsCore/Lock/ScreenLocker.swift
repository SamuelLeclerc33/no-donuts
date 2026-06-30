import Foundation
import os

// Owner: wiggum — screen locking + fail-safe enforcement + anti-spoofing hooks.
// Backlog: ND-014, ND-041. We LOCK only; unlock stays with macOS (Touch ID/password).

/// Locks the screen. Implementations must be reliable under sandbox/entitlements
/// and must report success/failure so callers never silently fail open.
///
/// `Sendable` because `PresenceEngine` is `@MainActor` and holds a locker; it must
/// be safe to carry across isolation boundaries (matches the camera/recognizer
/// protocols, see ADR-0005).
public protocol ScreenLocking: Sendable {
    /// Attempts to lock the screen.
    ///
    /// - Returns: `true` if the lock request was **dispatched** without a
    ///   detectable error; `false` if dispatch failed in a way we can observe.
    ///
    /// - Important: For the `osascript` implementation (ADR-0006), `true` means
    ///   only that the keystroke was dispatched and `osascript` exited 0 — it is
    ///   **NOT** a confirmation that the screen actually locked. See
    ///   `ScreenLocker.lock()` for the known fail-open gap and the deferred
    ///   verification follow-up.
    @discardableResult
    func lock() -> Bool
}

/// macOS screen-lock implementation.
///
/// Mechanism (ADR-0006): synthesizes the macOS Lock Screen shortcut
/// **Ctrl-Cmd-Q** via `osascript` / System Events. `key code 12` is the `Q` key;
/// Ctrl-Cmd-Q is the system Lock Screen shortcut.
///
/// - Important: This requires macOS **Accessibility** permission
///   (System Settings → Privacy & Security → Accessibility) because it sends a
///   synthetic keystroke. If the permission is **not** granted, macOS drops the
///   keystroke and the screen does **not** lock — in that case `osascript`
///   typically exits non-zero and `lock()` returns `false`, so the caller can
///   surface honest status rather than pretending the machine is protected. This
///   is a permission distinct from the camera grant (see EC-19,
///   SECURITY_PRIVACY.md).
///
/// - Warning: **What the `Bool` return value actually means.** `lock()` returns
///   `true` only to say that `osascript` **launched and exited 0**, i.e. the
///   keystroke was *dispatched*. It is **NOT** a confirmation that the screen
///   actually locked. Exit status reflects whether the AppleScript ran, not the
///   resulting system state.
///
///   Known fail-open gap (accepted for MVP): if the user has **remapped or
///   disabled** the Ctrl-Cmd-Q Lock-Screen shortcut (System Settings →
///   Keyboard → Keyboard Shortcuts), or in some permission/Accessibility states,
///   the keystroke can be dispatched and `osascript` can exit 0 while **nothing
///   locks** — `lock()` then returns `true` even though the machine is still
///   unlocked. This is an *undetectable* fail-open with the current mechanism.
///
///   True lock-state verification (querying CGSession's
///   `CGSSessionScreenIsLocked` after issuing the lock) and a non-blocking/async
///   `lock()` are a **deferred follow-up** (ND-014), not implemented here. Do not
///   treat a `true` return as a guarantee that the session is locked.
public final class ScreenLocker: ScreenLocking, Sendable {
    private let log = Logger(subsystem: "com.nodonuts.app", category: "lock")

    public init() {}

    @discardableResult
    public func lock() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to key code 12 using {control down, command down}",
        ]

        do {
            try process.run()
        } catch {
            // Process failed to launch at all — fail safe, do NOT report locked.
            log.error("Screen lock failed: could not run osascript: \(error.localizedDescription, privacy: .public)")
            return false
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // osascript ran but reported a non-zero status (e.g. Accessibility
            // permission not granted, keystroke dropped). Fail safe.
            log.error("Screen lock failed: osascript exited with status \(process.terminationStatus, privacy: .public). Accessibility permission may not be granted.")
            return false
        }

        // osascript launched and exited 0: the keystroke was DISPATCHED. This is
        // NOT a confirmation that the screen locked (see the type doc for the
        // remapped/disabled-shortcut fail-open and the deferred CGSession
        // verification follow-up, ND-014).
        return true
    }
}
