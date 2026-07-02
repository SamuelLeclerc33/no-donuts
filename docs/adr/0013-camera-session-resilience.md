# ADR-0013 — Camera session resilience: ObjC-exception shim + disconnect recovery

- Status: Accepted
- Date: 2026-07-02
- Owner: blart

## Context

The capture layer originally selected `AVCaptureDevice.default` exactly once, set
`configured = true`, and never re-evaluated the device or observed its lifecycle.
Two failure modes followed from that:

1. **Crash on abrupt teardown.** External / virtual cameras (UVC webcams, Continuity
   Camera, virtual cams) are exposed as `AVCaptureDALDevice`, and AVFoundation can
   raise an Objective-C `NSException` from a session mutation on such a device.
   Swift cannot `do/try/catch` an ObjC `NSException`, so it propagates to
   `std::terminate → abort()`. [ADR-0002]/EC-21 already fixed this for the *launch-time*
   frame-duration setter by wrapping that one call in an ObjC `@try/@catch` shim
   (`ObjCExceptionCatcher`), but every other session mutation (`beginConfiguration`,
   `addInput`/`addOutput`, `startRunning`/`stopRunning`, and the `AVCaptureDeviceInput`
   constructor) was still unguarded. Removing an external camera at runtime hit exactly
   that gap — confirmed by a real crash report (SIGABRT via `objc_exception_throw` in
   `AVCaptureDALDevice`, 2026-07-02, ND-054).

2. **Wedge on device removal.** With no `AVCaptureDeviceWasDisconnected` /
   `AVCaptureSessionRuntimeError` observers, unplugging the active camera left
   `configured`/`running` stuck `true` — the session silently stopped delivering
   frames and never recovered, even after a replug, because `capture()` short-circuits
   on `configured`. A cached buffer could also be served as a phantom "present" frame.

## Decision

Make the capture session resilient to runtime device changes, on-device only:

- **Shim every session mutation.** All `AVCaptureSession` / `AVCaptureDeviceInput`
  mutations run inside `nd_runCatchingObjCException`. A caught ObjC throw is logged and
  treated as a **non-fatal configuration failure** (`configured` stays `false`, the call
  returns a reason string) rather than aborting the process.
- **Observe device lifecycle and recover by teardown + re-selection.** On
  `AVCaptureDeviceWasDisconnected` (scoped to the active device) or
  `AVCaptureSessionRuntimeError`, tear down on the session queue to a re-configurable
  state (`configured = false`, inputs/outputs removed, cached frame cleared, observers
  dropped). The next `capture()` re-runs configuration, which re-selects
  `AVCaptureDevice.default` — i.e. **auto-switches to the built-in camera** when an
  external one is removed, so protection continues.
- **Interruptions are log-only, NOT teardown.** `AVCaptureSessionWasInterrupted`
  fires with reason `videoDeviceInUseByAnotherClient` when a video-call app grabs the
  camera. macOS is multi-client and AVFoundation auto-resumes when the interruption
  ends, so tearing down here would defeat the [ADR-0003] "assume present during a call,
  never lock mid-meeting" policy. We only log the interruption/reason.
- **Fail safe, never fail open.** If no camera is present after teardown, configuration
  returns `.unavailable("no camera device")` → the engine surfaces honest
  `cameraUnavailable` and does **not** lock the user out (EC-07/EC-08/EC-09). A
  monotonic freshness guard on the cached buffer prevents a stale pre-removal frame
  from being served as a false "present".

## Consequences

- The runtime-removal crash class is eliminated to match the launch-time fix; the two
  together cover DAL exceptions across the whole session lifecycle. EC-22 documents the
  runtime case; EC-21 the launch case.
- Removing an external camera degrades gracefully to the built-in camera with no user
  action; losing all cameras degrades to an honest, non-locking `cameraUnavailable`
  state paired with the ND-045 "not protecting you" notification.
- Trade-off: recovery is driven by the next `capture()` tick re-configuring, not by
  `resume()` (which no-ops when `configured` was cleared by a teardown during suspend).
  This self-heals within one tick and was accepted over adding a second restart path.
- The stale-frame threshold is a fixed ~3 s constant in the camera layer, decoupled
  from the engine's tick interval (which lives in `Config`, out of this layer's reach);
  it errs fail-safe (a missed live frame → `cameraUnavailable`, never a false present).
  Duty-cycle/threshold tuning stays tracked in ND-042.

## Alternatives considered

- **Rebuild an `AVCaptureDevice.DiscoverySession` and pick a specific device on
  disconnect.** More control, but more moving parts; re-selecting `AVCaptureDevice.default`
  on the next tick achieves the desired "fall back to built-in" behavior with far less code.
- **Tear down on interruptions too (uniform handling).** Simpler code, but it regresses
  ADR-0003 by locking the user out mid-call — rejected.
- **Port the whole camera layer to Swift-only error handling.** Not possible: the crash
  is an ObjC `NSException`, which Swift cannot catch; the ObjC shim is required.
