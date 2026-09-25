import Foundation
import AVFoundation
import os
import ObjCExceptionCatcher

/// Camera-layer logger. os_log is safe on the session queue and never touches
/// the network / disk beyond the unified log.
private let cameraLog = Logger(subsystem: "com.nodonuts.app", category: "camera")

/// "Now" on the host clock, in seconds. The single time base for frame
/// freshness (ND-055): monotonic mach time, immune to wall-clock changes, and
/// the clock that sample PTS are converted into. See `FrameFreshness`.
private func hostNow() -> TimeInterval {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

// Owner: blart — camera capture, camera-in-use monitoring, display/session state.
// Backlog: ND-011 (permission), ND-012 (single-frame capture), ND-013 (suspend/resume),
//          ND-031 (busy fallback), ND-055 (stale-frame guard), ND-084 (session fixes).

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
/// (`sessionQueue` for configuration/start/tear-down, `bufferLock` for the
/// shared buffer). Nothing mutable is touched without that synchronization.
///
/// Suspend/resume (ND-013): when the Mac is locked, the display sleeps, or the
/// session goes inactive, the orchestrator calls `suspend()` to stop the running
/// capture session — which turns the camera indicator light OFF — without tearing
/// down inputs/outputs, so `resume()` is a cheap `startRunning()`. The camera
/// light follows the session's running state: light is on iff the session is
/// running. `configured` stays `true` across a suspend/resume cycle; the `running`
/// flag (guarded by `sessionQueue`) tracks whether the session is currently live.
///
/// Stale-frame guard (ND-055): every cached frame carries a host-clock
/// timestamp and is only served while `FrameFreshness.isFresh`. If frames stop
/// arriving (unplugged camera, runtime error, wedged DAL/virtual device) the
/// controller reports honest `.cameraBusyNoFrames` / `.unavailable` instead of
/// replaying the last good frame forever. A disconnect, a runtime error, or a
/// wedged session (no fresh frame for `FrameFreshness.wedgedAfter`) tears the
/// session down so the next tick reconfigures. Interruptions (e.g. another app
/// taking the camera for a call) are logged only — never torn down (ADR-0003).
///
/// Privacy: frames live in memory only. We hand the `CVPixelBuffer` to the
/// recognizer and never write it to disk or off-device.
public final class CameraController: CameraCapturing, @unchecked Sendable {
    /// Serial queue owning session configuration/start and the delegate callbacks.
    private let sessionQueue = DispatchQueue(label: "com.nodonuts.camera.session")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let delegate: SampleBufferDelegate

    /// True once the session has been configured + started successfully.
    /// Guarded by `sessionQueue`. On a configuration failure (or a tear-down)
    /// this is `false` so the next `capture()` reconfigures — a transient hiccup
    /// must not permanently disable the camera for the whole process.
    private var configured = false

    /// True while the capture session is running (camera light ON). Guarded by
    /// `sessionQueue`. Goes `true` after `session.startRunning()` and `false`
    /// after `session.stopRunning()`, so `capture()`/`resume()` can tell whether
    /// the session needs (re)starting after a `suspend()`.
    private var running = false

    /// Host-clock time of the last `startRunning()`. Guarded by `sessionQueue`.
    /// Baseline for wedged detection so a just-(re)started session gets the
    /// full `wedgedAfter` window.
    private var runningSince: TimeInterval = 0

    /// The device currently attached as input. Its `uniqueID` filters
    /// disconnect notifications (another device's disconnect is ignored), and
    /// its `isInUseByAnotherApplication` gates wedged tear-down. Guarded by
    /// `sessionQueue`.
    private var activeDevice: AVCaptureDevice?

    /// Host-clock time of the last `wasInterrupted` notification, nil once it
    /// ended / on suspend / resume / tear-down. Guarded by `sessionQueue`.
    /// Only defers wedged tear-down for a bounded window (see
    /// `FrameFreshness.shouldTearDownWedged`): `interruptionEnded` isn't
    /// guaranteed, so this flag is never trusted on its own.
    private var interruptedSince: TimeInterval?

    /// True between `suspend()` and `resume()`. Guarded by `sessionQueue`.
    /// While suspended nothing but `resume()` may start the session — in
    /// particular `ensureConfigured` (after a tear-down, or on a launch while
    /// locked) must not turn the camera on behind the lock screen.
    private var suspended = false

    /// Result of `ensureConfigured`.
    private enum ConfigureResult {
        case ready
        case suspended
        case failed(String)
    }

    /// NotificationCenter tokens; removed in `deinit`.
    private var observers: [NSObjectProtocol] = []

    public init() {
        let session = self.session
        // The delegate converts sample PTS from the session's synchronization
        // clock into the host clock. Only ever called on `sessionQueue`.
        delegate = SampleBufferDelegate(clockProvider: { [weak session] in
            session?.synchronizationClock
        })
        installObservers()
    }

    deinit {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
    }

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
        //    authorized call (or after a tear-down). Returns a reason string on
        //    failure, nil on success.
        switch await ensureConfigured() {
        case .ready:
            break
        case .suspended:
            // Locked / display asleep: never start the camera from capture().
            return .unavailable("camera suspended")
        case .failed(let reason):
            // A (re)configure can fail precisely because another app holds the
            // device (e.g. a call started after a tear-down). Keep the bounded
            // busy/assume-present path (ADR-0003) instead of a plain unavailable.
            if AVCaptureDevice.default(for: .video)?.isInUseByAnotherApplication == true {
                return .cameraBusyNoFrames
            }
            return .unavailable(reason)
        }

        // NOTE: capture() must NOT restart a stopped session. If a suspend()
        // raced in (monitor saw lock/sleep), restarting here would turn the
        // camera light back ON while locked and double per-tick overhead. A
        // suspended session is only restarted by the explicit resume() below.
        // When suspended, the buffer was cleared, so we fall through to
        // waitForFreshFrame and then report .unavailable — correct.

        // 3. Sample the latest FRESH frame (ND-055). A stale or pre-suspend
        //    frame is never served. If none yet (session just started), wait
        //    briefly for a fresh delivery before giving up.
        if let buffer = delegate.latestFreshBuffer(now: hostNow()) {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }
        if let buffer = await waitForFreshFrame(timeout: 1.5) {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }

        // 4. No fresh frame. If the session has been running without delivering
        //    for too long, tear it down so the NEXT tick reconfigures (picks up
        //    a replacement device, clears a wedged DAL pipeline). This tick still
        //    reports honestly below.
        await tearDownIfWedged()

        // macOS camera is multi-client: during a call our session usually still gets
        // frames (handled above → normal recognition). We only get here with NO
        // fresh frame. If another app holds the camera, treat it as a busy call →
        // assume present (ADR-0003); otherwise it's genuinely unavailable.
        //
        // `isInUseByAnotherApplication` is the documented macOS "busy" signal. It's
        // imperfect (timing-sensitive, not guaranteed exhaustive) — verify on-device.
        // The bounded assume-present policy (e.g. a max-duration guard so we don't
        // stay unlocked forever behind a stuck call) lives in the engine (homer), not
        // here; this controller only reports the raw outcome.
        if AVCaptureDevice.default(for: .video)?.isInUseByAnotherApplication == true {
            return .cameraBusyNoFrames   // ND-031/ADR-0003: busy + no frames
        }
        return .unavailable("no fresh frame")
    }

    // MARK: - Configuration

    /// Runs `body` inside the ObjC @try/@catch shim. AVFoundation session
    /// mutations can raise NSException (notably DAL devices — EC-21), which
    /// Swift cannot catch. Returns false (and logs) on an exception.
    private func objcSafe(_ what: String, _ body: () -> Void) -> Bool {
        var shimError: NSError?
        let ok = nd_runCatchingObjCException(body, &shimError)
        if !ok {
            cameraLog.notice("Camera: \(what, privacy: .public) raised an exception (\(shimError?.localizedDescription ?? "unknown", privacy: .public))")
        }
        return ok
    }

    /// Configure inputs/outputs and start the session once. Runs on `sessionQueue`
    /// so all session mutation is serialized. Returns a failure reason, or nil on
    /// success. On success `configured` is set so future calls short-circuit; on
    /// failure every input/output added in this attempt is removed again (ND-084b)
    /// and `configured` is left `false`, so the next `capture()` retries cleanly.
    private func ensureConfigured() async -> ConfigureResult {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.configureOnQueue())
            }
        }
    }

    /// Body of `ensureConfigured`. Must be called on `sessionQueue`.
    private func configureOnQueue() -> ConfigureResult {
        if configured { return .ready }
        // ND-013 invariant: only resume() starts a suspended session.
        if suspended { return .suspended }

        guard let device = AVCaptureDevice.default(for: .video) else {
            return .failed("no camera device")
        }

        // Defensive: a previous partial attempt/tear-down should have left the
        // session empty, but make sure a leftover input/output can't make
        // canAddInput/canAddOutput fail forever (ND-084b).
        removeAllInputsAndOutputs()

        var input: AVCaptureDeviceInput?
        let inputOK = objcSafe("opening the camera input") {
            input = try? AVCaptureDeviceInput(device: device)
        }
        guard inputOK, let input else { return .failed("cannot open camera input") }

        session.beginConfiguration()

        guard session.canAddInput(input),
              objcSafe("adding the camera input", { session.addInput(input) }),
              session.inputs.contains(input) else {
            session.commitConfiguration()
            removeAllInputsAndOutputs()
            return .failed("cannot open camera input")
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: sessionQueue)
        guard session.canAddOutput(output),
              objcSafe("adding the camera output", { session.addOutput(output) }),
              session.outputs.contains(output) else {
            // ND-084b: roll back the input we just added, otherwise every retry
            // fails canAddInput until the app restarts.
            _ = objcSafe("rolling back the camera input") { session.removeInput(input) }
            session.commitConfiguration()
            removeAllInputsAndOutputs()
            return .failed("cannot add camera output")
        }

        // Make the frames deterministic for recognition. A mirror flip
        // changes the pixels -> a different Vision feature-print embedding
        // -> identity mismatch, so mirroring must be OFF and fixed. The
        // connection exists once the output is added to the session; guard
        // every set with its `is…Supported` check so we never crash on a
        // connection that doesn't support mirroring. Never force-unwrap: if
        // the connection is nil at this point, skip silently and log.
        //
        // We deliberately do NOT rotate/repipeline (no videoRotationAngle /
        // videoOrientation): the built-in Mac camera delivers landscape-
        // upright, non-mirrored frames after this, so Vision `.up` is the
        // correct default and rotating would add CPU cost + risk. cooper's
        // overridable Vision orientation (recognition-orientation follow-up)
        // covers atypical external cameras.
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                _ = objcSafe("configuring mirroring") {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
        } else {
            cameraLog.info("No video connection on the data output; skipping deterministic mirroring config")
        }

        session.commitConfiguration()

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
        //
        // Skipped when another app already holds the device (a call): locking
        // it and forcing 1 fps would throttle the call app's shared stream.
        // We then run at the device default until the next reconfigure.
        let sharedWithAnotherApp = device.isInUseByAnotherApplication
        if sharedWithAnotherApp {
            cameraLog.notice("Camera is in use by another app; not forcing a fixed frame rate")
        }
        if !sharedWithAnotherApp,
           let range = device.activeFormat.videoSupportedFrameRateRanges.first,
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

        // Fresh start: nothing queued before this point may be served.
        delegate.clear(notBefore: hostNow())
        guard objcSafe("starting the session", { session.startRunning() }) else {
            removeAllInputsAndOutputs()
            return .failed("cannot start camera session")
        }
        running = true
        runningSince = hostNow()
        activeDevice = device
        interruptedSince = nil
        configured = true
        return .ready
    }

    // MARK: - Tear-down (ND-055)

    /// Remove every input and output from the session. Must be called on
    /// `sessionQueue`. Idempotent; each removal goes through the ObjC shim.
    private func removeAllInputsAndOutputs() {
        guard !session.inputs.isEmpty || !session.outputs.isEmpty else { return }
        session.beginConfiguration()
        for input in session.inputs {
            _ = objcSafe("removing a camera input") { session.removeInput(input) }
        }
        for out in session.outputs {
            _ = objcSafe("removing a camera output") { session.removeOutput(out) }
        }
        session.commitConfiguration()
    }

    /// Fully tear the session down so the next `capture()` reconfigures from
    /// scratch: stop, remove all inputs/outputs, reset flags, drop the cached
    /// frame. Must be called on `sessionQueue`. Idempotent.
    private func tearDownOnQueue(reason: String) {
        let wasConfigured = configured || running
            || !session.inputs.isEmpty || !session.outputs.isEmpty
        if session.isRunning {
            _ = objcSafe("stopping the session") { session.stopRunning() }
        }
        removeAllInputsAndOutputs()
        configured = false
        running = false
        interruptedSince = nil
        activeDevice = nil
        delegate.clear(notBefore: hostNow())
        if wasConfigured {
            cameraLog.notice("Camera session torn down: \(reason, privacy: .public); will reconfigure on the next tick")
        }
    }

    /// If the session is running but has delivered no fresh frame for
    /// `FrameFreshness.wedgedAfter`, tear it down — unless another app holds
    /// the device or a recent interruption is in effect (ADR-0003: a call
    /// holding the camera is not a wedged session; see
    /// `FrameFreshness.shouldTearDownWedged`).
    private func tearDownIfWedged() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                defer { continuation.resume() }
                guard self.running else { return }
                let now = hostNow()
                let wedged = FrameFreshness.isWedged(lastFrameTime: self.delegate.lastFrameTime(),
                                                     runningSince: self.runningSince,
                                                     now: now)
                guard wedged else { return }
                // Re-derive "in a call" from the device itself rather than
                // trusting the interruption notification alone.
                let inUse = (self.activeDevice ?? AVCaptureDevice.default(for: .video))?
                    .isInUseByAnotherApplication == true
                guard FrameFreshness.shouldTearDownWedged(isWedged: wedged,
                                                          deviceInUseByAnotherApp: inUse,
                                                          interruptedSince: self.interruptedSince,
                                                          now: now) else { return }
                self.tearDownOnQueue(reason: "wedged (no fresh frame for \(Int(FrameFreshness.wedgedAfter))s while running)")
            }
        }
    }

    // MARK: - Lifecycle observers (ND-055)

    /// Observe runtime errors and device disconnects (→ tear-down) and
    /// interruptions (→ log only, ADR-0003). Handlers hop onto `sessionQueue`.
    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let detail = error.map { "\($0.domain) \($0.code)" } ?? "unknown error"
            self?.onSessionQueue { controller in
                controller.tearDownOnQueue(reason: "runtime error (\(detail))")
            }
        })

        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                            object: nil, queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let id = device.uniqueID
            self?.onSessionQueue { controller in
                guard controller.activeDevice?.uniqueID == id else { return }
                controller.tearDownOnQueue(reason: "active camera disconnected")
            }
        })

        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            // LOG ONLY. Never tear down on an interruption: during a call the
            // camera may be held by another client, and ADR-0003 says assume
            // present, not reconfigure-churn.
            self?.onSessionQueue { controller in
                controller.interruptedSince = hostNow()
                cameraLog.notice("Camera session interrupted (e.g. device in use by another client); not tearing down")
            }
        })

        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.onSessionQueue { controller in
                controller.interruptedSince = nil
                // Restart the wedged-detection window from the end of the interruption.
                if controller.running { controller.runningSince = hostNow() }
                cameraLog.notice("Camera session interruption ended")
            }
        })
    }

    /// Run `body` on `sessionQueue` with a weakly-held controller.
    private func onSessionQueue(_ body: @escaping @Sendable (CameraController) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    // MARK: - Suspend / resume (ND-013)

    /// ND-013: stop the running capture session so the camera indicator light
    /// goes OFF while the Mac is locked / display asleep / session inactive.
    /// Runs async on `sessionQueue`. Does NOT tear down inputs/outputs —
    /// `configured` stays `true` so `resume()` is a cheap `startRunning()`.
    /// Always clears the cached frame with a `notBefore` stamp (ND-084a), even
    /// when not running, so a frame already queued on the delegate can't land
    /// after the clear and be served by the first post-resume `capture()`.
    /// Sets `suspended`, so no `capture()` (in-flight tick, enrollment, or a
    /// reconfigure after a tear-down) can start the camera until `resume()` —
    /// this also closes the "camera starts behind the lock screen" gap noted
    /// under ND-096 (a launch while locked calls suspend() first).
    public func suspend() {
        sessionQueue.async {
            self.suspended = true
            self.interruptedSince = nil
            if self.running {
                _ = self.objcSafe("stopping the session") { self.session.stopRunning() }
                self.running = false
            }
            self.delegate.clear(notBefore: hostNow())
        }
    }

    /// ND-013: restart the capture session after a `suspend()` (camera light back
    /// on) so the next `capture()` has frames flowing. Runs async on
    /// `sessionQueue`. Clears with `notBefore` first (ND-084a) so only frames
    /// captured after the restart can be served.
    ///
    /// resume() (called by the SessionStateMonitor on unlock/wake) is the ONLY
    /// path that restarts a suspended session — capture() never does
    /// (`ensureConfigured` returns `.suspended` until resume() clears the flag).
    /// A session that was never configured (launch while locked) or was torn
    /// down is brought up by the first post-resume capture()'s
    /// ensureConfigured(), which is an acceptable minor first-tick delay.
    public func resume() {
        sessionQueue.async {
            self.suspended = false
            self.interruptedSince = nil
            self.delegate.clear(notBefore: hostNow())
            guard self.configured, !self.running else { return }
            guard self.objcSafe("restarting the session", { self.session.startRunning() }) else {
                self.tearDownOnQueue(reason: "restart after resume failed")
                return
            }
            self.running = true
            self.runningSince = hostNow()
        }
    }

    /// Poll the delegate for a fresh frame, up to `timeout` seconds. Returns nil
    /// promptly if the calling task is cancelled.
    private func waitForFreshFrame(timeout: TimeInterval) async -> CVPixelBuffer? {
        let deadline = hostNow() + timeout
        while hostNow() < deadline {
            if Task.isCancelled { return nil }
            if let buffer = delegate.latestFreshBuffer(now: hostNow()) { return buffer }
            do {
                try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            } catch {
                return nil   // cancelled
            }
        }
        return delegate.latestFreshBuffer(now: hostNow())
    }
}

/// Stores the most-recent pixel buffer delivered by the capture session,
/// stamped with a host-clock time (ND-055). Callbacks arrive on the session
/// queue; reads come from `capture()` on the main actor — so the shared state
/// is guarded by its own lock.
///
/// Timestamp choice: the sample's presentation timestamp, converted from the
/// session's synchronization clock into the host clock, capped at the arrival
/// time (a frame can't be newer than when we received it). If the PTS or the
/// clock is unusable, the host-clock arrival time is used. Either way the value
/// is comparable with `hostNow()`.
private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var frameTime: TimeInterval?
    private var notBefore: TimeInterval?
    private var loggedStaleArrival = false

    /// Returns the session's synchronization clock. Called on the session queue.
    private let clockProvider: () -> CMClock?

    init(clockProvider: @escaping () -> CMClock?) {
        self.clockProvider = clockProvider
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let arrival = hostNow()
        let stamp = Self.hostTime(of: sampleBuffer, clock: clockProvider(), arrival: arrival)

        lock.lock()
        defer { lock.unlock() }
        // ND-084a: a frame captured before the last clear (suspend/resume/
        // tear-down) is dropped, even if it's delivered afterwards.
        if let notBefore, stamp < notBefore { return }
        if !FrameFreshness.isFresh(frameTime: stamp, now: arrival, notBefore: nil),
           !loggedStaleArrival {
            loggedStaleArrival = true
            cameraLog.notice("Camera delivered a frame that is already stale on arrival (age \(arrival - stamp, format: .fixed(precision: 2), privacy: .public)s); it will not be used")
        }
        buffer = pixelBuffer
        frameTime = stamp
    }

    private static func hostTime(of sampleBuffer: CMSampleBuffer,
                                 clock: CMClock?,
                                 arrival: TimeInterval) -> TimeInterval {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric, let clock else { return arrival }
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard host.isValid, host.isNumeric else { return arrival }
        let seconds = host.seconds
        guard seconds.isFinite else { return arrival }
        return min(seconds, arrival)
    }

    /// The cached frame iff it is fresh at `now`; nil otherwise. Never returns
    /// a stale frame (ND-055: never fail open).
    func latestFreshBuffer(now: TimeInterval) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer, let frameTime,
              FrameFreshness.isFresh(frameTime: frameTime, now: now, notBefore: notBefore) else {
            return nil
        }
        return buffer
    }

    /// Host-clock time of the last accepted frame, or nil since the last clear.
    func lastFrameTime() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return frameTime
    }

    /// Drop the cached frame and refuse any frame stamped before `notBefore`.
    /// Called from `suspend()`/`resume()`/tear-down so a stale pre-suspend frame
    /// (e.g. the previous user's face) can never be returned — that would
    /// falsely report present and leave a stranger unlocked. After clear,
    /// `capture()` waits for a fresh live frame via `waitForFreshFrame`.
    func clear(notBefore: TimeInterval) {
        lock.lock()
        buffer = nil
        frameTime = nil
        self.notBefore = notBefore
        loggedStaleArrival = false
        lock.unlock()
    }
}
