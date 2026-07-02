import Foundation
import UserNotifications
import NoDonutsCore

// Owner: krusty — honest "we're not protecting you" surfacing (ND-045, EC-07/08/09).
//
// Trust rule: this is a camera app; when it CAN'T see the camera it must not look
// like it's protecting the Mac. The menu-bar glyph already goes ⚪️ honest, but the
// user isn't always looking at it — so on entering `.cameraUnavailable` we post a
// local notification and re-post it periodically while the condition persists, then
// clear it on recovery. Local notifications only: no push, no server, no PII in the
// static copy (privacy note in SECURITY_PRIVACY).

/// Watches `PresenceState` transitions and notifies the user when the app stops
/// protecting because the camera is unavailable. Fires only on transitions (tracks
/// `lastState`) so a steady state doesn't re-alert every tick — the repeat cadence
/// is owned by an internal timer instead.
@MainActor
final class NotProtectingNotifier {
    /// Stable identifier so re-posts REPLACE the existing notification rather than
    /// stacking a new one each interval.
    private static let notificationID = "nd.notProtecting"
    /// How often to re-surface the alert while the camera stays unavailable.
    private static let repeatInterval: TimeInterval = 300

    /// Last state we saw, so `update` acts only on genuine transitions.
    private var lastState: PresenceState = .unknown
    /// Repeating re-post timer, live only while unavailable. Invalidated on recovery.
    private var repeatTimer: Timer?

    /// Request notification authorization if it hasn't been granted/denied yet.
    /// Idempotent: `requestAuthorization` no-ops after the user's first choice, so
    /// this is safe to call on every active transition. Non-blocking; result ignored
    /// (the menu-bar glyph remains the always-honest fallback if the user declines).
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Feed the current presence state each tick. Posts + starts the repeat timer on
    /// the transition INTO `.cameraUnavailable`; clears the timer + delivered
    /// notifications on the transition OUT of it. Does nothing on steady states.
    func update(state: PresenceState) {
        defer { lastState = state }

        let wasUnavailable = lastState == .cameraUnavailable
        let isUnavailable = state == .cameraUnavailable

        if !wasUnavailable && isUnavailable {
            // Entered "not protecting": alert now and keep re-alerting while it lasts.
            postNotification()
            startRepeatTimer()
        } else if wasUnavailable && !isUnavailable {
            // Recovered: stop re-alerting and take down our alert. Scope removal to our
            // OWN identifier (never removeAll — don't wipe unrelated app notifications),
            // and clear BOTH the delivered alert AND any pending request so a just-
            // scheduled 1s-trigger post can't surface ~1s after the camera is back.
            stopRepeatTimer()
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        }
    }

    // MARK: - Internals

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "No Donuts isn\u{2019}t protecting you"
        content.body = "It can\u{2019}t access the camera, so it can\u{2019}t tell if you\u{2019}re here. Check camera permission or that no other app is using the camera."
        content.sound = .default

        // Fixed identifier → each re-post replaces the prior one (no stacking).
        // A short time-interval trigger delivers effectively immediately while
        // remaining a valid (non-nil) trigger.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func startRepeatTimer() {
        stopRepeatTimer()   // never stack timers
        // Block-based, [weak self] so the notifier isn't retained by the RunLoop.
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            // Timer fires on the main RunLoop; hop to the main actor to re-post.
            Task { @MainActor in self?.postNotification() }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeatTimer() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
