# ADR-0005 — Presence loop concurrency: main-actor-driven loop

- Status: Accepted
- Date: 2026-06-30
- Owner: homer

## Context

The presence loop runs `capture -> recognize -> decide -> render` on a fixed
interval and updates UI (the menu-bar status) each tick. The original scaffold
drove this with a repeating `Timer.scheduledTimer` whose closure spun up a
detached `Task` and hopped to `MainActor.run` to render. Under Swift 6 strict
concurrency this failed to compile: the engine's mutable state and the
non-`Sendable` capture of `self`/`menuBar` across the detached `Task` boundary
produced data-race / Sendable errors, and the loop's isolation was unclear.

## Decision

The presence loop is **main-actor-driven**.

- `PresenceEngine` is annotated `@MainActor`. It holds the only mutable presence
  state, so isolating it to the main actor makes its decision logic free of data
  races without locks. `AppDelegate` is also `@MainActor`.
- The loop is a **single cancellable `Task { @MainActor in ... }`** stored on the
  delegate (`loopTask`), using `try? await Task.sleep(for:)` for the interval
  instead of a `Timer`. It is cancelled in `applicationWillTerminate`.
- The async protocol methods `CameraCapturing.capture()` and
  `FaceRecognizing.recognize(_:)` are **awaited from the main actor**. `await`
  suspends the main actor at the suspension point; it does not block the run
  loop. The main thread remains responsive to UI/menu events while the work is
  in flight.

## Consequences

- Compiles cleanly under Swift 6 strict concurrency; no `Sendable` warnings and
  no detached tasks capturing main-actor state.
- The loop has a single, obvious lifecycle (one task, cancellable) rather than a
  timer plus ad-hoc tasks.
- **Important for cooper/blart:** because `capture()`/`recognize()` are awaited
  from the main actor, any heavy Vision/CoreML/AVFoundation work inside those
  implementations MUST be offloaded off the main actor (e.g. a `nonisolated`
  body, a background actor, or `Task.detached`/`await` onto a dedicated queue)
  and only the result returned. The protocol contract is `async` precisely so
  implementations can suspend during compute; they must not run heavy work
  synchronously on the main actor.
- The async service protocols (`CameraCapturing`, `FaceRecognizing`, and
  transitively `EnrollmentStoring`) are declared `Sendable` so the `@MainActor`
  engine can `await` them across isolation boundaries without a
  `#SendingRisksDataRace` diagnostic. Real implementations MUST preserve
  `Sendable` — via immutable stored state, by being an `actor`, or with a
  carefully guarded `@unchecked Sendable` — and must still offload heavy work
  off the main actor (see the cooper/blart note above).
- If meaningful compute later migrates onto the engine itself, `PresenceEngine`
  can be promoted from `@MainActor` to an `actor` (see Alternatives). Callers
  already `await` its `tick`, so that change would be largely source-compatible.

## Alternatives considered

- **Keep the `Timer` + detached `Task`:** rejected — this is exactly what broke
  under strict concurrency and obscured isolation/cancellation.
- **Make `PresenceEngine` an `actor` now:** defers nicely if compute moves onto
  the engine, but today the engine does no heavy work itself (it delegates to
  camera/recognizer) and it must touch main-actor UI state each tick. A
  `@MainActor` class is simpler for the walking skeleton; promote to `actor`
  later only if needed.
- **Background queue/thread for the loop with manual hops to the main actor for
  rendering:** more moving parts and more hop boilerplate than awaiting async
  protocol methods from the main actor, with no benefit while the engine itself
  is light.
