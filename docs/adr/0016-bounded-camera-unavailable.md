# ADR-0016 — Bounded camera-unavailable window (lid open), 10-minute busy cap

- Status: Accepted (amends the EC-07/08/09 policy and the ADR-0003 cap value)
- Date: 2026-09-25
- Owner: homer (with blart)

## Context

When the camera was **unavailable**, the engine showed `cameraUnavailable` and never locked. Unavailable covers permission denied or revoked, no trusted camera, a wedged or removed device, another app blocking configuration, and the lid closed. The only signal was a notification every 5 minutes. That made "unavailable" a one-step bypass: revoke camera access (`tccutil reset Camera` needs no admin), or make the camera fail, and protection ends for as long as it lasts.

Two related gaps:
- An unavailable tick reset the ADR-0003 busy-camera window, so mixing unavailable ticks with busy ones could restart the cap indefinitely.
- The cap itself was 30 minutes. Opening Photo Booth could buy 30 minutes unlocked.

Since ADR-0015, closing the lid (clamshell with an external monitor) also means "camera unavailable". Locking clamshell users on a timer would make the app unusable for them.

## Decision

- **Lid open:** after `maxCameraUnavailableSeconds` (**120 s**) of *continuous* unavailability, the engine escalates to absence. The normal consensus and grace then apply, and the lock goes through the ND-054 retry/backoff path. Any real frame, busy outcome, pause, trusted-network switch or session suspend resets the window.
- **Lid closed:** today's behavior is kept. There is no lock, the not-protecting notification fires, and the window is reset, so closing the lid never builds toward a lock. Lid state comes from `AppleClamshellState` on `IOPMrootDomain` (`LidState.isClosed()`). **An unreadable value counts as open**, so the failure mode is an extra lock, never a fail-open.
- **Before the cap, an unavailable tick HOLDS** (like the EC-10 recognizer-error hold). It shows `cameraUnavailable` but does not reset absence consensus, grace or lock-retry state. Otherwise alternating unavailable ticks with busy ticks past the call cap, or with no-face frames, would zero the consensus every time and never lock. That hole was found in security review. A returning user's frame goes through `markPresent`, which resets everything, so holding can't false-lock them.
- **Only a real laptop with its lid open escalates.** `LidState` is tri-state: `.open`, `.closed`, or `.noLid` (the property is absent, as on desktop Macs, which have no built-in camera under ADR-0015). `.closed` and `.noLid` never escalate; otherwise a desktop would be locked every ~2 minutes forever.
- While escalating, the display stays `cameraUnavailable`, so the notification isn't withdrawn seconds before the lock, until the lock path sets `suspended` or `lockFailed`. `cameraUnavailableEscalating` is exposed. The notification copy is lid-aware.
- Unavailable ticks **no longer reset** the busy-camera window.
- **Busy cap lowered** from 30 to **10 minutes** (`maxCallAssumedPresentSeconds = 600`). macOS normally shares camera frames during calls, so the busy-with-no-frames case is rare, and 10 minutes covers transient cases.

## Consequences

- Revoking camera access, breaking the camera, or blocking it no longer disables protection for longer than about 2 minutes plus consensus plus grace while the lid is open.
- **A user who denies camera permission gets locked after every unlock** (about 2 min plus grace). This is intended: the app cannot protect them. The notification explains that they should grant access or quit No Donuts.
- Clamshell users stay unprotected while the lid is closed, as ADR-0015 already accepted. The notification says so.
- A misread lid state (reported open while actually closed) could cause extra locks in clamshell. That is recoverable, and it errs toward safety.

## Alternatives considered

- **Always escalate, including with the lid closed.** Clamshell users would be locked on a timer. Rejected.
- **Never escalate (status quo).** Leaves a trivial bypass. Rejected.
