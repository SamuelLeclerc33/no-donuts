import Foundation
import AVFoundation
import os
import ObjCExceptionCatcher

/// Camera-layer logger. os_log is safe on the session queue and never touches
/// the network / disk beyond the unified log.
private let cameraLog = Logger(subsystem: "com.nodonuts.app", category: "camera")

// Owner: blart — camera capture, camera-in-use monitoring, display/session state.
// Backlog: ND-011 (permission), ND-012 (single-frame capture), ND-013 (suspend/resume).
//          ND-031/ND-032 TODO below.

/// Captures frames for the presence loop. Pulls a single frame per tick (not a
/// continuous stream) to save power, and reports when the camera is busy or the
/// session is suspended.
public protocol CameraCapturing: Sendable {
    /// Attempt to obtain a frame for this tick. See CaptureOutcome for the cases.
    func capture() async -> CaptureOutcome
}

/// AVFoundation-backed implementation (ND-011 + ND-012).
///
/// Design: a *persistent* low-FPS `AVCaptureSession` runs in the background and
/// the delegate keeps only the most-recent `CVImageBuffer`. `capture()` samples
/// that one frame per tick rather than consuming a stream — this keeps power use
/// low. The camera light staying on while the session runs is acceptable and
/// honest: we ARE watching.
///
/// Threading / `Sendable`: `capture()` is awaited from the `@MainActor`
/// `PresenceEngine` (ADR-0005), so this type must be `Sendable`. It holds a
/// non-Sendable `AVCaptureSession`, so we declare `@unchecked Sendable` and
/// funnel ALL session + latest-buffer access through a dedicated serial queue
/// (`sessionQueue` for configuration/start, `bufferLock` for the shared buffer).
/// Nothing mutable is touched without that synchronization.
///
/// Suspend/resume (ND-013): when the Mac is locked, the display sleeps, or the
/// session goes inactive, the orchestrator calls `suspend()` to stop the running
/// capture session — which turns the camera indicator light OFF — without tearing
/// down inputs/outputs, so `resume()` is a cheap `startRunning()`. The camera
/// light follows the session's running state: light is on iff the session is
/// running. `configured` stays `true` across a suspend/resume cycle; the `running`
/// flag (guarded by `sessionQueue`) tracks whether the session is currently live.
///
/// Privacy: frames live in memory only. We hand the `CVPixelBuffer` to the
/// recognizer and never write it to disk or off-device.
public final class CameraController: CameraCapturing, @unchecked Sendable {
    /// Serial queue owning session configuration/start and the delegate callbacks.
    private let sessionQueue = DispatchQueue(label: "com.nodonuts.camera.session")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let delegate = SampleBufferDelegate()

    /// True once the session has been configured + started successfully.
    /// Guarded by `sessionQueue`. On a configuration failure this stays `false`
    /// so the next `capture()` retries — a transient hiccup must not permanently
    /// disable the camera for the whole process.
    private var configured = false

    /// True while the capture session is running (camera light ON). Guarded by
    /// `sessionQueue`. Goes `true` after `session.startRunning()` and `false`
    /// after `session.stopRunning()`, so `capture()`/`resume()` can tell whether
    /// the session needs (re)starting after a `suspend()`.
    private var running = false

    /// The active input, retained so `teardown()` can `removeInput` it cleanly.
    /// Guarded by `sessionQueue` — set in `ensureConfigured()`, cleared in
    /// `teardown()`. (The disconnect observer is scoped to the local `device`
    /// captured in `registerObservers`, so no separate device field is needed.)
    private var activeInput: AVCaptureDeviceInput?

    /// NotificationCenter observer tokens for the active device/session
    /// (disconnect, runtime error, interruption begin/end). Registered in
    /// `ensureConfigured()` on success, removed + dropped in `teardown()` so a
    /// re-configure re-registers cleanly (no duplicates, no retain cycle).
    /// Guarded by `sessionQueue`.
    private var observerTokens: [NSObjectProtocol] = []

    /// ND-054: how stale a cached frame may be before `capture()` treats it as
    /// "no frame". A dead/removed-camera session stops delivering buffers but the
    /// last one lingers in the delegate; without this guard we'd report a phantom
    /// present. Chosen as ~2x the presence tick (~1.5s) so a couple of missed
    /// deliveries during normal jitter don't trip it, but a genuinely stalled
    /// session (device gone, teardown in flight) does. The tick interval isn't
    /// visible to this file, hence a documented constant rather than a parameter.
    private static let staleFrameThreshold: TimeInterval = 3.0

    public init() {}

    /// Triggers the macOS camera permission prompt once, at app launch — NOT from
    /// the presence loop (so a tick never blocks on the TCC dialog).
    public func requestAccessIfNeeded() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    public func capture() async -> CaptureOutcome {
        // 1. Permission. Resolve before touching any AV hardware. Never fail open.
        //    Do NOT request access here: prompting from the per-tick loop would
        //    block the @MainActor presence loop until the user answers the TCC
        //    dialog. The prompt is triggered once at launch via
        //    requestAccessIfNeeded(); until granted we report .unavailable.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            return .unavailable("camera permission not yet granted")
        case .denied, .restricted:
            return .unavailable("camera access denied/restricted")
        @unknown default:
            return .unavailable("camera access in unknown state")
        }

        // 2. Lazily configure + start the persistent session on the first
        //    authorized call. Returns a reason string on failure, nil on success.
        if let failure = await ensureConfigured() {
            return .unavailable(failure)
        }

        // NOTE: capture() must NOT restart a stopped session. If a suspend()
        // raced in (monitor saw lock/sleep), restarting here would turn the
        // camera light back ON while locked and double per-tick overhead. A
        // suspended session is only restarted by the explicit resume() below.
        // When suspended, the buffer was cleared, so we fall through to
        // waitForFirstFrame and then report .unavailable("no frame") — correct.

        // 3. Sample the latest frame. If none yet (session just started), wait
        //    briefly for the first delivery before giving up.
        // ND-054: honor the freshness guard. A removed/dead camera stops
        // delivering buffers but the delegate still holds the last one; without
        // this bound we'd return a phantom stale frame and falsely report present.
        if let buffer = delegate.latestBuffer(maxAge: Self.staleFrameThreshold) {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }
        if let buffer = await waitForFirstFrame(timeout: 1.5) {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }

        // macOS camera is multi-client: during a call our session usually still gets
        // frames (handled above → normal recognition). We only get here with NO frame.
        // If another app holds the camera, treat it as a busy call → assume present
        // (ADR-0003); otherwise it's genuinely unavailable.
        //
        // `isInUseByAnotherApplication` is the documented macOS "busy" signal. It's
        // imperfect (timing-sensitive, not guaranteed exhaustive) — verify on-device.
        // The bounded assume-present policy (e.g. a max-duration guard so we don't
        // stay unlocked forever behind a stuck call) lives in the engine (homer), not
        // here; this controller only reports the raw outcome.
        if AVCaptureDevice.default(for: .video)?.isInUseByAnotherApplication == true {
            return .cameraBusyNoFrames   // ND-031/ADR-0003: busy + no frames
        }
        return .unavailable("no frame")

        // TODO(blart): ND-032 — explicit multi-client *shared* frame acquisition.
        //   macOS shares the camera by default, so our persistent session normally
        //   keeps receiving frames during a call (handled by the .frame path above).
        //   This busy fallback only triggers when no frame is obtainable at all; an
        //   explicit multi-client/shared-stream attempt before giving up is still TODO.
        // TODO(blart): ND-013 — detect screen locked / display asleep / inactive session -> .suspended.
    }

    /// Configure inputs/outputs and start the session once. Runs on `sessionQueue`
    /// so all session mutation is serialized. Returns a failure reason, or nil on
    /// success. On success `configured` is set so future calls short-circuit; on
    /// failure `configured` is left `false` and nothing is cached, so the next
    /// `capture()` retries configuration (a transient hiccup is recoverable).
    private func ensureConfigured() async -> String? {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.configured {
                    continuation.resume(returning: nil)
                    return
                }

                // ND-054: auto-switch — this re-selects the current default video
                // device. After an external camera is torn down (see teardown()),
                // the next capture() re-enters here and picks the built-in camera.
                // If none exists we fail SAFE to .unavailable, never fail-open.
                guard let device = AVCaptureDevice.default(for: .video) else {
                    continuation.resume(returning: "no camera device")
                    return
                }

                // ND-054: every session mutation below runs inside the ObjC
                // exception shim. A DAL-backed external device can THROW an
                // NSException during (re)configure (as it does on teardown);
                // Swift can't catch that, so an unguarded call would abort().
                // A throw here is non-fatal: we log, roll back what we can, and
                // return a reason string leaving `configured == false` so the
                // next capture() retries.
                if !self.runCatching("beginConfiguration", { self.session.beginConfiguration() }) {
                    continuation.resume(returning: "camera configuration failed (begin)")
                    return
                }

                // ND-054: constructing the input can ALSO throw an ObjC
                // NSException on a DAL/virtual device (same crash class as the
                // session mutations) — Swift `try?` only catches Swift errors, not
                // an NSException, so wrap the construction in the ObjC shim too.
                // Fail cleanly on an ObjC throw, a Swift throw, OR canAddInput==false.
                var builtInput: AVCaptureDeviceInput?
                let inputBuilt = self.runCatching("AVCaptureDeviceInput(device:)") {
                    builtInput = try? AVCaptureDeviceInput(device: device)
                }
                guard inputBuilt, let input = builtInput,
                      self.session.canAddInput(input) else {
                    _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
                    continuation.resume(returning: "cannot open camera input")
                    return
                }
                guard self.runCatching("addInput", { self.session.addInput(input) }) else {
                    _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
                    continuation.resume(returning: "camera configuration failed (addInput)")
                    return
                }

                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self.delegate, queue: self.sessionQueue)
                guard self.session.canAddOutput(self.output) else {
                    _ = self.runCatching("removeInput") { self.session.removeInput(input) }
                    _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
                    continuation.resume(returning: "cannot add camera output")
                    return
                }
                guard self.runCatching("addOutput", { self.session.addOutput(self.output) }) else {
                    _ = self.runCatching("removeInput") { self.session.removeInput(input) }
                    _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
                    continuation.resume(returning: "camera configuration failed (addOutput)")
                    return
                }

                guard self.runCatching("commitConfiguration", { self.session.commitConfiguration() }) else {
                    continuation.resume(returning: "camera configuration failed (commit)")
                    return
                }

                // Retain the active input (guarded by sessionQueue) so teardown()
                // can remove it. The disconnect observer is scoped to this device
                // via the `device` value captured in registerObservers().
                self.activeInput = input

                // Low frame rate where supported — we only need ~1 frame per tick.
                // Aim for ~1 fps, clamped into the format's supported range. Only
                // set the duration if 1 fps actually fits the range; otherwise
                // leave the device defaults alone.
                //
                // Some devices (e.g. an external UVC webcam surfaced as an
                // AVCaptureDALDevice) reject `activeVideoMin/MaxFrameDuration`
                // by THROWING an NSException, which Swift cannot catch with
                // do/try/catch — it would propagate to abort() and crash on
                // launch. So we (1) clamp the CMTime into the range's own
                // [minFrameDuration, maxFrameDuration] and (2) perform the
                // assignment inside an ObjC @try/@catch shim. A throwing device
                // is NON-fatal: we just log and continue at the default rate.
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
                   (try? device.lockForConfiguration()) != nil {
                    let targetFPS = min(max(1.0, range.minFrameRate), range.maxFrameRate)
                    var frameDuration = CMTime(value: 1,
                                               timescale: CMTimeScale(targetFPS.rounded()))
                    // Clamp into the range's advertised duration bounds. Note
                    // duration is inversely related to rate: min rate -> max
                    // duration, max rate -> min duration.
                    if CMTimeCompare(frameDuration, range.minFrameDuration) < 0 {
                        frameDuration = range.minFrameDuration
                    }
                    if CMTimeCompare(frameDuration, range.maxFrameDuration) > 0 {
                        frameDuration = range.maxFrameDuration
                    }
                    var shimError: NSError?
                    let ok = nd_runCatchingObjCException({
                        device.activeVideoMinFrameDuration = frameDuration
                        device.activeVideoMaxFrameDuration = frameDuration
                    }, &shimError)
                    // Always unlock, regardless of whether the setter threw
                    // (the throw is caught by the shim before returning here).
                    device.unlockForConfiguration()
                    if !ok {
                        cameraLog.notice("Device rejected a fixed frame rate (\(shimError?.localizedDescription ?? "unknown", privacy: .public)); continuing at the default rate")
                    }
                }

                guard self.runCatching("startRunning", { self.session.startRunning() }) else {
                    // A DAL device can throw on start too. Roll back the input so
                    // a retry re-adds cleanly, leave configured == false.
                    _ = self.runCatching("beginConfiguration") { self.session.beginConfiguration() }
                    _ = self.runCatching("removeInput") { self.session.removeInput(input) }
                    _ = self.runCatching("removeOutput") { self.session.removeOutput(self.output) }
                    _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
                    self.activeInput = nil
                    continuation.resume(returning: "camera configuration failed (start)")
                    return
                }
                self.running = true
                self.configured = true

                // ND-054: register observers now that the session is live. Scope
                // the disconnect observer to THIS device and the session
                // observers to `self.session`. The blocks re-dispatch onto
                // sessionQueue — we must not mutate the session on the
                // notification's delivery thread.
                self.registerObservers(device: device)

                continuation.resume(returning: nil)
            }
        }
    }

    /// Run a session mutation inside the ObjC exception shim (ND-054). A DAL
    /// (external/virtual) device can throw an NSException from these calls,
    /// especially during teardown after the device is yanked. Swift cannot catch
    /// that, so an unguarded call aborts the process. We catch, log via
    /// `cameraLog`, and return `false` so the caller can treat it as a non-fatal
    /// configuration failure. Must be called on `sessionQueue`.
    @discardableResult
    private func runCatching(_ label: String, _ block: @escaping () -> Void) -> Bool {
        var shimError: NSError?
        let ok = nd_runCatchingObjCException(block, &shimError)
        if !ok {
            cameraLog.error("Session.\(label, privacy: .public) threw (\(shimError?.localizedDescription ?? "unknown", privacy: .public)); treating as non-fatal")
        }
        return ok
    }

    /// ND-054: register device-disconnect + session runtime-error/interruption
    /// observers. Called on `sessionQueue` from `ensureConfigured()` on success.
    ///
    /// Disconnect (physical removal) and runtime-error (hard fault) blocks
    /// re-dispatch onto `sessionQueue` and run `teardown()` so the next
    /// `capture()` re-configures against the current default device (auto-switch
    /// to built-in), or fails safe to `.unavailable` if none.
    ///
    /// Interruption begin/end are LOG-ONLY (no teardown): on macOS the camera is
    /// multi-client and `AVCaptureSessionWasInterrupted` fires with reason
    /// `videoDeviceInUseByAnotherClient` when a video-call app grabs the camera.
    /// Tearing down there would defeat the deliberate ADR-0003 "assume present
    /// during a call, never lock mid-meeting" policy (EC-01) and could route a
    /// call into a spurious `.cameraUnavailable`. AVFoundation auto-resumes the
    /// session when the interruption ends, and the busy/assume-present path in
    /// `capture()` (`.cameraBusyNoFrames`) already handles the no-frame call case.
    private func registerObservers(device: AVCaptureDevice) {
        let nc = NotificationCenter.default

        // Disconnect: scoped to THIS device object so we only react to the
        // camera we're actually using being removed.
        let disconnect = nc.addObserver(forName: .AVCaptureDeviceWasDisconnected,
                                        object: device, queue: nil) { [weak self] _ in
            self?.sessionQueue.async {
                cameraLog.notice("Active camera disconnected; tearing down for auto-switch")
                self?.teardown()
            }
        }

        // Runtime error: the session hit a fault (e.g. the underlying device
        // vanished). Full teardown; next capture() rebuilds.
        let runtimeError = nc.addObserver(forName: .AVCaptureSessionRuntimeError,
                                          object: self.session, queue: nil) { [weak self] note in
            self?.sessionQueue.async {
                let err = note.userInfo?[AVCaptureSessionErrorKey]
                cameraLog.error("Capture session runtime error (\(String(describing: err), privacy: .public)); tearing down")
                self?.teardown()
            }
        }

        // Interruption begin/end: LOG-ONLY, no teardown (ADR-0003 / EC-01).
        // An interruption is most often `videoDeviceInUseByAnotherClient` — a
        // video-call app grabbing the camera on multi-client macOS. Tearing down
        // would defeat the assume-present-during-a-call policy and could route a
        // call into a spurious `.cameraUnavailable`. AVFoundation auto-resumes
        // when the interruption ends; the busy path in capture() covers the
        // no-frame call case. We only log the reason for diagnostics.
        // Note: `AVCaptureSessionInterruptionReasonKey` is iOS-only (unavailable
        // on macOS), so we log the interruption itself. The dominant macOS cause
        // is another client (a call) grabbing the camera — exactly the case we
        // must NOT tear down for.
        let interrupted = nc.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                         object: self.session, queue: nil) { _ in
            cameraLog.notice("Capture session interrupted (likely another client/call); log-only, not tearing down (ADR-0003)")
        }
        let interruptionEnded = nc.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                               object: self.session, queue: nil) { _ in
            cameraLog.notice("Capture session interruption ended; log-only, session auto-resumes")
        }

        self.observerTokens = [disconnect, runtimeError, interrupted, interruptionEnded]
    }

    /// ND-054: tear the session all the way down (runs on `sessionQueue`). Stop
    /// running, remove input+output, clear the cached frame, drop the retained
    /// device/input, and remove + drop every observer token so a re-configure
    /// re-registers cleanly (no duplicates, no retain cycle). Sets
    /// `configured = false` / `running = false` so the next `capture()` naturally
    /// re-runs `ensureConfigured()` → re-selects `AVCaptureDevice.default` (the
    /// built-in camera, auto-switch) or fails safe to `.unavailable` if no device.
    /// Every session mutation is wrapped in the ObjC exception shim because a
    /// yanked DAL device is exactly what throws on teardown (the ND-054 crash).
    private func teardown() {
        _ = self.runCatching("stopRunning") { self.session.stopRunning() }

        if let input = self.activeInput {
            _ = self.runCatching("beginConfiguration") { self.session.beginConfiguration() }
            _ = self.runCatching("removeInput") { self.session.removeInput(input) }
            _ = self.runCatching("removeOutput") { self.session.removeOutput(self.output) }
            _ = self.runCatching("commitConfiguration") { self.session.commitConfiguration() }
        }

        self.activeInput = nil
        self.configured = false
        self.running = false
        self.delegate.clear()

        let nc = NotificationCenter.default
        for token in self.observerTokens { nc.removeObserver(token) }
        self.observerTokens = []
    }

    /// ND-013: stop the running capture session so the camera indicator light
    /// goes OFF while the Mac is locked / display asleep / session inactive.
    /// Runs async on `sessionQueue`. Does NOT tear down inputs/outputs —
    /// `configured` stays `true` so `resume()` (or the next `capture()`) is a
    /// cheap `startRunning()`. No-op if the session isn't currently running.
    public func suspend() {
        sessionQueue.async {
            guard self.running else { return }
            // ND-054: shim the stop — a DAL device can throw here too.
            _ = self.runCatching("stopRunning") { self.session.stopRunning() }
            self.running = false
            // Drop the last live frame so the first post-resume capture() can't
            // return a stale pre-suspend frame (stale-frame false-present).
            self.delegate.clear()
        }
    }

    /// ND-013: restart the capture session after a `suspend()` (camera light back
    /// on) so the next `capture()` has frames flowing. Runs async on
    /// `sessionQueue`. No-op unless we're configured and currently stopped.
    ///
    /// resume() (called by the SessionStateMonitor on unlock/wake) is the ONLY
    /// path that restarts a suspended session — capture() never does. A
    /// launch-while-locked start (session not yet configured) is instead brought
    /// up by the first post-resume capture()'s ensureConfigured(), which is an
    /// acceptable minor first-tick delay.
    ///
    /// Self-heal note: this guards on `self.configured`. If a teardown ran while
    /// suspended (e.g. a disconnect/runtime-error fired during suspend, clearing
    /// `configured`), this resume() is a deliberate no-op — recovery instead
    /// happens on the next `capture()` tick, whose `ensureConfigured()` rebuilds
    /// against the current default device. No behavioral change needed here.
    public func resume() {
        sessionQueue.async {
            guard self.configured, !self.running else { return }
            // ND-054: shim the (re)start — a DAL device can throw here too. If it
            // throws we tear down so the next capture() rebuilds against the
            // current default device rather than leaving a half-live session.
            guard self.runCatching("startRunning", { self.session.startRunning() }) else {
                self.teardown()
                return
            }
            self.running = true
        }
    }

    /// Poll the delegate for the first delivered frame, up to `timeout` seconds.
    /// ND-054: honors the freshness guard so a stalled/removed camera can't have
    /// its lingering last buffer resurrected here.
    private func waitForFirstFrame(timeout: TimeInterval) async -> CVPixelBuffer? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let buffer = delegate.latestBuffer(maxAge: Self.staleFrameThreshold) { return buffer }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        return delegate.latestBuffer(maxAge: Self.staleFrameThreshold)
    }
}

/// Stores the most-recent pixel buffer delivered by the capture session.
/// Callbacks arrive on the session queue; reads come from `capture()` on the
/// main actor — so the shared buffer is guarded by its own lock.
private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    /// ND-054: monotonic delivery time of `buffer`, stamped in `captureOutput`.
    /// Used by `latestBuffer(maxAge:)` to reject a frame that's too old (a
    /// removed/dead camera stops delivering but the last buffer lingers). Uses
    /// `DispatchTime` (mach clock) so it isn't affected by wall-clock changes.
    private var bufferStamp: DispatchTime?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = pixelBuffer
        bufferStamp = DispatchTime.now()
        lock.unlock()
    }

    /// Return the cached frame only if it was delivered within the last `maxAge`
    /// seconds; otherwise nil (ND-054 freshness guard). A stalled session — dead
    /// or removed camera — thus reports "no frame" instead of a phantom present.
    func latestBuffer(maxAge: TimeInterval) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer, let stamp = bufferStamp else { return nil }
        let ageNanos = DispatchTime.now().uptimeNanoseconds &- stamp.uptimeNanoseconds
        let age = TimeInterval(ageNanos) / 1_000_000_000
        return age <= maxAge ? buffer : nil
    }

    /// Drop the cached frame (and its timestamp) under the lock. Called from
    /// `suspend()` / `teardown()` so a stale pre-suspend frame (e.g. the previous
    /// user's face, or the last frame from a now-removed camera) can never be
    /// returned by a later `capture()` — that would falsely report present and
    /// leave a stranger unlocked. After clear, `capture()` waits for a fresh live
    /// frame via `waitForFirstFrame`.
    func clear() {
        lock.lock()
        buffer = nil
        bufferStamp = nil
        lock.unlock()
    }
}
