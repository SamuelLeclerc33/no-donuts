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
//   - `nd.didNotStart` (ND-112): on logout / shutdown, if "Start at login" is NOT
//     enabled, nothing will bring us back after the next login — schedule a one-shot
//     "didn't start after you logged in" `DidNotStartPolicy.fireDelay` ahead. Every
//     launch removes it (pending + delivered). A cancelled logout keeps us alive: the
//     heartbeat pushes it back, then removes it after `cancelledLogoutWindow`.
//
// If notifications aren't authorized, `add` just fails — nothing else can surface a
// dead process, so this is reported in diagnostics (see `authorizationDescription`).
// Local notifications only: static copy, no PII, nothing leaves the device.
@MainActor
final class LifecycleNotifier {
    nonisolated static let notRunningID = "nd.notRunning"
    nonisolated static let pausedReminderID = "nd.pausedReminder"
    nonisolated static let didNotStartID = "nd.didNotStart"

    private var heartbeatTimer: Timer?
    private var pausedReminderTimer: Timer?
    /// False after a menu Quit so a late heartbeat can't overwrite the "was quit"
    /// reminder. (Power-off does NOT clear it: a cancelled logout must re-arm.)
    private var heartbeatEnabled = false
    private var observers: [NSObjectProtocol] = []
    /// ND-112: when `nd.didNotStart` was scheduled at power-off; nil when none is
    /// pending. Drives the cancelled-logout push-back / removal on each heartbeat.
    private var didNotStartScheduledAt: Date?

    /// Launch: clear any stale delivered alerts from a previous run, arm the dead-man,
    /// and start the heartbeat. Call once from applicationDidFinishLaunching.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notRunningID, Self.pausedReminderID, Self.didNotStartID])
        // ND-112: we DID start — drop any "didn't start after you logged in" from the
        // previous session's logout, whether still pending or already shown.
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedReminderID, Self.didNotStartID])

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
        clearDidNotStart()   // the "was quit" reminder below covers this case

        var done = false
        let finish: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            completion()
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "No Donuts was quit")
        content.body = String(localized: "Your Mac isn\u{2019}t protected \u{2014} it won\u{2019}t lock when you walk away. Open No Donuts to turn protection back on.")
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
        content.title = String(localized: "No Donuts isn\u{2019}t running")
        content.body = String(localized: "Your Mac isn\u{2019}t protected \u{2014} it won\u{2019}t lock when you walk away. Open No Donuts to turn protection back on.")
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
            MainActor.assumeIsolated {
                self?.scheduleDeadMan()
                self?.heartbeatDidNotStart()
            }
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
        // ND-112: sleeping means the power-off didn't happen (cancelled logout); with
        // the heartbeat stopped a pending "didn't start" would fire during sleep.
        clearDidNotStart()
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
    ///
    /// ND-112: if no launcher will start us after the next login ("Start at login"
    /// not `.enabled`), schedule `nd.didNotStart` instead of going silent.
    private func systemWillPowerOff() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notRunningID])
        guard DidNotStartPolicy.shouldSchedule(loginItemEnabled: LoginItem.isEnabled()) else {
            clearDidNotStart()
            return
        }
        didNotStartScheduledAt = Date()
        // The process may be torn down right after this callback; wait briefly (on
        // main, bounded) for the add to reach the notification daemon. The completion
        // handler runs on a background queue, so this can't deadlock — and the timeout
        // caps the delay if it doesn't.
        let registered = DispatchSemaphore(value: 0)
        scheduleDidNotStart { registered.signal() }
        _ = registered.wait(timeout: .now() + 1.0)
    }

    // MARK: - Didn't start after login (ND-112)

    private func scheduleDidNotStart(completion: (@Sendable () -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "No Donuts didn\u{2019}t start")
        content.body = String(localized: "No Donuts didn\u{2019}t start after you logged in \u{2014} your Mac isn\u{2019}t protected. Open No Donuts, or turn on Start at login in Settings.")
        content.sound = .default
        // Same id → replaces any pending one (pushes the fire date back).
        let request = UNNotificationRequest(
            identifier: Self.didNotStartID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: DidNotStartPolicy.fireDelay, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { _ in completion?() }
    }

    /// Heartbeat while a power-off-scheduled `nd.didNotStart` is pending: we're still
    /// alive, so either the logout is still in progress (push it back so it can't fire
    /// over a live app) or it was cancelled (remove it).
    private func heartbeatDidNotStart() {
        guard let scheduledAt = didNotStartScheduledAt else { return }
        switch DidNotStartPolicy.heartbeatAction(secondsSincePowerOff: Date().timeIntervalSince(scheduledAt)) {
        case .pushBack: scheduleDidNotStart()
        case .remove: clearDidNotStart()
        }
    }

    private func clearDidNotStart() {
        guard didNotStartScheduledAt != nil else { return }
        didNotStartScheduledAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.didNotStartID])
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
        let known = [notRunningID, pausedReminderID, didNotStartID]
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
        content.title = String(localized: "No Donuts is paused")
        content.body = String(localized: "Your Mac won\u{2019}t lock when you walk away. Resume from the menu bar.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.pausedReminderID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Notification permission (ND-113)

    /// Current notification authorization, mapped to Core's enum (menu warning).
    static func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Diagnostics

    /// Coarse notification-permission label for Copy Diagnostics. English on purpose
    /// (ND-101): diagnostics is a support artifact, not user-facing UI. Calls out that the
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
