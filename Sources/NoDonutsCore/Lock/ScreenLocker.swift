import CoreGraphics
import Darwin
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
    /// Locks the screen. Returns true only if the lock is CONFIRMED (CGSession).
    @discardableResult
    func lock() async -> Bool
}

/// macOS screen-lock implementation.
///
/// Mechanism (ADR-0010, supersedes ADR-0006): a **layered, no-Accessibility**
/// lock:
///
/// 1. **`SACLockScreenImmediate`** — resolved at runtime via `dlopen`/`dlsym` from
///    `login.framework` (no link-time dependency on the private framework). Locks
///    immediately with no Accessibility grant. If the symbol can't be resolved we
///    skip to the fallback.
/// 2. **`CGSession -suspend`** — spawns the public `CGSession` tool with
///    `-suspend`, which switches to the login window (also no Accessibility grant).
///
/// After each attempt the lock is **CGSession-verified**: `lock()` returns `true`
/// only once the session reports locked (`CGSSessionScreenIsLocked`) OR is no
/// longer on the console (`kCGSSessionOnConsoleKey == false`, how `-suspend`
/// presents). If neither mechanism achieves a confirmed lock, `lock()` logs a
/// warning via `os_log` and returns `false` so the caller can surface honest
/// `.lockFailed` status rather than pretending the machine is protected.
///
/// - Important: **No Accessibility permission is required or requested.** The
///   prior osascript / Ctrl-Cmd-Q path (ADR-0006) needed Accessibility, which was
///   unreliable on ad-hoc-signed builds and did not lock on the target Mac. See
///   EC-19, SECURITY_PRIVACY.md.
///
/// - Note: `lock()` is `async`. The verification poll uses `Task.sleep` (not
///   `Thread.sleep`), so the main actor is never blocked while a lock is pending.
public final class ScreenLocker: ScreenLocking, @unchecked Sendable {
    private let log = Logger(subsystem: "com.nodonuts.app", category: "lock")

    public init() {}

    @discardableResult
    public func lock() async -> Bool {
        // ONE shared ~3s deadline across BOTH mechanisms so the whole lock() call
        // is bounded at ~3s (not 3s per mechanism = ~6s), keeping the awaiting
        // presence tick loop responsive.
        let deadline = Date().addingTimeInterval(3.0)

        // 1. Try SACLockScreenImmediate (private symbol, loaded defensively).
        if callSACLockScreenImmediate() {
            if await waitForScreenLocked(deadline: deadline) {
                return true
            }
            // Symbol resolved and called but the session never reported locked —
            // fall through to the public fallback rather than trusting it. The
            // fallback poll uses the REMAINING budget of the shared deadline.
            log.warning("SACLockScreenImmediate called but CGSession never reported locked; trying CGSession -suspend fallback.")
        }

        // 2. Fallback: CGSession -suspend (public, switches to the login window).
        runCGSessionSuspend()
        let locked = await waitForScreenLocked(deadline: deadline)
        if !locked {
            log.warning("Screen lock not confirmed within timeout (neither SACLockScreenImmediate nor CGSession -suspend achieved a confirmed CGSession lock).")
        }
        return locked
    }

    /// Attempts to resolve and invoke `SACLockScreenImmediate` from
    /// `login.framework` at runtime.
    ///
    /// - Returns: `true` if the symbol was resolved AND invoked (NOT proof of a
    ///   lock — the caller must still verify via CGSession); `false` if the
    ///   framework/symbol could not be loaded so the caller should fall back.
    private func callSACLockScreenImmediate() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_NOW) else {
            log.info("SACLockScreenImmediate unavailable: dlopen(\(path, privacy: .public)) returned nil; using fallback.")
            return false
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            log.info("SACLockScreenImmediate unavailable: dlsym returned nil; using fallback.")
            return false
        }

        typealias LockFn = @convention(c) () -> Void
        let fn = unsafeBitCast(sym, to: LockFn.self)
        fn()
        return true
    }

    /// Spawns the public `CGSession -suspend` tool, which switches to the login
    /// window. This path does not require Accessibility. Failures to launch are
    /// non-fatal for control flow — the caller verifies the actual lock state via
    /// CGSession — but ARE logged so a launch failure is never silently swallowed.
    ///
    /// - Note: We do NOT `waitUntilExit()`. That would block the calling (main)
    ///   actor synchronously; and we don't need the tool's exit code — the
    ///   `waitForScreenLocked` verify poll is what actually confirms the lock.
    private func runCGSessionSuspend() {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath:
                "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        process.arguments = ["-suspend"]
        do {
            try process.run()
        } catch {
            log.error("CGSession -suspend failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the current login session state and reports whether the screen is
    /// locked. Pure read of `CGSessionCopyCurrentDictionary()`.
    ///
    /// The screen counts as locked if EITHER `CGSSessionScreenIsLocked` is true OR
    /// the session is not on the console (`kCGSSessionOnConsoleKey == false`, how
    /// `CGSession -suspend` presents). The on-console signal is only used when the
    /// key is actually present, so a normal unlocked session (key present + true)
    /// reports NOT locked, and an absent key does not wrongly report locked.
    private func isScreenLockedNow() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if flag(d, "CGSSessionScreenIsLocked") {
            return true
        }
        // Only trust the on-console signal when the key is actually present:
        // absent key → treat as on-console (NOT locked).
        //
        // FUS caveat: `kCGSSessionOnConsoleKey == false` is ambiguous — it can
        // also mean this session was FAST-USER-SWITCHED away (another account
        // took the console), not password-locked by us. In practice that
        // ambiguity is benign here: lock() is only ever called while this session
        // is ON console, because SessionStateMonitor pauses the presence loop when
        // off-console (ND-013, EC-14). So at the moment we read this, off-console
        // reliably means our own `CGSession -suspend` succeeded (login window),
        // not a stray FUS state. See ADR-0010 (consequences), EC-19.
        if d["kCGSSessionOnConsoleKey"] != nil, !flag(d, "kCGSSessionOnConsoleKey") {
            return true
        }
        return false
    }

    /// Reads a boolean flag from a CGSession dictionary defensively: the values
    /// are `CFBoolean` and may bridge as `Bool` or `NSNumber`.
    private func flag(_ dict: [String: Any], _ key: String) -> Bool {
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        return false
    }

    /// Polls `isScreenLockedNow()` until it reports locked or the shared `deadline`
    /// passes, returning the final observed state. The lock is not instantaneous
    /// after the mechanism is invoked, so a short bounded poll is needed. Taking a
    /// `deadline` (not a per-call timeout) lets `lock()` share ONE ~3s budget
    /// across both mechanisms: the fallback poll only consumes the remaining time.
    /// If the deadline has already passed on entry, this does one final
    /// `isScreenLockedNow()` check and returns it.
    ///
    /// - Note: Uses `Task.sleep`, NOT `Thread.sleep`, so the calling actor (the
    ///   main actor, for the presence engine) is never blocked.
    ///
    /// - Cancellation: this poll is cancellation-aware. If the enclosing task is
    ///   cancelled — including a `Task.sleep` that throws on cancellation — we stop
    ///   immediately and return the current `isScreenLockedNow()` rather than
    ///   busy-spinning to the deadline (which `try?` on the sleep would otherwise
    ///   cause: cancellation returns instantly and the loop tight-spins the CPU).
    private func waitForScreenLocked(deadline: Date) async -> Bool {
        while !Task.isCancelled {
            if isScreenLockedNow() {
                return true
            }
            if Date() >= deadline {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            } catch {
                break  // cancelled → stop polling, report current state below
            }
        }
        return isScreenLockedNow()
    }
}
