# ADR-0006 — Screen-lock mechanism: synthetic Ctrl-Cmd-Q via osascript

- Status: Superseded by ADR-0010
- Date: 2026-06-30
- Owner: wiggum

> **Superseded by [ADR-0010](0010-screen-lock-no-accessibility.md).** The
> osascript / Ctrl-Cmd-Q path required Accessibility, which was unreliable
> (especially on ad-hoc-signed builds) and did not lock on the target Mac. The
> lock is now a layered, no-Accessibility mechanism
> (`SACLockScreenImmediate` → `CGSession -suspend`), CGSession-verified and
> async. The record below is kept for history.

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
then **verifies the screen actually locked** before returning `true`. A throw
from `run()` or a non-zero exit status is logged via `os_log`
(`Logger(subsystem: "com.nodonuts.app", category: "lock")`) and returns `false`.
It **never** returns `true` on failure. The protocol is
`@discardableResult func lock() -> Bool` so callers (the presence engine / UI)
can surface honest "not protecting" status.

**CGSession verification.** osascript exiting 0 only proves the keystroke was
*dispatched*, not that the screen locked. After a 0 exit, `lock()` polls
`CGSessionCopyCurrentDictionary()` for the `CGSSessionScreenIsLocked` flag (raw
string key — the constant is not bridged to Swift) every ~0.1s up to a 1s
timeout, and returns `true` **only** once the session reports locked. So the
Bool now reflects a **confirmed lock**, not mere keystroke dispatch.

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

## Known limitations / guarantee

The lock is now **CGSession-verified**, which closes the previously
"undetectable" fail-open for everything we can observe after the fact:

- **`lock()` returns a confirmed lock, not just keystroke dispatch.** After
  `osascript` exits `0`, `lock()` polls CGSession's `CGSSessionScreenIsLocked`
  and only returns `true` once the session reports locked. osascript exiting 0
  no longer counts as success on its own.
- **Remapped/disabled shortcut is now detected.** If the user has remapped or
  disabled the Ctrl-Cmd-Q Lock-Screen shortcut (System Settings → Keyboard →
  Keyboard Shortcuts), or Accessibility is denied so the keystroke is dropped,
  the keystroke can still be dispatched with a 0 exit — but the session never
  reports locked, so `lock()` returns `false` → the engine surfaces
  `.lockFailed`. The prior "exit 0 while nothing locks → wrongly returns `true`"
  gap (which produced a stuck fake `.suspended`) is closed (EC-19).
- **Detectable-up-front failures are still surfaced.** A throw from `run()` or a
  non-zero exit is still caught and returns `false`.

### Remaining caveats / follow-up

- **Bounded blocking.** Verification calls `waitUntilExit()` synchronously and
  then polls for up to ~1s, so `lock()` briefly blocks the caller (~≤1s).
  Making `lock()` async / non-blocking (do the poll off the calling actor)
  remains a tracked follow-up (ND-014).
- **Not anti-spoofing.** This verification is about *did the screen lock*, not
  about defeating a determined attacker; v1 anti-spoofing scope is unchanged
  (EC-12, SECURITY_PRIVACY.md).

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
