# ADR-0018 — Single launcher: bundled KeepAlive agent via SMAppService; dead-man notification

- Status: Accepted (supersedes the launcher part of [ADR-0013](0013-settings-ui-and-login-item.md) and the ND-016 install-script LaunchAgent)
- Date: 2026-09-28
- Owner: gordon (with krusty)

## Context

Two launchers coexisted: the script-installed LaunchAgent `com.nodonuts.agent` (ND-016, KeepAlive) and the Settings "Start at login" toggle, which used `SMAppService.mainApp` with no KeepAlive. Together they caused duplicate instances (ND-083, now guarded). Meanwhile the login-item path had no crash or kill recovery: one `kill` left the Mac unprotected until next login, and nothing told the user (ND-082). Colleagues (ND-111) shouldn't need to run an install script.

## Decision

- **One launcher:** a LaunchAgent plist **bundled in the app** (`Contents/Library/LaunchAgents/com.nodonuts.app.agent.plist`, `BundleProgram`, `RunAtLoad`, `KeepAlive { SuccessfulExit = false }`, `ThrottleInterval 10`), registered through `SMAppService.agent(plistName:)` from Settings › Start at login. A kill or crash relaunches within seconds. A clean Quit (exit 0) stays quit. It uses a new label so it can't collide with the legacy agent.
- **Migration:**
  - The app unregisters a legacy `SMAppService.mainApp` item once, and re-registers the agent if the item was on.
  - `scripts/migrate-launcher.sh` boots out and removes the legacy `com.nodonuts.agent`.
  - `install-launchagent.sh` is deprecated in favour of `install-app.sh`.
- **Dead-man notification:** while running, the app keeps one local notification (`nd.notRunning`) scheduled ~10 min ahead, refreshed every 60 s. If the process dies by any route, macOS still delivers "No Donuts isn't running". It is cancelled on sleep and re-armed on wake, and cancelled on logout/shutdown.
- **Confirmed Quit:** "Stop protecting this Mac?" A confirmed Quit reschedules the notification with "was quit" copy for +30 min.

## Consequences

- A killed or crashed app comes back on its own, and the user is told when it can't.
- **Handover:** a copy not started by launchd (manual `open`, `install-app.sh`, or enabling mid-session) hands over to the agent when it is enabled. It releases the single-instance lock, runs `launchctl kickstart`, and exits only once launchd reports a new pid holding the lock. On any failure it re-acquires the lock and keeps running, so it never ends with zero instances. The agent-managed copy never hands over (no loops).
- **Turning Start at login off** from the agent-managed copy would stop the running job, so Settings confirms first ("No Donuts will quit now…") and goes through the confirmed-Quit path.
- SMAppService may need **user approval** (Login Items). With dev signing, approval may be asked again after rebuilds.
- `NoDonuts --unregister` (handled before the single-instance guard, no UI) unregisters the agent and the legacy login item and clears pending `nd.*` notifications. `uninstall-launchagent.sh` uses it.
- A cancelled logout no longer disables the dead-man heartbeat.
- Without notification permission the dead-man path can't fire. Diagnostics report it.

## Alternatives considered

- **Keep `mainApp` + a script agent:** two launchers and no KeepAlive on the login-item path. Rejected.
- **Always-relaunch (KeepAlive true):** Quit would be impossible. Rejected in favour of a confirmed Quit plus the dead-man reminder.
