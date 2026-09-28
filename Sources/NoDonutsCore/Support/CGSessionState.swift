import CoreGraphics
import Foundation

// Owner: blart (session/display signals) + wiggum (lock verification).
// Backlog: ND-064 (shared CGSession reader), ND-090 (display-asleep ≠ locked).
// Edge cases: EC-02, EC-13, EC-14, EC-19. ADR-0009, ADR-0010.
//
// ONE defensive reader of `CGSessionCopyCurrentDictionary()`, consumed by both
// `ScreenLocker` (lock verification) and the app's `SessionStateMonitor` (loop
// suspend). Before ND-064 the two parsed the dictionary separately and had already
// drifted (the locker bridged NSNumber, the monitor used bare `as? Bool`).
// AppKit-free, so the parsing is EngineCheck-covered.

/// A parsed snapshot of the current login session.
public struct CGSessionState: Equatable, Sendable {
    /// `CGSSessionScreenIsLocked` is present and true.
    public var screenLocked: Bool
    /// `kCGSSessionOnConsoleKey`: `true`/`false` when present and readable; `nil`
    /// when absent or of an unexpected type. Callers treat `nil` as ON console:
    /// that keeps the loop running (monitor) and never claims a lock we can't
    /// confirm (locker). Both directions are the safe ones.
    public var onConsole: Bool?

    public init(screenLocked: Bool, onConsole: Bool?) {
        self.screenLocked = screenLocked
        self.onConsole = onConsole
    }

    /// Explicitly off the console (fast-user-switched away, or the login window
    /// after `SACSwitchToLoginWindow`). An unknown on-console value is NOT off-console.
    public var isOffConsole: Bool { onConsole == false }

    /// The session counts as locked: screen locked OR explicitly off-console.
    /// (See ScreenLocker for the FUS caveat on the off-console half.)
    public var isLockedOrOffConsole: Bool { screenLocked || isOffConsole }

    public static let screenLockedKey = "CGSSessionScreenIsLocked"
    /// The C `#define kCGSessionOnConsoleKey` is not bridged to Swift; raw key.
    public static let onConsoleKey = "kCGSSessionOnConsoleKey"

    /// Parse a CGSession dictionary. `nil` in → `nil` out (unknown state; each
    /// caller picks its own safe default).
    public static func parse(_ dict: [String: Any]?) -> CGSessionState? {
        guard let dict else { return nil }
        return CGSessionState(
            screenLocked: flag(dict[screenLockedKey]) ?? false,
            onConsole: flag(dict[onConsoleKey])
        )
    }

    /// Read the live session. `nil` if the dictionary can't be read (e.g. no
    /// window-server session).
    public static func current() -> CGSessionState? {
        parse(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// Defensive boolean read: CFBoolean values may bridge as `Bool` or
    /// `NSNumber`. Anything else (absent, string, …) → `nil`.
    public static func flag(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}

/// Main-display sleep state (CoreGraphics). Informational only since ND-090 — a
/// dark display does NOT suspend the presence loop.
public enum DisplaySleepState {
    public static func mainDisplayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}

/// When should the presence loop + camera be suspended (ND-013, ND-090)?
public enum SessionSuspendPolicy {
    /// Suspend ONLY when there is nobody we could (or should) verify:
    /// - the screen is locked (macOS already protects the Mac), or
    /// - this session is not on the console (FUS / login window), or
    /// - the machine is going to / is in system sleep.
    ///
    /// `displayAsleep` is deliberately ignored (ND-090, EC-02/EC-13): a dimmed or
    /// asleep display while the session is still UNLOCKED (display-sleep before lock,
    /// or a "require password after N minutes" delay) is exactly when someone could
    /// wake the screen and use the Mac. The camera still works with the display off,
    /// so the loop keeps running and walking away still locks after consensus + grace.
    public static func shouldSuspend(locked: Bool, onConsole: Bool, displayAsleep: Bool,
                                     systemSleeping: Bool) -> Bool {
        _ = displayAsleep
        return locked || !onConsole || systemSleeping
    }

    /// Convenience over a parsed snapshot. An unreadable session (`nil`) is treated
    /// as active — never wedge the loop off on an unknown state.
    public static func shouldSuspend(session: CGSessionState?, displayAsleep: Bool,
                                     systemSleeping: Bool) -> Bool {
        shouldSuspend(locked: session?.screenLocked ?? false,
                      onConsole: !(session?.isOffConsole ?? false),
                      displayAsleep: displayAsleep,
                      systemSleeping: systemSleeping)
    }

    /// How long the Mac must have been AWAKE after `willSleep` without a matching
    /// `didWake` before the monitor treats its "system sleeping" flag as stale (a
    /// cancelled sleep or a missed wake notification). Measured on
    /// `ProcessInfo.systemUptime`, which does not advance while the Mac is asleep,
    /// so real sleep time never counts toward it.
    public static let staleSleepFlagAfter: TimeInterval = 30

    /// True when a `willSleep` flag should be cleared by the safety poll.
    public static func sleepFlagIsStale(willSleepUptime: TimeInterval,
                                        nowUptime: TimeInterval) -> Bool {
        nowUptime - willSleepUptime >= staleSleepFlagAfter
    }
}
