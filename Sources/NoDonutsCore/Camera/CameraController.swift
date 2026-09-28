import Foundation
import AVFoundation
import IOKit.audio
import os
import ObjCExceptionCatcher

/// Camera-layer logger. os_log is safe on the session queue and never touches
/// the network / disk beyond the unified log.
private let cameraLog = Logger(subsystem: Log.subsystem, category: "camera")

/// "Now" on the host clock, in seconds. The single time base for frame
/// freshness (ND-055): monotonic mach time, immune to wall-clock changes, and
/// the clock that sample PTS are converted into. See `FrameFreshness`.
private func hostNow() -> TimeInterval {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

// Owner: blart — camera capture, camera-in-use monitoring, display/session state.
// Backlog: ND-011 (permission), ND-012 (single-frame capture), ND-013 (suspend/resume),
//          ND-031 (busy fallback), ND-055 (stale-frame guard), ND-084 (session fixes),
//          ND-075 (trust only the built-in camera; see CameraTrustPolicy),
//          ND-042 (pre-warm, per-tick timing, buffer-pinning argument),
//          ND-096 (640×480 preset + lowest frame rate; see CaptureFormatPolicy).

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
/// Camera trust (ND-075): only the Mac's built-in camera is ever opened or
/// probed (`trustedDevice()`, filtered by `CameraTrustPolicy`). External USB,
/// Continuity, and virtual cameras are ignored (logged once); with no trusted
/// device `capture()` reports `.unavailable(CameraTrustPolicy.noTrustedCameraReason)`.
///
/// Capture format (ND-096): the session asks for the 640×480 preset and the
/// device's lowest frame rate (15 fps on the built-in camera, which offers only
/// 15–30), with the device kept locked across `startRunning()` so the rate isn't
/// reset, and the actual active format / frame duration logged once per
/// configure. Both are skipped while another app shares the device, so a call's
/// stream is never throttled or downscaled by us. See `CaptureFormatPolicy`.
///
/// Pre-warm (ND-042c): `resume()` — called when enforcement turns on — configures
/// and starts the session straight away if camera access is granted, and a grant
/// that arrives later (onboarding) pre-warms if the camera was last resumed. So
/// the session is brought up outside the tick, and an unlock after a
/// launch-while-locked start no longer waits for the next `capture()`. Nothing
/// pre-warms while suspended or before the first `resume()` (paused / trusted
/// network at launch leave the camera off).
///
/// Pixel-buffer pinning (ND-042d): the delegate keeps exactly one
/// `CVPixelBuffer` (the latest), and each delivery replaces — so releases — the
/// previous one; the tick holds one more only for the length of recognition. At
/// most two pool buffers are pinned, well under the data output's pool, so the
/// pool can't be starved; no deep copy is needed (it would cost a 460 KB copy
/// per delivered frame, 15×/s, to save nothing). `captureOutput(_:didDrop:)`
/// logs an `OutOfBuffers` drop at `.notice` so on-device logs would show it if
/// that ever stops holding.
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

    /// True after `resume()` until the next `suspend()` (false at launch).
    /// Guarded by `sessionQueue`. Only a resumed camera is pre-warmed when
    /// access is granted later (ND-042c): a launch that starts paused or on a
    /// trusted network never calls `resume()`, so the grant doesn't start the
    /// camera there.
    private var resumed = false

    /// Result of `ensureConfigured`.
    private enum ConfigureResult {
        case ready
        case suspended
        case failed(String)
    }

    /// Signature of the last device set logged by `logDeviceInventory`, so
    /// the ignored-camera notice is emitted once per change, not every tick.
    /// Guarded by `sessionQueue`.
    private var loggedInventory: String?

    /// Last capture-format summary logged at `.notice` by
    /// `startRunningWithCaptureFormat`. Guarded by `sessionQueue`.
    private var lastLoggedCaptureFormat: String?

    /// Guards `_lastUnavailableReason`.
    private let reasonLock = NSLock()
    private var _lastUnavailableReason: String?
    private var _lastCaptureDuration: TimeInterval?

    /// Wall time of the most recent `capture()` call, in seconds (ND-042e), or
    /// nil before the first. Thread-safe. The loop logs it with the tick's total
    /// work time at `.debug`, so power / duty cycle can be judged from logs.
    public var lastCaptureDuration: TimeInterval? {
        reasonLock.lock()
        defer { reasonLock.unlock() }
        return _lastCaptureDuration
    }

    /// Reason from the most recent `.unavailable` outcome; nil after a
    /// successful `.frame` (and before the first capture). Thread-safe. For
    /// the UI (e.g. to explain "no trusted built-in camera").
    public var lastUnavailableReason: String? {
        reasonLock.lock()
        defer { reasonLock.unlock() }
        return _lastUnavailableReason
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
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            // ND-042c: bring the session up now rather than inside the next tick
            // — only if the camera is currently wanted (resumed, not suspended).
            if granted {
                sessionQueue.async { self.prewarmOnQueue(trigger: "camera access granted") }
            }
        }
    }

    public func capture() async -> CaptureOutcome {
        let started = hostNow()
        let outcome = await captureOutcome()
        let elapsed = hostNow() - started
        reasonLock.withLock {
            _lastCaptureDuration = elapsed
            switch outcome {
            case .unavailable(let reason): _lastUnavailableReason = reason
            case .frame: _lastUnavailableReason = nil
            default: break
            }
        }
        return outcome
    }

    private func captureOutcome() async -> CaptureOutcome {
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
            // Locked / display asleep / paused: never start the camera from
            // capture(). Report the semantically correct `.suspended` (not
            // `.unavailable`) so an in-flight tick after pause/suspend can't open a
            // stale ND-078 camera-unavailable window in the engine.
            return .suspended
        case .failed(let reason):
            // A (re)configure can fail precisely because another app holds the
            // device (e.g. a call started after a tear-down). Keep the bounded
            // busy/assume-present path (ADR-0003) instead of a plain unavailable.
            // Only the trusted device is probed (ND-075): an untrusted camera
            // being busy must not buy an assume-present window.
            if await trustedDeviceInUseByAnotherApp() {
                return .cameraBusyNoFrames
            }
            return .unavailable(reason)
        }

        // NOTE: capture() must NOT restart a stopped session. If a suspend()
        // raced in (monitor saw lock/sleep), restarting here would turn the
        // camera light back ON while locked and double per-tick overhead. A
        // suspended session is only restarted by the explicit resume() below.
        // When a suspend races in AFTER ensureConfigured returned .ready, the
        // buffer was cleared, so we fall through to waitForFreshFrame and report
        // .unavailable for this one tick (harmless: the App's suspend/pause path
        // resets the engine, which clears any unavailable window — ND-078).

        // 3. Sample the latest FRESH frame (ND-055). A stale or pre-suspend
        //    frame is never served. If none yet (session just started), wait
        //    briefly for a fresh delivery before giving up.
        if let buffer = delegate.latestFreshBuffer(now: hostNow()) {
            return .frame(CapturedFrame(pixelBuffer: buffer, captureTime: delegate.lastFrameTime()))
        }
        if let buffer = await waitForFreshFrame(timeout: 1.5) {
            return .frame(CapturedFrame(pixelBuffer: buffer, captureTime: delegate.lastFrameTime()))
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
        // ND-066b: probe the device we actually configured, not the system default.
        if await trustedDeviceInUseByAnotherApp() {
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

        logDeviceInventory()
        guard let device = trustedDevice() else {
            return .failed(CameraTrustPolicy.noTrustedCameraReason)
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

        // Another app already streaming from the device (a call): don't touch
        // its format or rate (ND-096) — both are device-wide.
        let sharedWithAnotherApp = device.isInUseByAnotherApplication
        if sharedWithAnotherApp {
            cameraLog.notice("Camera is in use by another app; not changing the session preset")
        }

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

        // ND-096: smallest preset ≥ 640×480 (CaptureFormatPolicy). Set after
        // the input is attached (canSetSessionPreset depends on it) and before
        // commit, so the device switches format once.
        if !sharedWithAnotherApp,
           let chosen = CaptureFormatPolicy.preferredPreset(isSupported: { raw in
               session.canSetSessionPreset(AVCaptureSession.Preset(rawValue: raw))
           }) {
            _ = objcSafe("setting the session preset") {
                session.sessionPreset = AVCaptureSession.Preset(rawValue: chosen)
            }
        }

        session.commitConfiguration()

        // Fresh start: nothing queued before this point may be served.
        delegate.clear(notBefore: hostNow())
        guard startRunningWithCaptureFormat(device: device, context: "configure") else {
            removeAllInputsAndOutputs()
            return .failed("cannot start camera session")
        }
        running = true
        runningSince = hostNow()
        activeDevice = device
        interruptedSince = nil
        configured = true
        cameraLog.notice("Camera: using \(device.localizedName, privacy: .public) (transport \(CameraTrustPolicy.fourCC(device.transportType), privacy: .public))")
        return .ready
    }

    /// ND-096: THE one way the session is started — by the initial configure and
    /// by `resume()`'s restart after a suspend. `stopRunning()` / `startRunning()`
    /// can drop the device back to its default format + rate (30 fps on the
    /// built-in camera), so both are re-applied on every start:
    /// lock the device → set the 640×480 format + lowest frame duration → start →
    /// unlock → log what the device actually runs at.
    ///
    /// Format + rate are skipped (device left untouched, not locked) when another
    /// app is using the camera, so a call's stream is never downscaled or throttled;
    /// that is re-evaluated at every start. Must be called on `sessionQueue`.
    /// Returns whether `startRunning()` completed without an exception.
    ///
    /// Why the device stays LOCKED across `startRunning()`: an unlocked device lets
    /// the session start reset the frame duration to the format default, and a
    /// locked device keeps its activeFormat, so the format is set explicitly too
    /// (the preset alone could leave it at the previous 1080p format).
    ///
    /// Frame rate: the range with the lowest minimum rate is chosen (not merely the
    /// first), and `targetFPS` is clamped into it; on the built-in camera that is
    /// 15 fps. Some devices (e.g. an external UVC webcam surfaced as an
    /// AVCaptureDALDevice) reject `activeVideoMin/MaxFrameDuration` / activeFormat
    /// by THROWING an NSException, which Swift cannot catch — so the CMTime is
    /// clamped into the range's own bounds and every assignment goes through the
    /// ObjC @try/@catch shim. A throwing device is non-fatal: log and continue.
    private func startRunningWithCaptureFormat(device: AVCaptureDevice, context: String) -> Bool {
        let sharedWithAnotherApp = device.isInUseByAnotherApplication
        var locked = false
        if !sharedWithAnotherApp, (try? device.lockForConfiguration()) != nil {
            locked = true
            let formats = device.formats
            if let idx = CaptureFormatPolicy.preferredFormatIndex(dimensions: formats.map {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return (Int(d.width), Int(d.height))
            }), formats[idx] != device.activeFormat {
                _ = objcSafe("setting the capture format") { device.activeFormat = formats[idx] }
            }
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            if let pick = CaptureFormatPolicy.lowestRate(in: ranges.map {
                CaptureFormatPolicy.RateRange(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
            }) {
                let range = ranges[pick.index]
                // At the range floor use the device's own CMTime (exact); else 1/fps.
                var frameDuration = pick.fps <= range.minFrameRate
                    ? range.maxFrameDuration
                    : CMTime(value: 1, timescale: CMTimeScale(pick.fps.rounded()))
                // Duration is inverse to rate: min rate -> max duration.
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
                if !ok {
                    cameraLog.notice("Device rejected a fixed frame rate (\(shimError?.localizedDescription ?? "unknown", privacy: .public)); continuing at the default rate")
                }
            }
        } else if sharedWithAnotherApp {
            cameraLog.notice("Camera is in use by another app; not changing its format or frame rate (\(context, privacy: .public))")
        }

        let started = objcSafe("starting the session (\(context))") { session.startRunning() }
        // Released on every path, after the start (see the doc comment).
        if locked { device.unlockForConfiguration() }
        guard started else { return false }

        // What the device actually runs at. `.notice` once per distinct result
        // (so a revert to 30 fps after a restart is visible), `.debug` otherwise —
        // resume() runs on every unlock/wake.
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minD = device.activeVideoMinFrameDuration.seconds
        let maxD = device.activeVideoMaxFrameDuration.seconds
        let summary = "preset \(session.sessionPreset.rawValue), active format \(dims.width)x\(dims.height), frame duration \(String(format: "%.4f", minD))–\(String(format: "%.4f", maxD))s (≈\(String(format: "%.1f", minD > 0 ? 1 / minD : 0)) fps max)"
        if summary != lastLoggedCaptureFormat {
            lastLoggedCaptureFormat = summary
            cameraLog.notice("Camera (\(context, privacy: .public)): \(summary, privacy: .public)")
        } else {
            cameraLog.debug("Camera (\(context, privacy: .public)): \(summary, privacy: .public)")
        }
        return true
    }

    // MARK: - Device trust (ND-075)

    /// The single source of capture devices: the first built-in wide-angle
    /// camera that `CameraTrustPolicy` accepts, or nil. Never falls back to
    /// `AVCaptureDevice.default(for:)`, which may be an external/virtual camera.
    private func trustedDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                         mediaType: .video,
                                         position: .unspecified)
            .devices
            .first(where: Self.isTrusted)
    }

    private static func isTrusted(_ device: AVCaptureDevice) -> Bool {
        CameraTrustPolicy.isTrusted(
            deviceTypeIsBuiltIn: device.deviceType == .builtInWideAngleCamera,
            transportIsBuiltIn: device.transportType == Int32(kIOAudioDeviceTransportTypeBuiltIn))
    }

    /// Busy probe on the configured device, else the trusted one (ND-066b).
    /// Hops onto `sessionQueue` because `activeDevice` lives there. False when
    /// no trusted camera exists, so the caller reports `.unavailable`.
    private func trustedDeviceInUseByAnotherApp() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                let device = self.activeDevice ?? self.trustedDevice()
                continuation.resume(returning: device?.isInUseByAnotherApplication == true)
            }
        }
    }

    /// Log every untrusted video device once (per change of the device set) at
    /// `.notice`, so it's visible why a plugged-in webcam or virtual camera is
    /// not used. Names + transport only; no image data. Must be called on
    /// `sessionQueue`.
    private func logDeviceInventory() {
        let all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified).devices
        let signature = all.map(\.uniqueID).sorted().joined(separator: "|")
        guard signature != loggedInventory else { return }
        loggedInventory = signature
        let untrusted = all.filter { !Self.isTrusted($0) }
        for device in untrusted {
            cameraLog.notice("Camera: ignored untrusted camera: \(device.localizedName, privacy: .public) (transport \(CameraTrustPolicy.fourCC(device.transportType), privacy: .public))")
        }
        if !all.contains(where: Self.isTrusted) {
            cameraLog.notice("Camera: \(CameraTrustPolicy.noTrustedCameraReason, privacy: .public)")
        }
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
                let inUse = (self.activeDevice ?? self.trustedDevice())?
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
            self.resumed = false
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
    /// ND-042c: a session that was never configured (launch while locked,
    /// access granted since) or was torn down is configured + started right
    /// here if access is granted, instead of waiting for the next capture().
    public func resume() {
        sessionQueue.async {
            self.suspended = false
            self.resumed = true
            self.interruptedSince = nil
            self.delegate.clear(notBefore: hostNow())
            guard self.configured else {
                self.prewarmOnQueue(trigger: "resume")
                return
            }
            guard !self.running else { return }
            // ND-096: re-apply format + frame rate on the restart (a stop/start
            // can revert the device to its 30 fps default).
            guard let device = self.activeDevice,
                  self.startRunningWithCaptureFormat(device: device, context: "resume") else {
                self.tearDownOnQueue(reason: "restart after resume failed")
                return
            }
            self.running = true
            self.runningSince = hostNow()
        }
    }

    /// ND-042c: configure + start the session ahead of the next tick. Only when
    /// the camera is wanted (`resumed`, not `suspended`), access is granted, and
    /// it isn't already configured. A failure is logged and left for the next
    /// `capture()` to retry and report honestly. Must be called on `sessionQueue`.
    private func prewarmOnQueue(trigger: String) {
        guard resumed, !suspended, !configured,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        switch configureOnQueue() {
        case .ready:
            cameraLog.info("Camera pre-warmed (\(trigger, privacy: .public))")
        case .suspended:
            break
        case .failed(let reason):
            cameraLog.info("Camera pre-warm (\(trigger, privacy: .public)) failed: \(reason, privacy: .public); the next tick retries")
        }
    }

    /// Poll the delegate for a fresh frame, up to `timeout` seconds. Returns nil
    /// promptly if the calling task is cancelled (ND-042b: the `Task.sleep` throw
    /// is caught and returns, it is not swallowed with `try?`).
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
    private var loggedOutOfBuffers = false

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

    /// ND-042d evidence hook: an `OutOfBuffers` drop means the output's pool is
    /// starved (buffers pinned too long). Logged once per clear at `.notice`;
    /// other drop reasons (e.g. `FrameWasLate`, expected with
    /// `alwaysDiscardsLateVideoFrames`) only at `.debug`.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String ?? "unknown"
        if reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) {
            lock.lock()
            let first = !loggedOutOfBuffers
            loggedOutOfBuffers = true
            lock.unlock()
            if first {
                cameraLog.notice("Camera dropped a frame: out of buffers (pixel-buffer pool starved)")
            }
        } else {
            cameraLog.debug("Camera dropped a frame: \(reason, privacy: .public)")
        }
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
        loggedOutOfBuffers = false
        lock.unlock()
    }
}
