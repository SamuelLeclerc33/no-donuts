import Foundation
import UserNotifications
import NoDonutsCore

// Owner: krusty — ND-119 enrollment drift warning (EC-04/EC-05 appearance change).
//
// Advisory only: recognition still works, but only barely (or the real user keeps
// getting stranger-locked right after unlocking). One local notification suggests a
// re-enroll; tapping it starts enrollment. Rate limit (4 h) comes from Core's
// `EnrollmentDriftMonitor.shouldNotify`; the AppDelegate decides WHEN to post.
//
// Privacy: STATIC copy. No score, margin or count ever goes into the notification
// (it can show on the lock screen / in Notification Center). Local only.
//
// ND-113: if notifications are denied, `add` just fails; the persistent menu item
// ("Recognition weak — re-enroll…") is the always-visible fallback.
@MainActor
final class EnrollmentDriftNotifier {
    /// Stable identifier so a re-post REPLACES the previous alert (never stacks).
    nonisolated static let notificationID = "nd.enrollmentDrift"

    /// Post (or replace) the drift notification.
    func post() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Recognition is weaker than usual")
        content.body = String(localized: "Your face is matching less reliably (a new look, glasses or lighting?). Re-enroll to avoid unexpected locks.")
        content.sound = .default
        // Same 1 s trigger idiom as the other nd.* alerts (valid non-nil trigger).
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationID,
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Take the alert down (pending AND delivered): re-enrolled, or identity no longer
    /// active so the advice no longer applies.
    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}

/// ND-119: routes notification taps. Only `nd.enrollmentDrift` has an action (start
/// enrollment); every other nd.* alert keeps its old behavior (tap just dismisses).
///
/// Installing a delegate also means we answer `willPresent`: alerts are shown as
/// banners even while one of our windows is frontmost (before, macOS suppressed them
/// then — the wrong call for "not protecting" / "couldn't lock" alarms).
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Called on the main actor when the drift notification is tapped.
    private let onEnrollmentDriftTapped: @MainActor () -> Void

    init(onEnrollmentDriftTapped: @escaping @MainActor () -> Void) {
        self.onEnrollmentDriftTapped = onEnrollmentDriftTapped
        super.init()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.identifier == EnrollmentDriftNotifier.notificationID
        else { return }
        let action = onEnrollmentDriftTapped
        await MainActor.run { action() }
    }
}
