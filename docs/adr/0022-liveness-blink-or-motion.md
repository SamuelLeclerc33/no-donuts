# ADR-0022 — Liveness: blink or non-rigid facial motion within 60 s

- Status: Accepted
- Date: 2026-09-28
- Owner: cooper (with wiggum, blart)

## Context

On 2026-09-28, on-device testing showed that a **photo of the enrolled user on a phone screen** held to the built-in camera **matched as the user** (score ~0.80 vs threshold 0.50). It also **passed the anti-spoof texture check**, with texture 58–89 against a floor of 12; the live user's minimum is 31.6. It kept the Mac unlocked for as long as it was held (ND-116). The variance-of-Laplacian check (ND-041/072) only catches blurry prints and low-quality screens. A modern phone screen has as much fine detail as a real face, so no floor value separates them. Per-frame texture can't work; the signal has to be **temporal**.

## Decision

An enrolled identity match counts as the user **only with live evidence in the last 60 s**: a **blink**, or **non-rigid / non-planar facial motion**.

- **Frame tap:** the camera already runs at 15 fps. Every other frame (~7 fps) goes to a `LivenessAnalyzer` on its own queue, which drops frames when busy and never blocks capture. It runs Vision face landmarks on the largest face. It only runs while the camera runs, never while suspended.
- **Blink:** the eye aspect ratio of both eyes drops below a fraction of its rolling open-eye baseline and recovers within ≤ 500 ms.
- **Motion:** a homography is fitted to the landmarks of frames ~0.5–1 s apart. A planar photo, even tilted or moved, fits almost exactly. A live 3D face turning or changing expression leaves a residual above a threshold, normalized by inter-ocular distance.
- **Window:** evidence within the last 60 s, or within the startup window: 60 s from the **first analyzed face** after an enforcement (re)start (ND-118a). It is armed once per restart, starts once, never restarts on later faces (hiding and re-showing a photo can't extend it), and falls back to arming time if no face is ever analyzed. Humans blink every 2–10 s even when concentrating, and 60 s leaves a wide margin.
- **Result:** a match without live evidence returns `.notLive`. The engine treats it as **normal absence** (consensus + grace, ~10 s), **not** the 3-tick stranger lock (ADR-0017), so a missed blink can't cause a fast false lock.
- **Toggle:** liveness is gated by the existing "Reject photos of me" setting (`antiSpoofEnabled`), together with the texture check.

**Face-track binding (review + on-device):** evidence belongs to one continuous face track (gap ≤ 1.0 s, IoU ≥ 0.3, IOD change ≤ 25%). A break resets the evidence, but a new track that starts within 1 s of, and overlaps, a track that was both matched at a tick and had its own evidence gets a 20 s probation that can't chain. This stops the photo-at-tick / attacker-blinks-between-ticks bypass without false-locking a moving user.

## Consequences

- A still photo or screen image of the user keeps the Mac unlocked for at most ~60 s + consensus + grace, instead of indefinitely. **Verified on-device 2026-09-28: a phone photo locked the Mac in ~6 s.**
- **Not stopped:** a replayed **video** of the user blinking or moving on a screen. That needs a challenge-response or depth sensing, which the built-in camera doesn't have. Recorded as a residual in the threat model.
- **False-lock risk:** a user whose eyes the detector can't see (strong glasses glare, extreme angle) and who holds perfectly still for more than 60 s gets the normal ~10 s lock. Motion evidence covers most of these. The thresholds are provisional and logged for on-device tuning.
- **Cost:** landmark detection at ~7 fps at 640×480. The per-frame cost is measured and reported in ND-116.

## Alternatives considered

- **Tune the texture floor:** impossible. The phone screen scored above the live user's minimum.
- **Blink only:** rejected by the user in favour of blink OR motion, to reduce false locks when eyes are hard to track.
- **Challenge only at unlock:** doesn't stop a photo held up while the session is still unlocked.
