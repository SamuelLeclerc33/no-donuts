import AppKit
import NoDonutsCore
import os

// Owner: homer (lifecycle) + blart (session/display signals).
// Backlog: ND-013, ND-090, ND-064. Edge cases: EC-02, EC-13, EC-14. ADR-0009.
//
// Event-driven monitor of whether this Mac session is *active* vs *suspended*
// (screen locked, not on the console / fast-user-switched away, or the machine
// going into system sleep). When suspended there is nobody to verify and the
// camera may be reassigned to the login window, so the presence loop is paused
// and the camera is stopped; both resume cleanly on unlock/wake.
//
// ND-090: a dark / asleep DISPLAY alone is NOT suspended. With the session still
// unlocked (display sleep before lock, or a "require password after N minutes"
// delay) anyone can wake the screen and use the Mac, so the loop keeps running
// (the camera works with the display off) and walking away still locks after
// consensus + grace. The decision itself is `SessionSuspendPolicy` (NoDonutsCore,
// EngineCheck-covered); the CGSession parsing is the shared `CGSessionState`.
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

    private let log = Logger(subsystem: Log.subsystem, category: "session")
    /// Safety-net poll (see `start()`): re-reads authoritative session state so a
    /// MISSED lock/unlock notification can't wedge the monitor. Held so it can be
    /// invalidated on deinit.
    private var safetyTimer: Timer?
    /// How often the safety poll re-checks. Cheap (a CGSession dict read); the value
    /// is a small resume latency, not a busy loop.
    private let safetyInterval: TimeInterval = 2

    /// `ProcessInfo.systemUptime` at the last `willSleep` without a matching
    /// `didWake`; nil when not sleeping. Uptime does not advance during sleep, so
    /// the safety poll can tell a stale flag (sleep cancelled / wake missed) from a
    /// real sleep — see `SessionSuspendPolicy.sleepFlagIsStale`.
    private var willSleepUptime: TimeInterval?

    public init() {
        // Compute the initial state before observing, so a launch while locked
        // starts suspended.
        self.isActive = SessionStateMonitor.currentlyActive(systemSleeping: false)
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
        // Display sleep/wake are observed only as prompts to re-read the session
        // (a lock often lands around them); they no longer suspend by themselves.
        for name in workspaceNames {
            workspace.addObserver(
                self,
                selector: #selector(recompute),
                name: name,
                object: nil
            )
        }

        // ND-090: SYSTEM sleep (not display sleep) suspends. willSleep arrives while
        // we can still stop the camera cleanly; didWake clears it.
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // Safety-net poll. The notifications above are the fast path, but our screen
        // lock is a non-standard mechanism (SACLockScreenImmediate / CGSession
        // -suspend, ADR-0010) whose RETURN does not reliably post
        // `com.apple.screenIsUnlocked` / a workspace active event. Without a fallback
        // a missed unlock event wedges `isActive == false` forever → the presence
        // loop never resumes and the app is stuck "locked" after you unlock. This
        // timer re-reads the authoritative CGSession state every couple
        // seconds and `recompute()` fires `onChange` only on a real transition, so it
        // self-heals a missed event within `safetyInterval` at negligible cost.
        // Block-based + [weak self] so the run loop's retain of the timer does NOT
        // create a retain cycle with the monitor; if the monitor is ever freed the
        // timer self-invalidates on its next fire.
        let timer = Timer(timeInterval: safetyInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Timer fires on the main run loop → we're on the main thread; recompute()
            // is @MainActor-isolated.
            MainActor.assumeIsolated {
                // A willSleep that never got its didWake (sleep cancelled, event
                // missed) must not wedge us suspended: if we've been AWAKE for a
                // while since willSleep, the flag is stale.
                if let slept = self.willSleepUptime,
                   SessionSuspendPolicy.sleepFlagIsStale(willSleepUptime: slept,
                                                         nowUptime: ProcessInfo.processInfo.systemUptime) {
                    self.log.notice("no didWake after willSleep; clearing stale sleep flag")
                    self.willSleepUptime = nil
                }
                self.recompute()
            }
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
    @objc private func systemWillSleep() {
        willSleepUptime = ProcessInfo.processInfo.systemUptime
        recompute()
    }

    @objc private func systemDidWake() {
        willSleepUptime = nil
        recompute()
    }

    @objc private func recompute() {
        let nowActive = SessionStateMonitor.currentlyActive(systemSleeping: willSleepUptime != nil)
        guard nowActive != isActive else { return }
        isActive = nowActive
        log.notice("session state → \(nowActive ? "active" : "suspended", privacy: .public)")
        onChange?(nowActive)
    }

    /// Returns false (suspended) if ANY of: the screen is locked, the session is
    /// explicitly not on the console, or the machine is going into system sleep.
    /// Display sleep alone does NOT suspend (ND-090). An unreadable session
    /// dictionary counts as active, so we never wedge the loop off on an unknown
    /// state (ND-064 shared reader: Bool/NSNumber bridging).
    private static func currentlyActive(systemSleeping: Bool) -> Bool {
        !SessionSuspendPolicy.shouldSuspend(session: CGSessionState.current(),
                                            displayAsleep: DisplaySleepState.mainDisplayIsAsleep(),
                                            systemSleeping: systemSleeping)
    }
}
