# ADR-0010 — Screen-lock mechanism: layered no-Accessibility lock

- Status: Accepted
- Date: 2026-06-30
- Owner: wiggum

## Context

The core action of No Donuts is to lock the Mac when the enrolled user is absent
(ND-014). We need a **reliable programmatic screen lock** under our
sandbox/entitlement posture. We lock only — unlock always stays with macOS
(Touch ID / password). A lock request must either lock or **loudly report
failure**; it must never silently fail open.

ADR-0006 chose a synthetic **Ctrl-Cmd-Q via `osascript` / System Events**. That
path requires the macOS **Accessibility** permission to deliver the synthetic
keystroke. In practice this was unreliable — especially on **ad-hoc-signed
builds** — and on the target Mac it **did not lock at all** even with the grant
attempted. It also added a second TCC prompt (beyond camera) and blocked the
caller during verification. We need a lock that works **without Accessibility**
and that does not block the presence poll's main actor.

## Decision

Use a **layered, no-Accessibility** lock, verified against CGSession and
implemented as an `async`, non-blocking call:

1. **`SACLockScreenImmediate`** — resolved at runtime via
   `dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)`
   + `dlsym(handle, "SACLockScreenImmediate")`, cast to
   `@convention(c) () -> Void` and called. No link-time dependency on the private
   framework; if `dlopen`/`dlsym` returns `nil`, skip to the fallback. Locks
   immediately, **no Accessibility grant**.
2. **`CGSession -suspend`** (fallback) — spawn the public tool at
   `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession`
   with `["-suspend"]`. Switches to the login window; also **no Accessibility
   grant**.

**CGSession verification.** After each attempt, `lock()` verifies via
`CGSessionCopyCurrentDictionary()`: the screen counts as locked if EITHER
`CGSSessionScreenIsLocked` is true OR the session is no longer on the console
(`kCGSSessionOnConsoleKey == false`, how `-suspend` presents). Values are
`CFBoolean` and may bridge as `Bool` or `NSNumber`, so both are read
defensively; the on-console signal is only trusted when the key is present so a
normal unlocked session reports NOT locked. `lock()` returns `true` **only** on
a confirmed lock.

**Async / non-blocking.** `ScreenLocking.lock()` is now
`@discardableResult func lock() async -> Bool`. `lock()` computes ONE ~3s
deadline and shares it across both mechanisms — the SAC poll and the CGSession
fallback poll draw from the same budget, so the whole call is bounded at ~3s
(not ~3s per mechanism = ~6s), keeping the awaiting presence tick loop
responsive. The verification poll (`waitForScreenLocked(deadline:)`) uses
`Task.sleep`, **not** `Thread.sleep`, so the presence engine's main actor is
never blocked while a lock is pending, and it is **cancellation-aware**: on task
cancellation it returns the current lock state immediately instead of
busy-spinning to the deadline. The `CGSession -suspend` fallback is spawned
**without** `waitUntilExit()` (no synchronous block on the actor; the exit code
is irrelevant because the verify poll is what confirms the lock) and a launch
failure is logged rather than silently swallowed.

If neither mechanism produces a confirmed lock, `lock()` logs a warning via
`os_log` (`Logger(subsystem: "com.nodonuts.app", category: "lock")`) and returns
`false`. It **never** returns `true` on failure — the engine surfaces honest
`.lockFailed`.

This supersedes **ADR-0006**.

## Consequences

- **No Accessibility grant needed or requested.** The lock works with only the
  camera permission the user already grants. Removes the second TCC prompt and
  the ad-hoc-signing fragility that broke the osascript path.
- **`SACLockScreenImmediate` is a private symbol**, loaded **defensively** at
  runtime (no link-time dependency), with a **public fallback** (`CGSession
  -suspend`) if the symbol can't be resolved on a given macOS release. This
  contains the code-signing/notarization and cross-version risk of the private
  API.
- **`CGSession -suspend` uses the login window** (fast-user-switch style) rather
  than the in-place lock screen — a slightly different UX, but a real, confirmed
  lock, and no Accessibility.
- **`kCGSSessionOnConsoleKey == false` is ambiguous** — it means "not on the
  console," which can be a genuine password-lock/`-suspend` OR a fast-user-switch
  to another account. We rely on it as a lock signal anyway because it is safe in
  context: `lock()` is only ever called while this session is **on console**
  (`SessionStateMonitor` pauses the presence loop when off-console, ND-013,
  EC-14). So at verify time, off-console reliably means our own `CGSession
  -suspend` succeeded, not a stray FUS state. This is documented as a comment in
  `isScreenLockedNow()`; no logic change.
- **Non-blocking.** `lock()` being `async` means callers must `await` it; homer's
  engine calls `await locker.lock()`. The verify poll runs off the calling
  actor's blocking path.
- Still spawns a short-lived process only in the fallback case; the primary path
  is an in-process function call.

## Known limitations / guarantee

- The lock is **CGSession-verified**: `lock()` returns a confirmed lock, not a
  mere "mechanism invoked." An invoked `SACLockScreenImmediate` that doesn't lock
  falls through to the fallback; a fallback that doesn't lock returns `false`.
- **Not anti-spoofing.** This is about *did the screen lock*, not defeating a
  determined attacker; v1 anti-spoofing scope is unchanged (EC-12,
  SECURITY_PRIVACY.md).

## Amendment (2026-09-24): CGSession is gone; SACSwitchToLoginWindow replaces it (ND-058, ND-074)

**Observed:** on macOS 27.0 (26A428) the `CGSession` tool (`/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession`) no longer exists. The public fallback was dead, leaving `SACLockScreenImmediate` as the only working mechanism. A break there would surface only at the first real walk-away, as `.lockFailed` shown to an empty chair.

**Probe on the same machine:** `dlopen(login.framework)` succeeds and `dlsym` resolves `SACLockScreenImmediate`, `SACSwitchToLoginWindow` and `SACScreenSaverStartNow`. Screensaver and display-sleep routes are rejected as lock mechanisms: they only lock when the user's "require password" delay is 0, and on the dev Mac it is 300 s.

**Decision:**
- The lock chain is `SACLockScreenImmediate`, then `SACSwitchToLoginWindow`. The second is the in-process equivalent of the old `CGSession -suspend` (it switches to the login window). Verification is unchanged: CGSession `ScreenIsLocked`, or off-console, with the same fast-user-switching caveat.
- **Launch self-test (ND-058):** `ScreenLocker.selfTest()` resolves the symbols without calling them. It runs at launch and on every session resume or wake. If no mechanism resolves, the app shows a persistent "can't lock the screen on this macOS" state: header, red glyph, and a repeating `nd.lockUnavailable` notification.
- Each lock logs which mechanism confirmed it (`lock confirmed via …`, persisted `.notice`), as a canary for Apple changing the private API.
- **Accepted risk:** both mechanisms live in `login.framework`, so they aren't independent. An opt-in Accessibility Ctrl-Cmd-Q tier was considered and declined, because it brings back the permission and ad-hoc-signing unreliability this ADR removed. The self-test turns a silent break into a loud one.

## Alternatives considered

- **Synthetic Ctrl-Cmd-Q via `osascript` (ADR-0006):** required Accessibility,
  was unreliable on ad-hoc-signed builds, and did not lock on the target Mac.
  Superseded by this ADR.
- **`SACLockScreenImmediate` only (no fallback):** simplest, but a single private
  symbol with no public backstop is too fragile across macOS releases — hence the
  layered design with `CGSession -suspend`.
- **`pmset` + require-password:** indirect and does not deterministically lock on
  demand; rejected.
