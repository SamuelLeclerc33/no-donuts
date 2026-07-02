import Foundation
// @preconcurrency: UNUserNotificationCenter is a thread-safe Apple type not yet
// marked Sendable; its callbacks fire off the main actor. This treats the
// module's Sendable-capture diagnostics as the non-issues they are here (we only
// pass Sendable locals into the completion closures — see post(now:)).
@preconcurrency import UserNotifications
import os
import NoDonutsCore

// Owner: krusty — menu-bar UI, status, notifications.
// Backlog: ND-045 (as part of the ND-054 fix). Edge cases: EC-07, EC-08, EC-09.
//
// The honest "we can't see you" signal. When the presence engine's DISPLAY state
// is `.cameraUnavailable` (camera denied / restricted / no device / removed), No
// Donuts is NOT protecting the user — the menu-bar glyph says so, but the menu is
// only visible when opened. This posts a local user notification so the user is
// told, out-of-band, that they're unprotected; it withdraws + resets when the
// camera recovers.
//
// Lives in the **App target** on purpose: like SessionStateMonitor this is OS glue
// (UserNotifications) that must not leak into the AppKit-free, testable
// NoDonutsCore (ADR-0007). It observes the SAME PresenceState the menu bar renders
// — there is no second source of truth. The AppDelegate calls `update(state:)`
// from the one render/refresh path.
//
// FAIL-SAFE SILENT (hard requirement): if notification authorization is not
// granted, this no-ops. It NEVER requests authorization (that's gordon's
// launch-time job) and never crashes/throws. The app behaves identically when
// notifications are denied.
//
// PRIVACY (hard requirement): the notification carries ONLY a fixed status string
// — no image, no identity, no dynamic user data, no network. See the constants.
@MainActor
public final class CameraStatusNotifier {
    /// Stable identifier so a re-post REPLACES the existing notification rather than
    /// stacking a new one each throttle interval, and so withdraw targets exactly it.
    private static let notificationID = "com.nodonuts.camera-unavailable"

    /// Fixed, privacy-safe copy. No dynamic data ever interpolated in.
    private static let title = "No Donuts"
    private static let body = "Not protecting you — camera unavailable. Grant camera access or reconnect a camera."

    /// While the state PERSISTS at `.cameraUnavailable`, re-post at most this often so
    /// the user is periodically reminded without being spammed. The first post on entry
    /// is immediate (not throttled).
    private let repeatInterval: TimeInterval = 5 * 60

    private let log = Logger(subsystem: "com.nodonuts.app", category: "notify")
    /// The notification center. Injected for testability; defaults to the current one.
    private let center: UNUserNotificationCenter

    /// True while we consider the camera unavailable — used to detect transitions.
    private var isUnavailable = false
    /// When we last posted (nil = not yet posted this episode). Drives the throttle.
    private var lastPostedAt: Date?

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Feed the engine's current display state. Called from the SAME place the menu
    /// bar is told the state (the AppDelegate render/refresh path). Idempotent and
    /// cheap on the steady state; only acts on transitions and throttled re-posts.
    /// `now` is injectable for tests; defaults to the wall clock.
    public func update(state: PresenceState, now: Date = Date()) {
        let unavailable = (state == .cameraUnavailable)

        if unavailable {
            if !isUnavailable {
                // Transition INTO cameraUnavailable → notify immediately.
                isUnavailable = true
                post(now: now)
            } else if let last = lastPostedAt, now.timeIntervalSince(last) >= repeatInterval {
                // Still unavailable and the throttle window has elapsed → re-post.
                // Same identifier, so this replaces rather than stacks.
                post(now: now)
            }
        } else if isUnavailable {
            // Transition OUT of cameraUnavailable → withdraw + reset so the NEXT
            // episode notifies immediately again.
            isUnavailable = false
            lastPostedAt = nil
            center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        }
    }

    /// Post (or replace) the notification, but only if authorization is granted.
    /// FAIL-SAFE SILENT: we check status first and no-op otherwise; we NEVER request
    /// authorization here. The throttle clock advances on the ATTEMPT so an
    /// unauthorized state doesn't hammer getNotificationSettings every tick.
    private func post(now: Date) {
        lastPostedAt = now
        // Hoist all main-actor-isolated statics into Sendable locals BEFORE entering
        // the non-isolated getNotificationSettings/add completion closures, so the
        // closures capture only Sendable values (no main-actor hop, no warning).
        let id = Self.notificationID
        let title = Self.title
        let body = Self.body
        let center = self.center
        let log = self.log
        center.getNotificationSettings { settings in
            // Only post when the user has authorized (or provisionally authorized)
            // notifications. Anything else (denied / not-determined) → silent no-op.
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // No trigger → deliver immediately. Same identifier replaces in place.
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    log.error("camera-unavailable notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
