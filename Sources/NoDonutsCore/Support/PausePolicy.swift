import Foundation

// Owner: krusty (+ homer) — pure pause / liveness-reminder policy (ND-080, ND-082).
// AppKit-free and timer-free (ADR-0007) so EngineCheck can verify it; the App-target
// PauseController / LifecycleNotifier own the actual timers and notifications.

/// What kind of pause is active.
public enum PauseKind: Equatable, Sendable {
    /// "Pause for 15 minutes / 1 hour": auto-resumes at its expiry.
    case timed
    /// "Pause until I resume": no expiry.
    case indefinite
}

public enum PausePolicy {
    /// ND-080 / EC-15: does a pause of `kind` END when the session suspends (screen
    /// locks, display sleeps, fast-user-switch away)?
    ///
    /// - `.indefinite` → YES. It's the only pause that could otherwise survive
    ///   forever; ending it on suspend means the user always comes back to a
    ///   protected Mac, whatever they forgot.
    /// - `.timed` → NO. It is already bounded (≤ 1 h) and the user picked the
    ///   duration deliberately (e.g. "1 h while I present in the next room" — the
    ///   display may sleep meanwhile). It expires on its own schedule.
    public static func endsOnSessionSuspend(_ kind: PauseKind) -> Bool {
        switch kind {
        case .indefinite: return true
        case .timed: return false
        }
    }

    /// ND-080: does a pause of `kind` get the periodic "still paused" reminder?
    /// Only indefinite pauses — a timed pause ends by itself.
    public static func remindsWhilePaused(_ kind: PauseKind) -> Bool {
        kind == .indefinite
    }

    /// ND-080: cadence of the "No Donuts is paused" reminder.
    public static let pausedReminderInterval: TimeInterval = 30 * 60
}

/// ND-082: dead-man ("No Donuts isn't running") notification timing.
///
/// While the process is alive it keeps ONE pending local notification scheduled
/// `fireDelay` in the future and re-schedules (replaces) it every
/// `heartbeatInterval`. If the process dies (kill, crash, scripted quit) the
/// heartbeat stops and the notification fires ≤ `fireDelay` later.
public enum DeadManPolicy {
    /// How often a live process pushes the pending notification back.
    public static let heartbeatInterval: TimeInterval = 60
    /// How far in the future the pending notification is scheduled while alive.
    public static let fireDelay: TimeInterval = 10 * 60
    /// After a deliberate Quit from our menu: remind the user this much later.
    public static let quitReminderDelay: TimeInterval = 30 * 60

    /// Invariant: a live process must always re-schedule well before the pending
    /// notification could fire, even if a heartbeat is late (timer tolerance, a
    /// busy main thread). Requires ≥ 3 missed heartbeats of slack.
    public static func heartbeatKeepsAhead(heartbeat: TimeInterval = heartbeatInterval,
                                           fireDelay: TimeInterval = fireDelay) -> Bool {
        heartbeat > 0 && fireDelay >= heartbeat * 3
    }
}

/// ND-112: "No Donuts didn't start after you logged in" (`nd.didNotStart`).
///
/// Residual from the ND-109 threat model: with no launcher (Start at login off, or
/// the agent still waiting for approval), a logout / reboot ends the process and
/// nothing brings it back, silently. On `willPowerOff` the app schedules a local
/// notification `fireDelay` ahead; the next launch removes it (pending + delivered).
///
/// A logout can be CANCELLED (an app refuses to quit, the user cancels), leaving us
/// running with that request pending. While alive, the heartbeat pushes it back
/// (`.pushBack`) so it can't fire over a live app; once `cancelledLogoutWindow` has
/// passed since the power-off with the process still alive, the logout clearly
/// didn't happen and the request is removed (`.remove`). Pure / timer-free
/// (ADR-0007): the App-target LifecycleNotifier owns the notification itself.
public enum DidNotStartPolicy {
    /// How long after logout the reminder fires if nothing started us. Long enough
    /// for a login + the agent's launch, short enough to catch the user at the desk.
    public static let fireDelay: TimeInterval = 5 * 60
    /// Still alive this long after `willPowerOff` → the logout was cancelled.
    /// Longer than any completed logout we've seen (apps get well under a minute);
    /// a slower one only degrades back to the pre-ND-112 residual (no alert).
    public static let cancelledLogoutWindow: TimeInterval = 5 * 60

    /// Schedule the reminder at power-off only when nothing will start the app after
    /// login. `loginItemEnabled` must be the STRICT answer (`SMAppService.Status ==
    /// .enabled`): `.requiresApproval` / `.notFound` won't launch anything at login.
    /// (Scheduling unconditionally was tried and reverted in review: an overdue one-shot
    /// can be delivered at login BEFORE the agent launches the app → a false alarm at
    /// every normal login. Accepted gap: an agent booted out while still `.enabled`.)
    public static func shouldSchedule(loginItemEnabled: Bool) -> Bool {
        !loginItemEnabled
    }

    public enum HeartbeatAction: Equatable, Sendable {
        /// Re-schedule it `fireDelay` from now (a logout may still complete).
        case pushBack
        /// The logout was cancelled; remove the pending request.
        case remove
    }

    /// What a heartbeat that runs `secondsSincePowerOff` after the scheduling
    /// power-off should do with the pending reminder. Negative (clock went back) is
    /// treated as "just happened".
    public static func heartbeatAction(secondsSincePowerOff: TimeInterval,
                                       window: TimeInterval = cancelledLogoutWindow) -> HeartbeatAction {
        max(0, secondsSincePowerOff) < window ? .pushBack : .remove
    }
}

/// ND-113: coarse notification-authorization state, mirrored from
/// `UNAuthorizationStatus` by the App target (Core stays UserNotifications-free).
public enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral

    /// Show the persistent "Notifications off" menu warning? Only for `.denied`:
    /// every alarm (dead-man, lock-failed, not-protecting, identity-off, didn't-start)
    /// is silently dropped then. `.notDetermined` → no warning; onboarding asks.
    /// Provisional / ephemeral still deliver (quietly), so no warning either.
    public var showsNotificationsOffWarning: Bool { self == .denied }
}
