import Foundation
import os.log
import NoDonutsCore

// Owner: krusty (app shell) with gordon (launcher) — ND-082 / ADR-0018 handover.
//
// Problem: only the copy launchd starts for `com.nodonuts.app.agent` has KeepAlive.
// A copy started any other way (manual `open`, scripts/install-app.sh, or "Start at
// login" switched on mid-session) holds the single-instance lock, so the agent's
// RunAtLoad copy exits 0 and launchd treats the job as finished. One kill of the
// unmanaged copy then leaves the Mac unprotected until next login.
//
// Fix: when the agent is `.enabled` and this process is NOT the managed one, hand
// over to it:
//   1. If the job isn't loaded this session (install-app.sh boots it out), ask
//      SMAppService to reload it (`register()` again, never `unregister()`).
//   2. Wait briefly for any RunAtLoad copy to finish exiting on our lock.
//   3. Release the lock, `launchctl kickstart gui/<uid>/<label>`.
//   4. Confirm: launchd reports a pid for the job that isn't ours AND another
//      process now holds the lock. Then exit(0) without the "was quit" reminder
//      (the new copy re-arms nd.notRunning on launch).
//   5. Anything else: take the lock back (`acquireOrExit`, which exits 0 only if
//      another live copy already holds it) and keep running. Logged.
// Never ends with zero instances: we only exit once another process holds the lock.
// Loop guard: the managed copy never hands over (XPC_SERVICE_NAME == label, or
// launchd's pid for the job is ours).
//
// Privacy: runs /bin/launchctl locally; no data, no network.
@MainActor
enum LauncherHandover {
    private static let log = Logger(subsystem: Log.subsystem, category: Log.Category.app)

    /// UserDefaults flag: a mid-session handover (from Settings) asks the new copy to
    /// reopen Settings so the window doesn't just vanish.
    static let reopenSettingsKey = "handoverReopenSettings"

    private static var inProgress = false

    // MARK: - launchctl

    private static var serviceTarget: String { "gui/\(getuid())/\(LoginItem.agentLabel)" }

    /// Run /bin/launchctl with `args`; returns (exit status, stdout). Bounded: the
    /// commands used here return immediately.
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("handover: launchctl \(args.first ?? "", privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// (loaded, pid) for the agent job in this login session.
    static func jobState() -> (loaded: Bool, pid: Int32?) {
        let result = launchctl(["print", serviceTarget])
        guard result.status == 0 else { return (false, nil) }
        return (true, LauncherHandoverPolicy.parsePID(fromLaunchctlPrint: result.output))
    }

    /// Whether this process is the launchd-managed agent copy.
    static func isAgentManaged() -> Bool {
        let env = ProcessInfo.processInfo.environment[LauncherHandoverPolicy.serviceNameEnvKey]
        if env == LoginItem.agentLabel { return true }
        return LauncherHandoverPolicy.isAgentManaged(serviceNameEnv: env,
                                                     label: LoginItem.agentLabel,
                                                     jobPID: jobState().pid,
                                                     ownPID: getpid())
    }

    // MARK: - Handover

    /// Hand over to the agent if it's enabled and we aren't it. Returns only when we
    /// keep running; on a confirmed handover the process exits 0.
    ///
    /// - Parameters:
    ///   - trigger: for the log ("launch", "enable").
    ///   - reopenSettings: ask the new copy to reopen Settings (mid-session enable).
    static func handOverIfNeeded(trigger: String, reopenSettings: Bool = false) {
        guard !inProgress else { return }
        inProgress = true
        defer { inProgress = false }

        let enabled = LoginItem.status() == .enabled
        guard enabled else { return }
        let managed = isAgentManaged()
        guard LauncherHandoverPolicy.shouldHandOver(agentEnabled: enabled, isAgentManaged: managed) else {
            log.info("handover(\(trigger, privacy: .public)): this process is the managed agent copy; nothing to do")
            return
        }
        let ownPID = getpid()
        log.notice("handover(\(trigger, privacy: .public)): agent enabled but this copy (pid \(ownPID)) isn't launchd-managed; handing over")

        // 1. Job not loaded this session → ask SMAppService to reload it.
        var state = jobState()
        if !state.loaded {
            LoginItem.reloadEnabledAgent()
            state = waitFor(timeout: 1.0) { let s = jobState(); return s.loaded ? s : nil } ?? jobState()
            guard state.loaded else {
                log.error("handover(\(trigger, privacy: .public)): agent job not loaded in this session and reload failed; keeping this unmanaged copy running")
                return
            }
        }

        // 2. A RunAtLoad copy may be starting and about to exit 0 on our lock. Let it
        // go first, so the pid we confirm below belongs to a copy that will stay.
        if let pid = state.pid, pid != ownPID {
            _ = waitFor(timeout: 2.0) { jobState().pid == nil ? true : nil }
        }

        // 3. Release the lock and start the managed copy.
        SingleInstance.release()
        let kick = launchctl(["kickstart", serviceTarget])
        if kick.status != 0 {
            log.error("handover(\(trigger, privacy: .public)): launchctl kickstart failed (status \(kick.status)); keeping this copy running")
            SingleInstance.acquireOrExit()
            return
        }

        // 4. Confirm: a live pid that isn't ours AND the lock is held by another process.
        let confirmed = waitFor(timeout: 2.0) { () -> Bool? in
            let pid = jobState().pid
            guard LauncherHandoverPolicy.handoverConfirmed(jobPID: pid, ownPID: ownPID),
                  SingleInstance.isHeldByAnotherProcess() else { return nil }
            return true
        } ?? false

        guard confirmed else {
            // 5. Take the lock back. If the new copy grabbed it late, this exits 0 —
            // a live copy exists, which is what we wanted.
            log.error("handover(\(trigger, privacy: .public)): couldn't confirm the agent copy took over; keeping this copy running")
            SingleInstance.acquireOrExit()
            return
        }

        if reopenSettings {
            UserDefaults.standard.set(true, forKey: reopenSettingsKey)
            UserDefaults.standard.synchronize()
        }
        log.notice("handover(\(trigger, privacy: .public)): agent copy is running; exiting this unmanaged copy (pid \(ownPID))")
        // exit 0 without the "was quit" reminder: the new copy re-arms nd.notRunning.
        exit(0)
    }

    /// Poll `probe` every 100 ms until it returns non-nil or `timeout` passes.
    private static func waitFor<T>(timeout: TimeInterval, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = probe() { return value }
            usleep(100_000)
        } while Date() < deadline
        return probe()
    }
}
