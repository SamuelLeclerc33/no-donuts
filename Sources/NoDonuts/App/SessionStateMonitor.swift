import AppKit
import CoreGraphics
import os

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

    private let log = Logger(subsystem: "com.nodonuts.app", category: "session")
    /// Safety-net poll (see `start()`): re-reads authoritative session state so a
    /// MISSED lock/unlock notification can't wedge the monitor. Held so it can be
    /// invalidated on deinit.
    private var safetyTimer: Timer?
    /// How often the safety poll re-checks. Cheap (a CGSession dict read); the value
    /// is a small resume latency, not a busy loop.
    private let safetyInterval: TimeInterval = 2

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

        // Safety-net poll. The notifications above are the fast path, but our screen
        // lock is a non-standard mechanism (SACLockScreenImmediate / CGSession
        // -suspend, ADR-0010) whose RETURN does not reliably post
        // `com.apple.screenIsUnlocked` / a workspace active event. Without a fallback
        // a missed unlock event wedges `isActive == false` forever → the presence
        // loop never resumes and the app is stuck "locked" after you unlock. This
        // timer re-reads the authoritative CGSession/CGDisplay state every couple
        // seconds and `recompute()` fires `onChange` only on a real transition, so it
        // self-heals a missed event within `safetyInterval` at negligible cost.
        // Block-based + [weak self] so the run loop's retain of the timer does NOT
        // create a retain cycle with the monitor; if the monitor is ever freed the
        // timer self-invalidates on its next fire.
        let timer = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Timer fires on the main run loop → we're on the main thread; recompute()
            // is @MainActor-isolated.
            MainActor.assumeIsolated { self.recompute() }
        }
        timer.tolerance = safetyInterval / 2   // let the OS coalesce it (power-friendly)
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // The safety timer is block-based with [weak self]; it self-invalidates on its
        // next fire once self is gone, so it's not touched here (a non-Sendable Timer
        // can't be accessed from a nonisolated deinit).
    }

    /// Recompute the active/suspended state; fire `onChange` only if it changed.
    /// Notifications deliver on the main thread, so `@MainActor` is satisfied.
    @objc private func recompute() {
        let nowActive = SessionStateMonitor.currentlyActive()
        guard nowActive != isActive else { return }
        isActive = nowActive
        log.notice("session state → \(nowActive ? "active" : "suspended", privacy: .public)")
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
