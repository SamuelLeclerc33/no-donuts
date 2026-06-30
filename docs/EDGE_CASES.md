# Edge Cases — No Donuts

A living log of edge cases to validate together. Each has a **decision** (or `OPEN`) and a **status**.

**Status:** `OPEN` (needs discussion) · `DECIDED` (policy set) · `IMPLEMENTED` (in code + tested)

| # | Edge case | Decision | Status | Owner |
|---|---|---|---|---|
| EC-01 | **On a video call** (another app holds camera) | Try multi-client shared frames; if none, assume PRESENT and don't lock. See [ADR-0003](adr/0003-camera-in-use-policy.md). | DECIDED | blart/homer |
| EC-02 | **Screen already locked / display asleep / session inactive** | Suspend the loop; take no action. | DECIDED | blart |
| EC-03 | **Stranger sits down, enrolled user absent** | **Presence-only MVP (ND-020/025):** detection has no identity, so ANY detected face counts as present — a stranger keeps the Mac unlocked. The strict policy (stranger = ABSENT → lock after grace; a non-matching face must NOT count as present) returns with identity matching in v1.1. | DECIDED (strict behavior deferred to identity) | homer/wiggum/cooper |
| EC-04 | **User present but looking away / turned head** | Detection may miss the face briefly; grace period + consecutive-absent debounce absorbs short gaps. Tune thresholds. | OPEN | cooper/homer |
| EC-05 | **Poor lighting / backlight / glasses / hat / mask** | Affects detection + match. Need robust model + threshold; surface "can't see you" status. | OPEN | cooper |
| EC-06 | **Multiple faces in frame** (user + colleague) | If enrolled user matches any face → PRESENT. Define behavior re: shoulder-surfing later. | OPEN | cooper/homer |
| EC-07 | **External monitor, lid closed (clamshell)** | Built-in camera unavailable → `capture()` returns `.unavailable` → engine surfaces honest `cameraUnavailable` status and does NOT lock (no fail-open; this is now real, not masked by a fake recognizer). User isn't locked out when the only camera is gone. A periodic "can't see you" notification is tracked as ND-045. | DECIDED | blart/homer |
| EC-08 | **Camera permission denied / restricted (MDM)** | `capture()` returns `.unavailable` (denied/restricted or no device); engine surfaces honest `cameraUnavailable` status and does NOT lock. No silent fail-open. krusty owns the prompt/remediation UX; periodic "can't see you" notification tracked as ND-045. | DECIDED | blart/homer/krusty |
| EC-09 | **No camera at all / camera hardware error** | Same policy as EC-07/EC-08: `.unavailable` → `cameraUnavailable`, do NOT lock (never hard-lock the user out when we can't see). Honest visible status; periodic "can't see you" notification tracked as ND-045. | DECIDED | blart/homer |
| EC-10 | **Recognition error / model timeout on a tick** | Conservative HOLD (bounded): a transient `.error` tick neither advances nor resets the absence consensus — no markAbsent (no lock-storm) and no markPresent (no false-unlock); state + counters left untouched until the next clean reading. The 3-tick absence consensus (`consecutiveAbsentTicksToLock`) further damps single-frame glitches. **The hold is bounded:** after `maxConsecutiveErrorsBeforeAbsent` (default 3) CONSECUTIVE errors the engine escalates — it treats the tick as absence (markAbsent), so a wedged recognizer runs the normal grace→lock path and locks rather than holding unlocked forever (no indefinite fail-open). Any clean reading resets the error streak. | DECIDED | homer |
| EC-11 | **User briefly leaves and returns within grace** | No lock; reset cleanly on re-detect. | DECIDED | homer |
| EC-12 | **Photo / phone screen held up to spoof** | Basic anti-spoofing in M4; v1 is not hardened against determined attackers. | OPEN | wiggum/cooper |
| EC-13 | **Laptop sleep / wake, lid open/close** | Loop must pause on sleep and resume sanely on wake without a false lock. | OPEN | blart/homer |
| EC-14 | **Fast user switching / multiple accounts** | Out of scope for v1; document behavior so it doesn't misbehave. | OPEN | homer |
| EC-15 | **App paused by user, then walks away** | Respect pause; don't lock. Consider auto-resume after timed pause. | DECIDED | krusty/homer |
| EC-16 | **Privacy/cover over camera (physical shutter)** | Expected: a covered lens yields a dark frame → Vision returns no faces → `noFace` → counts toward the absence consensus → ABSENT → locks after grace; pending on-device verification. (A distinct "covered" status remains a nice-to-have.) | DECIDED | blart/homer |
| EC-17 | **Presentation / screen sharing without camera** | Camera not in use but user may step away intentionally → normal lock rules apply. Confirm acceptable. | OPEN | homer |
| EC-18 | **Battery / power profile** | Duty-cycle checks; possibly slow tick on battery to save power. | OPEN | blart/homer |
| EC-19 | **Screen-lock request reports success but may not have locked** | The lock sends a synthetic Ctrl-Cmd-Q via System Events ([ADR-0006](adr/0006-screen-lock-mechanism.md)), which needs Accessibility. Two cases: **(a) detectable failure** — `osascript` throws or exits non-zero (e.g. Accessibility outright denied / keystroke not delivered) → `lock()` returns `false` → engine shows honest `lockFailed` status ("can't lock — grant Accessibility"); do **NOT** fail open. **(b) undetectable failure** — `osascript` exit 0 only means the keystroke was *dispatched*, not that the screen locked; if the Ctrl-Cmd-Q shortcut is **remapped/disabled**, the keystroke can be dispatched while nothing locks and `lock()` still returns `true`. This is a **known MVP gap**; true lock-state verification (CGSession `CGSSessionScreenIsLocked`) is deferred (ND-014). | DECIDED (gap noted) | wiggum/homer |

## How to use this file
- Add a row when a new edge case surfaces. Keep it OPEN until we agree on policy.
- When decided, write the policy in the Decision column (link an ADR if architectural).
- When shipped + tested, mark IMPLEMENTED and reference the backlog item.
