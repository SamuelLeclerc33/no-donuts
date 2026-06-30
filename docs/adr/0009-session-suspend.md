# ADR-0009 — Suspend the presence loop + camera while locked/asleep/inactive

- Status: Accepted
- Date: 2026-06-30
- Owner: homer / blart

## Context

While the Mac is already locked, the display is asleep, or this session has been
fast-user-switched away from the console, there is no point running the presence
loop: there is nobody to verify, the camera may be reassigned to the login
window, and keeping an `AVCaptureSession` running needlessly burns power and the
green camera light. Polling for these states on every tick would be wasteful and
laggy; the OS already publishes precise notifications for them.

There is also a correctness hazard: if the user is *mid-absence* (a few absent
ticks accumulated, grace partway elapsed) when the screen locks or the lid
closes, naively resuming on unlock/wake could fire a lock with little or no
grace — a false lock the instant the user sits back down.

## Decision

Introduce an **event-driven `SessionStateMonitor`** (ND-013) that pauses the
loop and stops the camera while the session is suspended, and resumes both on
unlock/wake.

- **Signals (no polling).** The monitor observes:
  - `DistributedNotificationCenter` — `com.apple.screenIsLocked` /
    `com.apple.screenIsUnlocked`.
  - `NSWorkspace.shared.notificationCenter` — `screensDidSleep`/`screensDidWake`
    and `sessionDidResignActive`/`sessionDidBecomeActive` (fast user switching).
- **State derivation.** On each signal it recomputes a single `isActive` bool.
  Suspended if ANY of: screen locked (`CGSessionCopyCurrentDictionary()` →
  `CGSSessionScreenIsLocked == true`), not on console
  (`kCGSSessionOnConsoleKey == false`), or `CGDisplayIsAsleep(CGMainDisplayID())`.
  Unknown session dictionary → default to active (never wedge the loop off).
  `onChange` fires on transitions only.
- **Lifecycle in the App target.** `AppDelegate` owns the monitor:
  `active == false` → `stopLoop()` + `camera.suspend()` + render `.suspended`;
  `active == true` → `camera.resume()` + `startLoop()`. The loop is the same
  single cancellable main-actor `Task` (ADR-0005), now extracted into idempotent
  `startLoop()`/`stopLoop()`. Launching while locked starts suspended.
- **AppKit stays out of the core.** The monitor lives in the **App target**
  (AppKit/CoreGraphics), keeping `NoDonutsCore` AppKit-free (ADR-0007). The
  engine never learns *why* it was suspended.
- **False-lock-free resume.** On a `.suspended` capture outcome the engine
  resets absence accounting (`consecutiveAbsentTicks`, `absentSince`,
  `lockAttempted`, `consecutiveErrorTicks`) — mirroring `.unavailable`. A
  lock/unlock or sleep/wake mid-absence therefore cannot cause a grace-less lock
  on resume; the next absence episode must rebuild the full consensus + grace.

## Consequences

- No camera activity, no green light, and no wasted power while the Mac is
  locked/asleep/switched away; clean resume on return.
- The loop has two clear states (running / stopped) with idempotent start/stop,
  so repeated wake events can't stack multiple loops.
- The core stays portable and testable: `EngineCheck` covers the
  reset-on-suspend behavior without AppKit or a real session.
- `SessionStateMonitor` itself depends on AppKit/CoreGraphics and is not exercised
  by `EngineCheck`; it is verified by build + manual lock/sleep testing.
- Full multi-account / fast-user-switching behavior is still out of scope
  (EC-14); we simply suspend when not on the console.

## Alternatives considered

- **Poll session state every tick.** Simpler wiring but wastes work, adds tick
  latency, and keeps the camera alive needlessly. Rejected in favor of the OS
  notifications that already exist.
- **Let the engine decide to stop the camera.** Would pull AppKit/CGSession
  concepts into `NoDonutsCore` and break ADR-0007. Rejected: session/display
  state is an App-target (OS-glue) concern.
- **Keep running but skip locking while suspended.** Still burns power and the
  camera light, and risks acting on stale frames from the login window.
  Rejected.
