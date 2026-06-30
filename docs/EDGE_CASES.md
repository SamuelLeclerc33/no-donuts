# Edge Cases — No Donuts

A living log of edge cases to validate together. Each has a **decision** (or `OPEN`) and a **status**.

**Status:** `OPEN` (needs discussion) · `DECIDED` (policy set) · `IMPLEMENTED` (in code + tested)

| # | Edge case | Decision | Status | Owner |
|---|---|---|---|---|
| EC-01 | **On a video call** (another app holds camera) | Try multi-client shared frames; if none, assume PRESENT and don't lock. See [ADR-0003](adr/0003-camera-in-use-policy.md). | DECIDED | blart/homer |
| EC-02 | **Screen already locked / display asleep / session inactive** | Suspend the loop; take no action. | DECIDED | blart |
| EC-03 | **Stranger sits down, enrolled user absent** | Treat as ABSENT → lock after grace. A non-matching face must NOT count as present. | DECIDED | homer/wiggum |
| EC-04 | **User present but looking away / turned head** | Detection may miss the face briefly; grace period + consecutive-absent debounce absorbs short gaps. Tune thresholds. | OPEN | cooper/homer |
| EC-05 | **Poor lighting / backlight / glasses / hat / mask** | Affects detection + match. Need robust model + threshold; surface "can't see you" status. | OPEN | cooper |
| EC-06 | **Multiple faces in frame** (user + colleague) | If enrolled user matches any face → PRESENT. Define behavior re: shoulder-surfing later. | OPEN | cooper/homer |
| EC-07 | **External monitor, lid closed (clamshell)** | Built-in camera unavailable. Behavior when no camera? (Assume present? Disable? Use external cam?) **Interim:** `.unavailable` → `cameraUnavailable`, no lock (fail-open — masked by the fake recognizer). **MUST decide before ND-025** (see Camera follow-ups). | OPEN | blart |
| EC-08 | **Camera permission denied / restricted (MDM)** | `capture()` returns `.unavailable` (denied/restricted or no device); engine surfaces honest `cameraUnavailable` status and does NOT lock. No silent fail-open. krusty owns the prompt/remediation UX. | DECIDED | blart/homer/krusty |
| EC-09 | **No camera at all / camera hardware error** | Define fail policy (don't hard-lock the user out repeatedly). **Interim:** `.unavailable` → `cameraUnavailable`, no lock (fail-open — masked by the fake recognizer). **MUST decide before ND-025** (see Camera follow-ups). | OPEN | blart/homer |
| EC-10 | **Recognition error / model timeout on a tick** | Don't reset absence timer on error; count conservatively. Avoid lock-storms. | OPEN | homer |
| EC-11 | **User briefly leaves and returns within grace** | No lock; reset cleanly on re-detect. | DECIDED | homer |
| EC-12 | **Photo / phone screen held up to spoof** | Basic anti-spoofing in M4; v1 is not hardened against determined attackers. | OPEN | wiggum/cooper |
| EC-13 | **Laptop sleep / wake, lid open/close** | Loop must pause on sleep and resume sanely on wake without a false lock. | OPEN | blart/homer |
| EC-14 | **Fast user switching / multiple accounts** | Out of scope for v1; document behavior so it doesn't misbehave. | OPEN | homer |
| EC-15 | **App paused by user, then walks away** | Respect pause; don't lock. Consider auto-resume after timed pause. | DECIDED | krusty/homer |
| EC-16 | **Privacy/cover over camera (physical shutter)** | Equivalent to "no face" → behaves like absent; consider distinct status. | OPEN | blart |
| EC-17 | **Presentation / screen sharing without camera** | Camera not in use but user may step away intentionally → normal lock rules apply. Confirm acceptable. | OPEN | homer |
| EC-18 | **Battery / power profile** | Duty-cycle checks; possibly slow tick on battery to save power. | OPEN | blart/homer |
| EC-19 | **Screen-lock request reports success but may not have locked** | The lock sends a synthetic Ctrl-Cmd-Q via System Events ([ADR-0006](adr/0006-screen-lock-mechanism.md)), which needs Accessibility. Two cases: **(a) detectable failure** — `osascript` throws or exits non-zero (e.g. Accessibility outright denied / keystroke not delivered) → `lock()` returns `false` → engine shows honest `lockFailed` status ("can't lock — grant Accessibility"); do **NOT** fail open. **(b) undetectable failure** — `osascript` exit 0 only means the keystroke was *dispatched*, not that the screen locked; if the Ctrl-Cmd-Q shortcut is **remapped/disabled**, the keystroke can be dispatched while nothing locks and `lock()` still returns `true`. This is a **known MVP gap**; true lock-state verification (CGSession `CGSSessionScreenIsLocked`) is deferred (ND-014). | DECIDED (gap noted) | wiggum/homer |

## How to use this file
- Add a row when a new edge case surfaces. Keep it OPEN until we agree on policy.
- When decided, write the policy in the Decision column (link an ADR if architectural).
- When shipped + tested, mark IMPLEMENTED and reference the backlog item.
