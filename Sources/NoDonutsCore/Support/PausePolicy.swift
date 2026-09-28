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
