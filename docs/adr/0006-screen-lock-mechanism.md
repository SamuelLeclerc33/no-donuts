# ADR-0006 — Screen-lock mechanism: synthetic Ctrl-Cmd-Q via osascript

- Status: Accepted
- Date: 2026-06-30
- Owner: wiggum

## Context

The core action of No Donuts is to lock the Mac when the enrolled user is absent
(ND-014). We need a **reliable programmatic screen lock** that works under our
sandbox/entitlement posture. We lock only — unlock always stays with macOS
(Touch ID / password). Whatever mechanism we pick, a lock request must either
lock or **loudly report failure**; it must never silently fail open (a failed
lock that is reported as success would leave an unattended machine unprotected).

## Decision

The lock is issued by **synthesizing the macOS Lock Screen shortcut
Ctrl-Cmd-Q** via `osascript` / System Events:

```
/usr/bin/osascript -e 'tell application "System Events" to key code 12 using {control down, command down}'
```

(`key code 12` is the `Q` key; Ctrl-Cmd-Q is the system Lock Screen shortcut.)

`ScreenLocker.lock()` runs this through `Process`, calls `waitUntilExit()`, and
returns `process.terminationStatus == 0`. A throw from `run()` or a non-zero exit
status is logged via `os_log` (`Logger(subsystem: "com.nodonuts.app",
category: "lock")`) and returns `false`. It **never** returns `true` on failure.
The protocol is `@discardableResult func lock() -> Bool` so callers (the presence
engine / UI) can surface honest "not protecting" status.

## Consequences

- **Requires a new TCC permission: Accessibility.** Sending synthetic keystrokes
  requires the app to be granted Accessibility (System Settings → Privacy &
  Security → Accessibility). This is a permission **beyond** the camera grant the
  user already has to give. If Accessibility is **denied**, macOS drops the
  keystroke and the screen does not lock — but `lock()` detects this (non-zero
  status / dropped key path) and returns `false`, so the failure is **surfaced,
  never silent** (see EC-19). gordon/krusty own prompting for and explaining this
  grant.
- Spawns a **short-lived `osascript` process** per lock. Cheap, but it is an
  out-of-process dependency on `/usr/bin/osascript` and AppleScript/System Events.
- No private API and no login-window switch — uses the same path a user would
  use by hand.

## Known limitations / weaker guarantee (MVP)

The fail-safe guarantee above is **weaker than it first appears**, and we are
accepting that for the MVP:

- **`osascript` exit status ≠ confirmed lock.** `lock()` returns `true` when
  `osascript` launches and exits `0`. That only confirms the AppleScript ran and
  the Ctrl-Cmd-Q keystroke was **dispatched** — it does **not** confirm the
  screen actually locked. The exit status reflects whether the script executed,
  not the resulting system state.
- **Undetectable fail-open if the shortcut is remapped/disabled.** If the user
  has remapped or disabled the Ctrl-Cmd-Q Lock-Screen shortcut (System Settings →
  Keyboard → Keyboard Shortcuts), or in some Accessibility/permission paths, the
  keystroke can be dispatched and `osascript` can exit `0` while **nothing
  locks**. In that case `lock()` returns `true` even though the machine is still
  unlocked. This is a silent fail-open we currently cannot detect.
- **Detectable failures are still surfaced.** A throw from `run()` or a non-zero
  exit (e.g. Accessibility outright denied) is still caught and returns `false`,
  so those *detectable* failures are honestly reported (EC-19). The gap is only
  the *undetectable* case above.

**Decision:** accept this weaker guarantee for the MVP (no change to the
osascript mechanism). **Defer** to a follow-up pass (ND-014):

1. **Verified lock state** — after issuing the lock, query CGSession
   (`CGSSessionScreenIsLocked` via `CGSessionCopyCurrentDictionary`) and only
   report success once the session reports locked, closing the fail-open.
2. **Non-blocking / async `lock()`** — the current implementation calls
   `waitUntilExit()` synchronously; verification implies polling/waiting for the
   lock state, which should be done off the calling actor.

Until then, callers must treat a `true` return as "lock keystroke dispatched,"
not "session confirmed locked."

## Alternatives considered

- **`SACLockScreenimmediate` (login.framework private API):** locks immediately
  with **no Accessibility grant** required. Rejected for v1 because it is a
  **private symbol** — fragile across macOS releases and a code-signing/notarization
  risk. Kept as a **fallback** if osascript proves unreliable.
- **`/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend`:**
  public, switches to the login window. Also **avoids the Accessibility grant**.
  Slightly different UX (fast-user-switch login window vs. lock screen). Kept as a
  **fallback** alongside `SACLockScreenimmediate` if the osascript path is unreliable.

Both fallbacks avoid the Accessibility permission; we accept the Accessibility
cost for v1 in exchange for using only public, stable, hand-equivalent APIs.
