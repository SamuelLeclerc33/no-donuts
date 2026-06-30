import Foundation
import AVFoundation

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
        if let buffer = delegate.latestBuffer() {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }
        if let buffer = await waitForFirstFrame(timeout: 1.5) {
            return .frame(CapturedFrame(pixelBuffer: buffer))
        }
        return .unavailable("no frame")

        // TODO(blart): ND-031/ND-032 — detect when another app holds the camera and
        //   attempt multi-client shared frames; on failure emit .cameraBusyNoFrames (ADR-0003).
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

                guard let device = AVCaptureDevice.default(for: .video) else {
                    continuation.resume(returning: "no camera device")
                    return
                }

                self.session.beginConfiguration()

                guard let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    continuation.resume(returning: "cannot open camera input")
                    return
                }
                self.session.addInput(input)

                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self.delegate, queue: self.sessionQueue)
                guard self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    continuation.resume(returning: "cannot add camera output")
                    return
                }
                self.session.addOutput(self.output)

                self.session.commitConfiguration()

                // Low frame rate where supported — we only need ~1 frame per tick.
                // Aim for ~1 fps, clamped into the format's supported range. Only
                // set the duration if 1 fps actually fits the range; otherwise
                // leave the device defaults alone.
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
                   (try? device.lockForConfiguration()) != nil {
                    let targetFPS = min(max(1.0, range.minFrameRate), range.maxFrameRate)
                    let frameDuration = CMTime(value: 1,
                                               timescale: CMTimeScale(targetFPS.rounded()))
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                    device.unlockForConfiguration()
                }

                self.session.startRunning()
                self.running = true
                self.configured = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// ND-013: stop the running capture session so the camera indicator light
    /// goes OFF while the Mac is locked / display asleep / session inactive.
    /// Runs async on `sessionQueue`. Does NOT tear down inputs/outputs —
    /// `configured` stays `true` so `resume()` (or the next `capture()`) is a
    /// cheap `startRunning()`. No-op if the session isn't currently running.
    public func suspend() {
        sessionQueue.async {
            guard self.running else { return }
            self.session.stopRunning()
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
    public func resume() {
        sessionQueue.async {
            guard self.configured, !self.running else { return }
            self.session.startRunning()
            self.running = true
        }
    }

    /// Poll the delegate for the first delivered frame, up to `timeout` seconds.
    private func waitForFirstFrame(timeout: TimeInterval) async -> CVPixelBuffer? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let buffer = delegate.latestBuffer() { return buffer }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        return delegate.latestBuffer()
    }
}

/// Stores the most-recent pixel buffer delivered by the capture session.
/// Callbacks arrive on the session queue; reads come from `capture()` on the
/// main actor — so the shared buffer is guarded by its own lock.
private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = pixelBuffer
        lock.unlock()
    }

    func latestBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Drop the cached frame under the lock. Called from `suspend()` so a stale
    /// pre-suspend frame (e.g. the previous user's face) can never be returned by
    /// the first post-resume `capture()` — that would falsely report present and
    /// leave a stranger unlocked. After clear, `capture()` waits for a fresh live
    /// frame via `waitForFirstFrame`.
    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}
