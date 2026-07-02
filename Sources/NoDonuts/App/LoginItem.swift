import Foundation
import ServiceManagement
import os.log
import NoDonutsCore

// Owner: gordon — the app-side "Start at login" toggle for Settings (ND-040).
//
// This uses SMAppService.mainApp: the modern (macOS 13+) login-item API. It's
// live (toggles take effect without relaunch), needs no sudo/admin, and shows up
// under System Settings › General › Login Items as a user-controllable item.
//
// Relationship to the ND-016 LaunchAgent: BOTH achieve "launch No Donuts at
// login". The LaunchAgent (scripts/com.nodonuts.agent.plist) is the
// install-script path (RunAtLoad + KeepAlive crash recovery), suited to
// MDM/enterprise deployment. THIS toggle is the in-app, user-facing switch. They
// are complementary; for a plain user install, the Settings toggle is the
// friendlier control. If both a LaunchAgent and this registration are active,
// launchd/SMAppService coalesce to a single running instance at login (the app is
// a singleton menu-bar accessory), so there's no double-launch concern in
// practice — but installers should prefer one mechanism.
//
// Privacy: registers only the app itself as a login item. No data, no network.

/// The Settings "Start at login" control, backed by `SMAppService.mainApp`.
@MainActor
enum LoginItem {
    private static let log = Logger(subsystem: Log.subsystem, category: Log.Category.app)

    /// Whether the app is currently registered to launch at login.
    ///
    /// Returns true only for `.enabled`. Every other status — `.notRegistered`,
    /// `.requiresApproval` (the user must approve it in System Settings), or
    /// `.notFound` — reads as "not enabled" so the Settings toggle reflects the
    /// honest, effective state rather than an optimistic one.
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The raw status, exposed so the UI can (optionally) distinguish
    /// "needs approval in System Settings" from a plain off state.
    static func status() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Enable or disable launch-at-login. Throwing so the caller can surface a
    /// failure (e.g. approval required, or an unsigned/ad-hoc build the OS won't
    /// register). Idempotent-ish: registering when already enabled or
    /// unregistering when already off is a no-op that SMAppService tolerates.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            log.info("registered app as a login item")
        } else {
            try SMAppService.mainApp.unregister()
            log.info("unregistered app login item")
        }
    }
}
