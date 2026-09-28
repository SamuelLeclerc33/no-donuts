import Foundation
import ServiceManagement
import os.log
import NoDonutsCore

// Owner: gordon — the app's single launcher, behind Settings › "Start at login"
// (ND-040, ND-082, ND-083).
//
// Backed by SMAppService.agent(plistName:): a LaunchAgent plist BUNDLED inside the
// app at Contents/Library/LaunchAgents/com.nodonuts.app.agent.plist (source:
// Resources/LaunchAgents/, copied in by scripts/make-app.sh). Registering it makes
// launchd start the app at login (RunAtLoad) AND relaunch it after a crash or kill
// (KeepAlive { SuccessfulExit = false }); the menu Quit exits 0 and stays quit.
// That KeepAlive is the reason we moved off SMAppService.mainApp, which has none —
// a single `kill` used to leave the Mac unprotected until next login (ND-082).
//
// One launcher only (ND-083). Two older mechanisms may still be present on a Mac:
//  - SMAppService.mainApp (the previous version of this toggle). Migrated here: if
//    it is registered, we unregister it and, if it was enabled, register the agent
//    instead so the user's "start at login" choice is preserved.
//  - The ND-016 script-installed ~/Library/LaunchAgents/com.nodonuts.agent.plist.
//    The app does not touch it (it's outside the bundle and owned by the user's
//    shell scripts); scripts/migrate-launcher.sh removes it. The bundled agent uses
//    a different Label (com.nodonuts.app.agent) so the two can't collide in launchd.
// If a duplicate copy still starts, SingleInstance.swift makes it exit 0 (which
// KeepAlive does not respawn).
//
// Privacy: registers only the app's own bundled agent. No data, no network.

/// The Settings "Start at login" control, backed by the bundled LaunchAgent.
@MainActor
enum LoginItem {
    private static let log = Logger(subsystem: Log.subsystem, category: Log.Category.app)

    /// File name under `Contents/Library/LaunchAgents/`. Must match make-app.sh.
    static let agentPlistName = "com.nodonuts.app.agent.plist"
    /// The launchd Label inside that plist (`gui/<uid>/com.nodonuts.app.agent`).
    static let agentLabel = "com.nodonuts.app.agent"

    private static var agent: SMAppService { SMAppService.agent(plistName: agentPlistName) }

    /// Set once the legacy-login-item migration has run in this process.
    private static var didMigrate = false

    /// Whether the app is currently registered to launch at login.
    ///
    /// Returns true only for `.enabled`. Every other status (`.notRegistered`,
    /// `.requiresApproval`, which means the user must approve it in System Settings,
    /// or `.notFound`) reads as "not enabled", so the Settings toggle shows the
    /// actual state, not an optimistic one.
    static func isEnabled() -> Bool {
        migrateLegacyLoginItemIfNeeded()
        return agent.status == .enabled
    }

    /// The raw status, so the UI can tell "needs approval in System Settings"
    /// apart from a plain off state.
    static func status() -> SMAppService.Status {
        migrateLegacyLoginItemIfNeeded()
        return agent.status
    }

    /// Enable or disable launch-at-login.
    ///
    /// Enabling when macOS wants the user's approval does NOT throw: the agent is
    /// registered but parked in `.requiresApproval`, so we open System Settings ›
    /// General › Login Items for the user and return normally. The caller then
    /// reads `status()` and shows the "needs approval" hint. Throws for real
    /// failures (e.g. the plist is missing from the bundle, so `.notFound`, or
    /// the OS rejects the registration).
    static func setEnabled(_ enabled: Bool) throws {
        migrateLegacyLoginItemIfNeeded()
        let service = agent
        if enabled {
            do {
                try service.register()
                log.info("registered bundled launch agent \(agentLabel, privacy: .public)")
            } catch {
                guard service.status == .requiresApproval else {
                    log.error("launch agent register failed: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
                log.info("launch agent register error while approval pending: \(error.localizedDescription, privacy: .public)")
            }
            if service.status == .requiresApproval {
                log.info("launch agent requires approval; opening System Settings › Login Items")
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            // unregister() on a never-registered service reports an error; treat
            // "already off" as success.
            guard service.status != .notRegistered else { return }
            try service.unregister()
            log.info("unregistered bundled launch agent \(agentLabel, privacy: .public)")
        }
    }

    /// Ask SMAppService to (re)load an already-approved agent (ND-082 handover).
    ///
    /// Used when the registration is `.enabled` but the job isn't loaded in this
    /// login session (install-app.sh boots it out before replacing the bundle).
    /// `register()` on a registered service is expected to be idempotent and to
    /// bootstrap the job again; it never unregisters, so the worst case is an error
    /// and an unchanged status. Returns true if the call didn't throw.
    @discardableResult
    static func reloadEnabledAgent() -> Bool {
        let service = agent
        guard service.status == .enabled else { return false }
        do {
            try service.register()
            log.info("re-registered enabled launch agent \(agentLabel, privacy: .public) to reload it")
            return true
        } catch {
            log.error("re-register of enabled launch agent failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `NoDonuts --unregister` (ND-052 uninstall): remove BOTH registrations, the
    /// bundled agent and the legacy `SMAppService.mainApp` item. Deliberately skips
    /// the migration (which could register the agent). Errors are logged and
    /// returned as text lines for the CLI to print; never throws.
    static func unregisterAllForUninstall() -> [String] {
        var lines: [String] = []
        let services: [(String, SMAppService)] = [("launch agent \(agentLabel)", agent),
                                                  ("legacy login item (mainApp)", SMAppService.mainApp)]
        for (name, service) in services {
            let before = service.status
            guard before != .notRegistered else {
                lines.append("\(name): not registered")
                continue
            }
            do {
                try service.unregister()
                log.info("uninstall: unregistered \(name, privacy: .public)")
                lines.append("\(name): unregistered")
            } catch {
                log.error("uninstall: unregister \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lines.append("\(name): unregister failed (\(error.localizedDescription)); status \(service.status.rawValue)")
            }
        }
        return lines
    }

    /// One-time migration off the legacy `SMAppService.mainApp` login item (ND-083).
    ///
    /// Runs at most once per process and is idempotent across launches: after the
    /// first successful run `mainApp.status` is `.notRegistered` and this is a no-op.
    /// If the legacy item was `.enabled`, the agent is registered in its place so
    /// "start at login" stays on. Never throws; failures are logged and the next
    /// launch retries.
    ///
    /// Called lazily by every `LoginItem` entry point. The app shell should also
    /// call it once at launch, so the migration doesn't wait for Settings to open.
    static func migrateLegacyLoginItemIfNeeded() {
        guard !didMigrate else { return }
        didMigrate = true

        let legacy = SMAppService.mainApp
        let legacyStatus = legacy.status
        guard legacyStatus == .enabled || legacyStatus == .requiresApproval else { return }

        // Security review: register the agent FIRST and only drop the legacy item once
        // the agent is actually in place (.enabled / .requiresApproval). If registration
        // fails we KEEP mainApp — two launchers are harmless (SingleInstance exits the
        // duplicate), but no launcher silently disables protection after the next login.
        if legacyStatus == .enabled, agent.status == .notRegistered {
            do {
                try agent.register()
                log.info("migration: registered bundled launch agent \(agentLabel, privacy: .public) in place of mainApp")
            } catch {
                log.error("migration: agent register failed (status \(agent.status.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
        let agentStatus = agent.status
        guard agentStatus == .enabled || agentStatus == .requiresApproval
                || legacyStatus == .requiresApproval else {
            // Agent not in place → keep the legacy login item; retried next launch
            // (the guard above still sees mainApp registered).
            log.notice("migration: agent not registered (status \(agentStatus.rawValue, privacy: .public)); keeping legacy mainApp login item")
            return
        }
        if agentStatus == .requiresApproval {
            // Tell the user once instead of only logging: approval is needed for the
            // new launcher to run at login.
            log.notice("migration: agent requires approval; opening Login Items")
            SMAppService.openSystemSettingsLoginItems()
        }
        do {
            try legacy.unregister()
            log.info("migration: unregistered legacy SMAppService.mainApp login item (status was \(legacyStatus.rawValue, privacy: .public))")
        } catch {
            log.error("migration: failed to unregister legacy mainApp login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
