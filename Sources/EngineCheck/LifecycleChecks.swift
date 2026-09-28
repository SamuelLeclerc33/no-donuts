import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// ND-080 / ND-082 pause + liveness policy.
@MainActor
func runPauseLivenessPolicyChecks(_ c: Checks) async {
    print("\nND-080 / ND-082 — pause + liveness policy")
    do {
        c.expect(PausePolicy.endsOnSessionSuspend(.indefinite),
                 "ND-080: an indefinite pause ENDS when the session suspends (user returns protected)")
        c.expect(!PausePolicy.endsOnSessionSuspend(.timed),
                 "ND-080: a timed pause survives a session suspend (bounded; expires on its own)")
        c.expect(PausePolicy.remindsWhilePaused(.indefinite) && !PausePolicy.remindsWhilePaused(.timed),
                 "ND-080: only indefinite pauses get the periodic reminder")
        c.expect(PausePolicy.pausedReminderInterval == 30 * 60,
                 "ND-080: paused reminder every 30 min")
        c.expect(DeadManPolicy.heartbeatKeepsAhead(),
                 "ND-082: shipped heartbeat (60 s) re-arms the dead-man (10 min) with >= 3 beats of slack")
        c.expect(!DeadManPolicy.heartbeatKeepsAhead(heartbeat: 300, fireDelay: 600)
                 && !DeadManPolicy.heartbeatKeepsAhead(heartbeat: 0, fireDelay: 600),
                 "ND-082: a heartbeat too slow (or zero) for the fire delay is rejected")
        c.expect(DeadManPolicy.quitReminderDelay == 30 * 60 && DeadManPolicy.fireDelay == 10 * 60,
                 "ND-082: not-running fires <= 10 min after death; after a menu Quit, +30 min")
    }
}

/// ND-112 / ND-113 didn't-start reminder + notifications-off warning.
@MainActor
func runStartupReminderChecks(_ c: Checks) async {
    print("\nND-112 / ND-113 — didn't-start reminder + notifications-off warning")
    do {
        typealias D = DidNotStartPolicy
        c.expect(D.shouldSchedule(loginItemEnabled: false),
                 "ND-112: Start at login off → schedule nd.didNotStart at power-off")
        c.expect(!D.shouldSchedule(loginItemEnabled: true),
                 "ND-112: Start at login on → no reminder (avoids an overdue false alarm at login)")
        c.expect(D.fireDelay == 5 * 60, "ND-112: reminder fires ~5 min after logout")
        c.expect(D.fireDelay > DeadManPolicy.heartbeatInterval * 3,
                 "ND-112: a live heartbeat pushes it back with >= 3 beats of slack")
        c.expect(D.heartbeatAction(secondsSincePowerOff: 0) == .pushBack
                 && D.heartbeatAction(secondsSincePowerOff: 60) == .pushBack,
                 "ND-112: alive shortly after power-off (logout in progress) → push back")
        c.expect(D.heartbeatAction(secondsSincePowerOff: D.cancelledLogoutWindow) == .remove
                 && D.heartbeatAction(secondsSincePowerOff: 3600) == .remove,
                 "ND-112: still alive past the window → logout was cancelled → remove")
        c.expect(D.heartbeatAction(secondsSincePowerOff: -30) == .pushBack,
                 "ND-112: a clock step backwards counts as 'just powered off'")
        c.expect(NotificationAuthorization.denied.showsNotificationsOffWarning,
                 "ND-113: denied → persistent 'Notifications off' menu warning")
        let quiet: [NotificationAuthorization] = [.notDetermined, .authorized, .provisional, .ephemeral]
        c.expect(quiet.allSatisfy { !$0.showsNotificationsOffWarning },
                 "ND-113: not determined (onboarding asks) / authorized / provisional / ephemeral → no warning")
    }
}

/// ND-082 launcher handover (ADR-0018).
@MainActor
func runLauncherHandoverChecks(_ c: Checks) async {
    print("\nND-082 — launcher handover (ADR-0018)")
    do {
        typealias H = LauncherHandoverPolicy
        let running = """
        gui/503/com.nodonuts.app.agent = {
        	active count = 1
        	path = /Applications/NoDonuts.app/Contents/Library/LaunchAgents/com.nodonuts.app.agent.plist
        	type = LaunchAgent
        	state = running

        	program identifier = Contents/MacOS/NoDonuts (mode: 2)
        	pid = 28408
        	immediate reason = inefficient
        	last exit code = 0
        }
        """
        c.expect(H.parsePID(fromLaunchctlPrint: running) == 28408,
                 "ND-082: parses `pid = N` from launchctl print of a running job")
        let loadedNotRunning = """
        gui/503/com.nodonuts.app.agent = {
        	active count = 0
        	state = not running
        	last exit code = 0
        }
        """
        c.expect(H.parsePID(fromLaunchctlPrint: loadedNotRunning) == nil,
                 "ND-082: a loaded-but-not-running job has no pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "Could not find service \"com.nodonuts.app.agent\" in domain for user gui: 503") == nil
                 && H.parsePID(fromLaunchctlPrint: "") == nil,
                 "ND-082: 'not found' / empty output → no pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "\tpid = 0\n") == nil
                 && H.parsePID(fromLaunchctlPrint: "\tpid = abc\n") == nil
                 && H.parsePID(fromLaunchctlPrint: "\tpid = -4\n") == nil,
                 "ND-082: pid 0 / garbage / negative is not a live pid")
        c.expect(H.parsePID(fromLaunchctlPrint: "\tparent pid = 1\n\tpid = 77\n") == 77,
                 "ND-082: `parent pid` lines don't count; the job's own `pid =` does")

        let label = "com.nodonuts.app.agent"
        c.expect(H.isAgentManaged(serviceNameEnv: label, label: label, jobPID: nil, ownPID: 10),
                 "ND-082: XPC_SERVICE_NAME == label → managed (even if launchctl can't be read)")
        c.expect(H.isAgentManaged(serviceNameEnv: "0", label: label, jobPID: 10, ownPID: 10),
                 "ND-082: launchd's job pid == ours → managed")
        c.expect(!H.isAgentManaged(serviceNameEnv: "application.com.nodonuts.app.1.2", label: label, jobPID: nil, ownPID: 10)
                 && !H.isAgentManaged(serviceNameEnv: nil, label: label, jobPID: 11, ownPID: 10)
                 && !H.isAgentManaged(serviceNameEnv: "com.nodonuts.agent", label: label, jobPID: nil, ownPID: 10),
                 "ND-082: `open` / other pid / legacy agent label → NOT managed")

        c.expect(H.shouldHandOver(agentEnabled: true, isAgentManaged: false),
                 "ND-082: enabled agent + unmanaged copy → hand over")
        c.expect(!H.shouldHandOver(agentEnabled: true, isAgentManaged: true),
                 "ND-082: the managed copy never hands over (loop guard)")
        c.expect(!H.shouldHandOver(agentEnabled: false, isAgentManaged: false),
                 "ND-082: agent not enabled (off / needs approval) → keep running")

        c.expect(H.handoverConfirmed(jobPID: 11, ownPID: 10),
                 "ND-082: a live job pid that isn't ours confirms the handover")
        c.expect(!H.handoverConfirmed(jobPID: nil, ownPID: 10)
                 && !H.handoverConfirmed(jobPID: 10, ownPID: 10)
                 && !H.handoverConfirmed(jobPID: 0, ownPID: 10),
                 "ND-082: no pid / our own pid / 0 never confirms (don't exit into nothing)")
    }
}

/// ND-090 + ND-064 session suspend policy + CGSession reader.
@MainActor
func runSessionSuspendChecks(_ c: Checks) async {
    // ND-090 + ND-064: session suspend policy + shared CGSession reader.
    print("\nSession suspend policy + CGSession reader (ND-090, ND-064):")
    do {
        typealias P = SessionSuspendPolicy
        c.expect(!P.shouldSuspend(locked: false, onConsole: true, displayAsleep: true, systemSleeping: false),
                 "ND-090: display asleep but session UNLOCKED → keep running (walk-away still locks)")
        c.expect(!P.shouldSuspend(locked: false, onConsole: true, displayAsleep: false, systemSleeping: false),
                 "ND-090: unlocked, on console, awake → active")
        c.expect(P.shouldSuspend(locked: true, onConsole: true, displayAsleep: false, systemSleeping: false)
                 && P.shouldSuspend(locked: true, onConsole: true, displayAsleep: true, systemSleeping: false),
                 "ND-090: screen locked → suspend (display on or off)")
        c.expect(P.shouldSuspend(locked: false, onConsole: false, displayAsleep: false, systemSleeping: false),
                 "ND-090: off console (FUS / login window) → suspend (EC-14)")
        c.expect(P.shouldSuspend(locked: false, onConsole: true, displayAsleep: true, systemSleeping: true)
                 && P.shouldSuspend(locked: false, onConsole: true, displayAsleep: false, systemSleeping: true),
                 "ND-090: system sleep → suspend (EC-13)")

        // Snapshot convenience: unreadable session → active; off-console only when explicit.
        c.expect(!P.shouldSuspend(session: nil, displayAsleep: true, systemSleeping: false),
                 "ND-064: unreadable CGSession → active (never wedge the loop off)")
        c.expect(!P.shouldSuspend(session: CGSessionState(screenLocked: false, onConsole: nil),
                                  displayAsleep: false, systemSleeping: false),
                 "ND-064: on-console unknown → treated as on console")
        c.expect(P.shouldSuspend(session: CGSessionState(screenLocked: false, onConsole: false),
                                 displayAsleep: false, systemSleeping: false),
                 "ND-064: explicit off-console snapshot → suspend")

        // Parsing: Bool AND NSNumber bridging, absent / junk keys.
        let K = CGSessionState.self
        let boolLocked = K.parse([K.screenLockedKey: true, K.onConsoleKey: true])
        c.expect(boolLocked == CGSessionState(screenLocked: true, onConsole: true) && boolLocked?.isLockedOrOffConsole == true,
                 "ND-064: Bool flags parse (locked, on console) → locked")
        let numOff = K.parse([K.screenLockedKey: NSNumber(value: 0), K.onConsoleKey: NSNumber(value: 0)])
        c.expect(numOff == CGSessionState(screenLocked: false, onConsole: false) && numOff?.isLockedOrOffConsole == true,
                 "ND-064: NSNumber flags bridge (0/0) → off console counts as locked")
        let numUnlocked = K.parse([K.screenLockedKey: NSNumber(value: 0), K.onConsoleKey: NSNumber(value: 1)])
        c.expect(numUnlocked?.isLockedOrOffConsole == false,
                 "ND-064: NSNumber unlocked + on console → NOT locked")
        let empty = K.parse([:])
        c.expect(empty == CGSessionState(screenLocked: false, onConsole: nil) && empty?.isLockedOrOffConsole == false,
                 "ND-064: absent keys → not locked, on-console unknown (absent key never claims locked)")
        let junk = K.parse([K.screenLockedKey: "yes", K.onConsoleKey: "no"])
        c.expect(junk?.screenLocked == false && junk?.onConsole == nil && junk?.isLockedOrOffConsole == false,
                 "ND-064: non-Bool/NSNumber values ignored (no claimed lock, no suspend)")
        c.expect(K.parse(nil) == nil, "ND-064: nil dictionary → nil (caller picks safe default)")
        c.expect(K.flag(true) == true && K.flag(NSNumber(value: 1)) == true && K.flag(NSNumber(value: false)) == false
                 && K.flag(nil) == nil && K.flag("1") == nil,
                 "ND-064: flag() bridges Bool + NSNumber only")

        // Stale willSleep flag (cancelled sleep / missed didWake) — uptime excludes sleep.
        c.expect(!P.sleepFlagIsStale(willSleepUptime: 100, nowUptime: 100 + P.staleSleepFlagAfter - 1),
                 "ND-090: sleep flag fresh shortly after willSleep")
        c.expect(P.sleepFlagIsStale(willSleepUptime: 100, nowUptime: 100 + P.staleSleepFlagAfter),
                 "ND-090: awake ≥30s after willSleep with no didWake → stale, cleared")
    }
}

/// ND-042a fixed-cadence (deadline-based) presence loop scheduling.
@MainActor
func runTickScheduleChecks(_ c: Checks) async {
    print("\nND-042a — TickSchedule (deadline cadence, skip missed deadlines)")
    // Work finished inside the interval: next deadline = previous + interval, so
    // work time does NOT add to the period (old loop: work + sleep).
    var n = TickSchedule.next(after: 100, interval: 1, now: 100.3)
    c.expect(n.deadline == 101 && n.skipped == 0, "tick: 300ms of work → next tick at start + 1s, not +1.3s")
    c.expect(abs(TickSchedule.delay(until: n.deadline, now: 100.3) - 0.7) < 1e-9, "tick: sleep = interval − work (0.7s)")

    // Ten ticks with 300ms of work each stay on the 1s grid (no drift).
    var d: TimeInterval = 0
    for _ in 0..<10 { d = TickSchedule.next(after: d, interval: 1, now: d + 0.3).deadline }
    c.expect(abs(d - 10) < 1e-9, "tick: 10 ticks × (0.3s work) land at exactly 10s — no cumulative drift")

    // Finished exactly on the next deadline → run it now, nothing skipped.
    n = TickSchedule.next(after: 100, interval: 1, now: 101)
    c.expect(n.deadline == 101 && n.skipped == 0, "tick: finishing exactly on the deadline → due now, 0 skipped")

    // Overran 2.5 intervals → skip the missed grid points, never burst.
    n = TickSchedule.next(after: 100, interval: 1, now: 102.5)
    c.expect(n.deadline == 103 && n.skipped == 2, "tick: 2.5s overrun → next at 103 (2 skipped), no back-to-back burst")
    c.expect(TickSchedule.delay(until: n.deadline, now: 102.5) == 0.5, "tick: after an overrun the sleep is to the next grid point")

    // Interval change (Settings) applies from the next deadline.
    n = TickSchedule.next(after: 100, interval: 2, now: 100.4)
    c.expect(n.deadline == 102 && n.skipped == 0, "tick: a new 2s interval applies from the previous deadline")

    // Degenerate inputs never spin.
    n = TickSchedule.next(after: 100, interval: 0, now: 100)
    c.expect(n.deadline >= 100 + TickSchedule.minimumInterval, "tick: 0s interval floored (no spin)")
    n = TickSchedule.next(after: 100, interval: .nan, now: 100)
    c.expect(n.deadline >= 100 + TickSchedule.minimumInterval, "tick: NaN interval floored (no spin)")
    n = TickSchedule.next(after: .nan, interval: 1, now: 50)
    c.expect(n.deadline == 51 && n.skipped == 0, "tick: non-finite previous deadline re-anchors to now + interval")
    c.expect(TickSchedule.delay(until: 10, now: 20) == 0, "tick: a past deadline never gives a negative sleep")

    // Huge gap (e.g. a long stall) still resolves to the next future grid point.
    n = TickSchedule.next(after: 0, interval: 1, now: 86_400.25)
    c.expect(n.deadline == 86_401 && n.skipped == 86_400, "tick: a day-long stall resolves to the next grid point")
}
