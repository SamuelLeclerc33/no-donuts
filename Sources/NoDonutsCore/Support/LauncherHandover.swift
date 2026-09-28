import Foundation

/// ND-082 / ADR-0018: pure decisions for handing a hand-started copy over to the
/// bundled KeepAlive agent (`com.nodonuts.app.agent`), plus the `launchctl print`
/// parsing they depend on. AppKit-free so EngineCheck can cover it; the app shell
/// (`Sources/NoDonuts/App/LauncherHandover.swift`) runs the actual launchctl calls.
///
/// Why hand over: a copy NOT started by launchd (manual `open`, install-app.sh, or
/// "Start at login" switched on mid-session) holds the single-instance lock, so the
/// agent's RunAtLoad copy exits 0 and launchd treats the job as done. The running
/// copy then has no KeepAlive: one kill leaves the Mac unprotected. Handing over
/// makes the launchd-managed copy the one that runs.
public enum LauncherHandoverPolicy {
    /// Environment variable launchd sets to the job Label in processes it spawns.
    /// LaunchServices (`open`) sets it to `application.<bundle id>.<n>.<n>`; a shell
    /// inherits whatever the terminal had (often "0").
    public static let serviceNameEnvKey = "XPC_SERVICE_NAME"

    /// The `pid = N` of the job in `launchctl print gui/<uid>/<label>` output, or nil
    /// when the job is loaded but not running (no pid line) or the text isn't a
    /// service description. Only the first `pid = ` line counts: in current output
    /// it is a top-level key of the service dictionary and appears once.
    public static func parsePID(fromLaunchctlPrint output: String) -> Int32? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pid = ") else { continue }
            let value = line.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(value), pid > 0 else { return nil }
            return pid
        }
        return nil
    }

    /// Whether THIS process is the one launchd runs for the agent job. Either signal
    /// is enough: the launchd-set service name equals the label, or launchd reports
    /// our own pid for the job. A managed process must never hand over (loop guard).
    public static func isAgentManaged(serviceNameEnv: String?,
                                      label: String,
                                      jobPID: Int32?,
                                      ownPID: Int32) -> Bool {
        if serviceNameEnv == label { return true }
        if let jobPID, jobPID == ownPID { return true }
        return false
    }

    /// Hand over only when the agent is registered AND approved (`.enabled`) and we
    /// are not already the managed copy. `.requiresApproval` can't run, so we keep
    /// running rather than exit into nothing.
    public static func shouldHandOver(agentEnabled: Bool, isAgentManaged: Bool) -> Bool {
        agentEnabled && !isAgentManaged
    }

    /// The handover is confirmed only when launchd reports a live pid for the job
    /// that is not ours. Anything else means "keep running".
    public static func handoverConfirmed(jobPID: Int32?, ownPID: Int32) -> Bool {
        guard let jobPID, jobPID > 0 else { return false }
        return jobPID != ownPID
    }
}
