import CoreGraphics
import Darwin
import Foundation
import os

// Owner: wiggum — screen locking + fail-safe enforcement + anti-spoofing hooks.
// Backlog: ND-014, ND-041. We LOCK only; unlock stays with macOS (Touch ID/password).

/// A programmatic screen-lock mechanism, in **chain order** (`allCases` is the
/// order `ScreenLocker.lock()` tries them). Both live in the private
/// `login.framework` and are resolved at runtime (ADR-0010).
public enum LockMechanism: String, Sendable, CaseIterable {
    /// `SACLockScreenImmediate` — locks the current session in place (lock screen).
    case sacLockScreenImmediate
    /// `SACSwitchToLoginWindow` — switches to the login window (fast-user-switch
    /// style; the session goes off-console). Fallback only.
    case sacSwitchToLoginWindow

    /// The C symbol exported by `login.framework` for this mechanism.
    public var symbolName: String {
        switch self {
        case .sacLockScreenImmediate: return "SACLockScreenImmediate"
        case .sacSwitchToLoginWindow: return "SACSwitchToLoginWindow"
        }
    }
}

/// Result of a lock self-test (ND-058): which mechanisms are resolvable right now,
/// in chain order. `canLock == false` means the app CANNOT lock this Mac and must
/// say so loudly — never pretend to protect (fail-safe, ND-014).
///
/// - Important: "available" means the symbol RESOLVED, not that invoking it is
///   proven to lock. The self-test never invokes anything; `lock()` still
///   verifies every attempt against CGSession.
public struct LockCapability: Sendable, Equatable {
    public let available: [LockMechanism]
    public var canLock: Bool { !available.isEmpty }
    public init(available: [LockMechanism]) { self.available = available }
}

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

    /// Reports which lock mechanisms are usable, WITHOUT locking (ND-058). Must
    /// never invoke a mechanism — it is safe to call at launch / on wake.
    func selfTest() -> LockCapability
}

extension ScreenLocking {
    /// Default for fakes/test doubles: every mechanism available.
    public func selfTest() -> LockCapability {
        LockCapability(available: LockMechanism.allCases)
    }
}

/// macOS screen-lock implementation.
///
/// Mechanism (ADR-0010, supersedes ADR-0006): a **layered, no-Accessibility**
/// chain, both symbols resolved at runtime via `dlopen`/`dlsym` from the private
/// `login.framework` (no link-time dependency):
///
/// 1. **`SACLockScreenImmediate`** — locks the session in place, immediately.
/// 2. **`SACSwitchToLoginWindow`** — fallback: switches to the login window
///    (presents like fast user switching: the session goes off-console).
///
/// - Note: macOS 27 removed the `CGSession` tool (`User.menu/.../CGSession`), so
///   the former `CGSession -suspend` fallback is gone (ND-074). Both remaining
///   mechanisms live in the SAME private framework, so if Apple removes/renames
///   it, BOTH fail together — which is why `selfTest()` exists (ND-058): the app
///   checks at launch/wake and warns loudly instead of discovering it at the
///   first walk-away.
///
/// Each attempt is **CGSession-verified**: `lock()` returns `true` only once the
/// session reports locked (`CGSSessionScreenIsLocked`) OR is no longer on the
/// console (`kCGSSessionOnConsoleKey == false`, how `SACSwitchToLoginWindow`
/// presents). If no mechanism achieves a confirmed lock, `lock()` logs a warning
/// and returns `false` so the caller can surface honest `.lockFailed` status
/// rather than pretending the machine is protected.
///
/// - Important: **No Accessibility permission is required or requested.** The
///   prior osascript / Ctrl-Cmd-Q path (ADR-0006) needed Accessibility, which was
///   unreliable on ad-hoc-signed builds and did not lock on the target Mac. See
///   EC-19, SECURITY_PRIVACY.md.
///
/// - Note: `lock()` is `async`. The verification poll uses `Task.sleep` (not
///   `Thread.sleep`), so the main actor is never blocked while a lock is pending.
public final class ScreenLocker: ScreenLocking, @unchecked Sendable {
    public typealias SymbolResolver = @Sendable (String) -> UnsafeMutableRawPointer?
    /// Invokes a RESOLVED mechanism. Default: calls it as `void (*)(void)`.
    public typealias Invoker = @Sendable (LockMechanism, UnsafeMutableRawPointer) -> Void
    /// Reads whether the screen is currently locked. Default: CGSession.
    public typealias LockProbe = @Sendable () -> Bool

    private let log = Logger(subsystem: Log.subsystem, category: Log.Category.lock)
    private let resolveSymbol: SymbolResolver
    private let invoke: Invoker
    private let isLockedProbe: LockProbe?
    private let lockTimeout: TimeInterval

    /// Production initializer. `resolveSymbol` is injectable so `selfTest()` can
    /// be checked with fake resolvers (never invoke a fake pointer).
    public convenience init(resolveSymbol: @escaping SymbolResolver = ScreenLocker.loginFrameworkSymbol) {
        self.init(resolveSymbol: resolveSymbol, invoke: ScreenLocker.invokeC, isLocked: nil)
    }

    /// Full-seam initializer for tests: `invoke` and `isLocked` let `lock()`
    /// ordering/fallthrough be verified WITHOUT touching a real lock symbol.
    /// Production code should use `init(resolveSymbol:)`.
    public init(resolveSymbol: @escaping SymbolResolver,
                invoke: @escaping Invoker,
                isLocked: LockProbe?,
                lockTimeout: TimeInterval = 3.0) {
        self.resolveSymbol = resolveSymbol
        self.invoke = invoke
        self.isLockedProbe = isLocked
        self.lockTimeout = lockTimeout
    }

    // MARK: - login.framework resolution

    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"

    /// `login.framework` handle, opened ONCE (lazily, thread-safe static init)
    /// and intentionally never `dlclose`d — the symbols must stay valid for the
    /// process lifetime. `nil` if the framework can't be loaded (logged once).
    nonisolated(unsafe) private static let loginFrameworkHandle: UnsafeMutableRawPointer? = {
        let handle = dlopen(loginFrameworkPath, RTLD_NOW)
        if handle == nil {
            Logger(subsystem: Log.subsystem, category: Log.Category.lock).warning(
                "dlopen(\(loginFrameworkPath, privacy: .public)) returned nil; no lock mechanism is resolvable.")
        }
        return handle
    }()

    /// Default resolver: `dlsym` against the cached `login.framework` handle.
    /// Resolves only — never calls the symbol.
    @Sendable
    public static func loginFrameworkSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = loginFrameworkHandle else { return nil }
        return dlsym(handle, name)
    }

    /// Default invoker. Both SAC entry points are `void (*)(void)`.
    private static let invokeC: Invoker = { _, sym in
        typealias LockFn = @convention(c) () -> Void
        unsafeBitCast(sym, to: LockFn.self)()
    }

    // MARK: - Self-test + lock

    /// Resolves each mechanism's symbol, in chain order. NEVER invokes one.
    public func selfTest() -> LockCapability {
        LockCapability(available: resolvedChain().map(\.0))
    }

    private func resolvedChain() -> [(LockMechanism, UnsafeMutableRawPointer)] {
        LockMechanism.allCases.compactMap { m in resolveSymbol(m.symbolName).map { (m, $0) } }
    }

    @discardableResult
    public func lock() async -> Bool {
        // ONE shared deadline across the whole chain so lock() is bounded at
        // ~lockTimeout (not per mechanism), keeping the presence loop responsive.
        let deadline = Date().addingTimeInterval(lockTimeout)
        let chain = resolvedChain()
        if chain.isEmpty {
            log.warning("Screen lock impossible: no lock mechanism resolvable in login.framework.")
            return false
        }

        for (index, (mechanism, sym)) in chain.enumerated() {
            if isScreenLockedNow() {
                // A previous (unconfirmed-in-time) attempt landed late — done.
                log.notice("lock confirmed via \(chain[max(index - 1, 0)].0.rawValue, privacy: .public)")
                return true
            }
            // A non-last mechanism gets MOST (80%) of the remaining budget, so a
            // slow-but-working lock (animation, busy machine) confirms before we
            // fire the fallback (which would drop the user at the login window
            // instead of their lock screen). The remaining 20% still guarantees
            // the fallback real verification time if the first silently does
            // nothing. The last mechanism gets everything left.
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            let isLast = index == chain.count - 1
            let slice = Date().addingTimeInterval(isLast ? remaining : remaining * 0.8)
            invoke(mechanism, sym)
            if await waitForScreenLocked(deadline: slice) {
                log.notice("lock confirmed via \(mechanism.rawValue, privacy: .public)")
                return true
            }
            log.warning("\(mechanism.symbolName, privacy: .public) invoked but CGSession never reported locked.")
            if Task.isCancelled { break }
        }
        log.warning("Screen lock NOT confirmed: no mechanism (\(chain.map(\.0.rawValue).joined(separator: ", "), privacy: .public)) achieved a CGSession-confirmed lock.")
        return false
    }

    /// Reads the current login session state and reports whether the screen is
    /// locked. Pure read of `CGSessionCopyCurrentDictionary()`.
    ///
    /// The screen counts as locked if EITHER `CGSSessionScreenIsLocked` is true OR
    /// the session is not on the console (`kCGSSessionOnConsoleKey == false`, how
    /// `SACSwitchToLoginWindow` presents). The on-console signal is only used when the
    /// key is actually present, so a normal unlocked session (key present + true)
    /// reports NOT locked, and an absent key does not wrongly report locked.
    private func isScreenLockedNow() -> Bool {
        if let probe = isLockedProbe { return probe() }
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
        // reliably means our own `SACSwitchToLoginWindow` fallback succeeded
        // (login window), not a stray FUS state. See ADR-0010 (consequences), EC-19.
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
    /// across the whole mechanism chain.
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
