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

    // ND-073: identity-off alert — fully independent of the camera-unavailable alert
    // above (own id, own timer, own last-seen value).
    /// Stable identifier for the identity-off alert (re-posts replace, never stack).
    private static let identityNotificationID = "nd.identityOff"
    /// How often to re-surface the identity-off alert while it persists.
    private static let identityRepeatInterval: TimeInterval = 300
    /// Current off reason, or nil when identity is not off. `.unknown` never changes it.
    private var identityOffReason: IdentityOffReason?
    /// Repeating identity-off re-post timer, live only while identity is off.
    private var identityRepeatTimer: Timer?

    // ND-058/ND-074: lock-unavailable alert — independent of the camera and identity
    // alerts above (own id, own timer, own last-seen value).
    /// Stable identifier for the lock-unavailable alert (re-posts replace, never stack).
    private static let lockNotificationID = "nd.lockUnavailable"
    /// How often to re-surface the lock-unavailable alert while it persists.
    private static let lockRepeatInterval: TimeInterval = 300
    /// Last-seen "can lock" value. Starts true so a first `!canLock` counts as entry.
    private var lastCanLock = true
    /// Repeating lock-unavailable re-post timer, live only while we can't lock.
    private var lockRepeatTimer: Timer?

    // ND-054: lock-FAILED alert (a lock attempt was made and didn't take) — distinct
    // from lock-UNAVAILABLE above. Own id; NO repeat timer: the engine's auto-lock
    // retry backoff (10/20/40/60s) drives re-posts via a rising lockFailureCount.
    /// Stable identifier for the lock-failed alert (re-posts replace, never stack).
    private static let lockFailedNotificationID = "nd.lockFailed"
    /// Last-seen failed auto-lock count, to re-post when a retry fails again.
    private var lastLockFailureCount = 0

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
    ///
    /// ND-054: also drives the lock-failed alert — posted on entry into `.lockFailed`,
    /// re-posted (same id, replaces) whenever `lockFailureCount` rises while still in
    /// `.lockFailed` (each failed auto-lock retry), cleared on leaving `.lockFailed`.
    func update(state: PresenceState, lockFailureCount: Int = 0) {
        updateLockFailed(state: state, lockFailureCount: lockFailureCount)
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

    /// Feed the last KNOWN identity status (ND-073). Posts + starts the repeat timer on
    /// entry into `.off`; re-posts (replacing) if the reason changes while off; clears
    /// the timer + delivered AND pending alerts of the identity-off id on exit.
    /// `.unknown` is ignored (a flaky Keychain read must not flap the alert).
    func update(identity: IdentityStatus) {
        if identity == .unknown { return }
        let newReason: IdentityOffReason?
        if case .off(let reason) = identity { newReason = reason } else { newReason = nil }
        guard newReason != identityOffReason else { return }
        let wasOff = identityOffReason != nil
        identityOffReason = newReason

        if newReason != nil {
            postIdentityNotification()
            if !wasOff { startIdentityRepeatTimer() }
        } else {
            stopIdentityRepeatTimer()
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.identityNotificationID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.identityNotificationID])
        }
    }

    /// Feed the lock self-test result (ND-058/ND-074). Posts + starts the repeat timer
    /// on entry into `!canLock`; clears the timer + delivered AND pending alerts of the
    /// lock-unavailable id on recovery. Steady values do nothing.
    func update(lockCapability: LockCapability) {
        let canLock = lockCapability.canLock
        guard canLock != lastCanLock else { return }
        lastCanLock = canLock
        if !canLock {
            postLockNotification()
            startLockRepeatTimer()
        } else {
            stopLockRepeatTimer()
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.lockNotificationID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.lockNotificationID])
        }
    }

    // MARK: - Internals

    /// ND-054 lock-failed path. Must run BEFORE `update(state:)` overwrites `lastState`.
    private func updateLockFailed(state: PresenceState, lockFailureCount: Int) {
        defer { lastLockFailureCount = lockFailureCount }
        let wasFailed = lastState == .lockFailed
        let isFailed = state == .lockFailed
        if isFailed {
            // Entry (incl. a manual lockNow failure with count 0) or another failed
            // auto-lock retry while still failed → (re-)alert.
            if !wasFailed || lockFailureCount > lastLockFailureCount {
                postLockFailedNotification(retrying: lockFailureCount >= 1)
            }
        } else if wasFailed {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [Self.lockFailedNotificationID])
            center.removePendingNotificationRequests(withIdentifiers: [Self.lockFailedNotificationID])
        }
    }

    /// `retrying`: an AUTO lock failed while the user is away and the engine will retry.
    /// false = a manual "Lock now" failed (user present, no retries scheduled).
    private func postLockFailedNotification(retrying: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "No Donuts couldn\u{2019}t lock your Mac"
        content.body = retrying
            ? "You seem to be away, but locking failed. It will keep retrying. Lock manually with Control-Command-Q."
            : "Locking the screen failed. Lock manually with Control-Command-Q."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.lockFailedNotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func postLockNotification() {
        let content = UNMutableNotificationContent()
        content.title = "No Donuts can\u{2019}t lock your Mac"
        content.body = "The macOS screen-lock mechanism No Donuts uses isn\u{2019}t available on this version of macOS, so walking away WON\u{2019}T lock your Mac. Update No Donuts, and lock manually with Control-Command-Q until then."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.lockNotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func startLockRepeatTimer() {
        stopLockRepeatTimer()   // never stack timers
        let timer = Timer(timeInterval: Self.lockRepeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postLockNotification() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockRepeatTimer = timer
    }

    private func stopLockRepeatTimer() {
        lockRepeatTimer?.invalidate()
        lockRepeatTimer = nil
    }

    private func postIdentityNotification() {
        guard let reason = identityOffReason else { return }
        let content = UNMutableNotificationContent()
        content.title = "No Donuts isn\u{2019}t checking that it\u{2019}s you"
        let fix = "To fix it, click the No Donuts icon in the menu bar and choose \u{201C}Re-enroll my face (required)\u{2026}\u{201D}."
        switch reason {
        case .modelMismatch:
            content.body = "The face-recognition model changed, so your saved enrollment no longer applies. Until you re-enroll, ANY face keeps your Mac unlocked. " + fix
        case .enrollmentMissing:
            content.body = "Your saved face enrollment is missing (it was removed from the Keychain). Until you re-enroll, ANY face keeps your Mac unlocked. " + fix
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identityNotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func startIdentityRepeatTimer() {
        stopIdentityRepeatTimer()   // never stack timers
        let timer = Timer(timeInterval: Self.identityRepeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.postIdentityNotification() }
        }
        RunLoop.main.add(timer, forMode: .common)
        identityRepeatTimer = timer
    }

    private func stopIdentityRepeatTimer() {
        identityRepeatTimer?.invalidate()
        identityRepeatTimer = nil
    }

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
