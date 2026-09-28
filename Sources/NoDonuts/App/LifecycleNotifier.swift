import AppKit
import UserNotifications
import NoDonutsCore

// Owner: krusty — process-liveness + paused reminders (ND-082, ND-080, EC-15).
//
// Trust rule: the menu-bar glyph can't tell the user anything once the process is
// dead, and an indefinite pause is easy to forget. Two local notifications cover it:
//
//   - `nd.notRunning` (dead-man, ND-082): while the process is alive we keep ONE
//     pending request scheduled `DeadManPolicy.fireDelay` ahead and push it back every
//     `heartbeatInterval` on a main-run-loop Timer that is INDEPENDENT of the
//     enforcement loop (paused / suspended / trusted-network still count as running —
//     this is about the PROCESS). If we're killed, crash, or are quit by a script, the
//     heartbeat stops and the notification fires ≤ 10 min later. A deliberate Quit
//     from our menu re-schedules it at +30 min with "was quit" copy.
//   - `nd.pausedReminder` (ND-080): every 30 min while an INDEFINITE pause is active;
//     cleared on resume.
//
// System sleep: the Timer doesn't fire while asleep but a time-interval trigger can
// come due, so a >10 min sleep would falsely claim "not running" on wake. We remove
// the pending dead-man on willSleep and re-arm it on didWake. Logout / shutdown remove
// it once (not a user "stop protecting" action; the login item relaunches us) but keep
// the heartbeat, so a CANCELLED logout re-arms within a minute.
//
// If notifications aren't authorized, `add` just fails — nothing else can surface a
// dead process, so this is reported in diagnostics (see `authorizationDescription`).
// Local notifications only: static copy, no PII, nothing leaves the device.
@MainActor
final class LifecycleNotifier {
    nonisolated static let notRunningID = "nd.notRunning"
    nonisolated static let pausedReminderID = "nd.pausedReminder"

    private var heartbeatTimer: Timer?
    private var pausedReminderTimer: Timer?
    /// False after a menu Quit so a late heartbeat can't overwrite the "was quit"
    /// reminder. (Power-off does NOT clear it: a cancelled logout must re-arm.)
    private var heartbeatEnabled = false
    private var observers: [NSObjectProtocol] = []

    /// Launch: clear any stale delivered alerts from a previous run, arm the dead-man,
    /// and start the heartbeat. Call once from applicationDidFinishLaunching.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notRunningID, Self.pausedReminderID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedReminderID])

        heartbeatEnabled = true
        scheduleDeadMan()
        startHeartbeat()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillPowerOff() }
        })
    }

    // MARK: - Dead-man (ND-082)

    /// Deliberate Quit from our menu: stop the heartbeat, clear the paused reminder,
    /// and re-schedule the dead-man at +30 min with "was quit" copy. `completion` runs
    /// on main once the request is registered (or after a short timeout), so the caller
    /// can terminate without racing the async `add`.
    func prepareForUserQuit(completion: @escaping @MainActor () -> Void) {
        heartbeatEnabled = false
        stopHeartbeat()
        updatePause(indefinitelyPaused: false)

        var done = false
        let finish: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            completion()
        }
        let content = UNMutableNotificationContent()
        content.title = "No Donuts was quit"
        content.body = "Your Mac isn\u{2019}t protected \u{2014} it won\u{2019}t lock when you walk away. Open No Donuts to turn protection back on."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notRunningID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: DeadManPolicy.quitReminderDelay, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }
        // Never let a stuck notification center block Quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { finish() } }
    }

    private func scheduleDeadMan() {
        guard heartbeatEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "No Donuts isn\u{2019}t running"
        content.body = "Your Mac isn\u{2019}t protected \u{2014} it won\u{2019}t lock when you walk away. Open No Donuts to turn protection back on."
        content.sound = .default
        // Same id → replaces the pending request (pushes the fire date back).
        let request = UNNotificationRequest(
            identifier: Self.notRunningID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: DeadManPolicy.fireDelay, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: DeadManPolicy.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDeadMan() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func systemWillSleep() {
        stopHeartbeat()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notRunningID])
    }

    private func systemDidWake() {
        guard heartbeatEnabled else { return }
        scheduleDeadMan()
        startHeartbeat()
    }

    /// Logout / restart / shutdown: remove the pending dead-man ONCE so a completed
    /// logout doesn't later claim "isn't running". The heartbeat keeps running: if the
    /// logout is cancelled (an app refused to quit, or the user cancelled), the next
    /// beat (<= 60 s) re-arms it. If the logout completes, the process dies before
    /// that — or at worst re-arms a notification the next launch replaces.
    private func systemWillPowerOff() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notRunningID])
    }

    /// Undo `prepareForUserQuit` when the quit didn't happen (e.g. turning off
    /// "Start at login" failed after the user confirmed): re-arm the normal dead-man
    /// and restart the heartbeat, replacing the "was quit" copy.
    func cancelUserQuit() {
        heartbeatEnabled = true
        scheduleDeadMan()
        startHeartbeat()
    }

    /// `NoDonuts --unregister` (uninstall): remove every pending AND delivered
    /// notification of ours (`nd.*`: not-running, paused, not-protecting, identity,
    /// lock), so no "isn't running" alert fires after the app is gone. Blocks the
    /// (non-UI) caller until done or `timeout`; returns the number removed.
    nonisolated static func removeAllForUninstall(timeout: TimeInterval = 3) -> Int {
        let center = UNUserNotificationCenter.current()
        let group = DispatchGroup()
        let found = UninstallIDs()
        group.enter()
        center.getPendingNotificationRequests { requests in
            found.set(pending: requests.map(\.identifier))
            group.leave()
        }
        group.enter()
        center.getDeliveredNotifications { notifications in
            found.set(delivered: notifications.map(\.request.identifier))
            group.leave()
        }
        _ = group.wait(timeout: .now() + timeout)
        let (pendingIDs, deliveredIDs) = found.snapshot()
        // Also name the known ids explicitly, in case a query timed out.
        let known = [notRunningID, pausedReminderID]
        center.removePendingNotificationRequests(withIdentifiers: Array(Set(pendingIDs + known)))
        center.removeDeliveredNotifications(withIdentifiers: Array(Set(deliveredIDs + known)))
        // The removes are fire-and-forget; a follow-up query on the same center gives
        // them time to land before the CLI process exits.
        let flush = DispatchSemaphore(value: 0)
        center.getPendingNotificationRequests { _ in flush.signal() }
        _ = flush.wait(timeout: .now() + timeout)
        return Set(pendingIDs).count + Set(deliveredIDs).count
    }

    // MARK: - Paused reminder (ND-080)

    /// Feed after every enforcement-gate pass. Starts the 30-min reminder on entry into
    /// an indefinite pause; clears the timer + delivered/pending reminder on exit.
    func updatePause(indefinitelyPaused: Bool) {
        let active = pausedReminderTimer != nil
        if indefinitelyPaused && !active {
            let timer = Timer(timeInterval: PausePolicy.pausedReminderInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.postPausedReminder() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pausedReminderTimer = timer
        } else if !indefinitelyPaused && active {
            pausedReminderTimer?.invalidate()
            pausedReminderTimer = nil
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.pausedReminderID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.pausedReminderID])
        }
    }

    private func postPausedReminder() {
        let content = UNMutableNotificationContent()
        content.title = "No Donuts is paused"
        content.body = "Your Mac won\u{2019}t lock when you walk away. Resume from the menu bar."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.pausedReminderID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Diagnostics

    /// Coarse notification-permission label for Copy Diagnostics. Calls out that the
    /// "not running" / "paused" reminders can't be shown when not authorized.
    static func authorizationDescription() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return "authorized"
        case .provisional: return "provisional (delivered quietly)"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied (\u{201C}not running\u{201D} / \u{201C}paused\u{201D} reminders can\u{2019}t be shown)"
        case .notDetermined: return "not determined (\u{201C}not running\u{201D} / \u{201C}paused\u{201D} reminders can\u{2019}t be shown yet)"
        @unknown default: return "unknown"
        }
    }
}

/// Thread-safe holder for the `nd.*` ids found by `removeAllForUninstall`.
private final class UninstallIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var delivered: [String] = []

    func set(pending ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        pending = ids.filter { $0.hasPrefix("nd.") }
    }

    func set(delivered ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        delivered = ids.filter { $0.hasPrefix("nd.") }
    }

    func snapshot() -> ([String], [String]) {
        lock.lock(); defer { lock.unlock() }
        return (pending, delivered)
    }
}
