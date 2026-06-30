import AppKit
import CoreGraphics

// Owner: homer (lifecycle) + blart (session/display signals).
// Backlog: ND-013. Edge cases: EC-02, EC-13, EC-14. ADR-0009.
//
// Event-driven monitor of whether this Mac session is *active* (a real user is
// looking at the screen) vs *suspended* (locked, display asleep, or not on the
// console / fast-user-switched away). When suspended there is nobody to verify
// and the camera may be reassigned to the login window, so the presence loop is
// paused and the camera is stopped; both resume cleanly on unlock/wake.
//
// Lives in the **App target** (AppKit) on purpose: NoDonutsCore stays
// AppKit-free (ADR-0007), so this OS-session glue does not leak into the
// testable core. The engine itself only ever sees the resulting start/stop of
// the loop — it has no opinion on *why* the session is suspended.
@MainActor
public final class SessionStateMonitor {
    /// True when the session is active (NOT suspended). The loop should only run
    /// while this is true.
    public private(set) var isActive: Bool

    /// Fired on transitions only (never for a no-op recompute), with the new
    /// `isActive` value. Set this before `start()`.
    public var onChange: ((Bool) -> Void)?

    public init() {
        // Compute the initial state before observing, so a launch while locked
        // starts suspended.
        self.isActive = SessionStateMonitor.currentlyActive()
    }

    /// Register for the OS session/display notifications. Safe to call once.
    public func start() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(
                self,
                selector: #selector(recompute),
                name: Notification.Name(name),
                object: nil
            )
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in workspaceNames {
            workspace.addObserver(
                self,
                selector: #selector(recompute),
                name: name,
                object: nil
            )
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Recompute the active/suspended state; fire `onChange` only if it changed.
    /// Notifications deliver on the main thread, so `@MainActor` is satisfied.
    @objc private func recompute() {
        let nowActive = SessionStateMonitor.currentlyActive()
        guard nowActive != isActive else { return }
        isActive = nowActive
        onChange?(nowActive)
    }

    /// Returns false (suspended) if ANY of: the screen is locked, the session is
    /// not on the console (fast-user-switched away), or the main display is
    /// asleep. Defaults to active (true) when the session dictionary can't be
    /// read, so we never wedge the loop off on an unknown state.
    private static func currentlyActive() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            return false
        }

        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // Unknown session state → assume active rather than silently
            // suspending the loop forever.
            return true
        }

        if let locked = info["CGSSessionScreenIsLocked"] as? Bool, locked {
            return false
        }
        // "kCGSSessionOnConsoleKey": present + true means this session owns the
        // console. Treat an explicit `false` as suspended (fast user switch).
        // (The C #define isn't bridged to Swift, so use the raw string key.)
        if let onConsole = info["kCGSSessionOnConsoleKey"] as? Bool, !onConsole {
            return false
        }

        return true
    }
}
