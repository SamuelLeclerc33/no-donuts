import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import os
@preconcurrency import Vision

// Owner: cooper — ND-116 live-evidence analyzer (blink + non-rigid motion), EC-12.
// Privacy: frames are analyzed in memory on a private queue and released at once. Only
// landmark coordinates of the last ~1 s and a few numbers are kept; nothing is written
// to disk or sent anywhere. No network, ever.

/// "Now" on the host clock (seconds): the clock the camera stamps frames with (ND-055),
/// so evidence ages compare with frame times.
public func livenessHostNow() -> TimeInterval {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// Diagnostics snapshot (numbers only).
public struct LivenessDiagnostics: Sendable, Equatable {
    public var lastEvidenceAge: TimeInterval?
    public var windowAge: TimeInterval?
    public var blinks: Int
    public var motionEvents: Int
    public var framesAnalyzed: Int
    public var framesDropped: Int
    public var framesWithFace: Int
    /// Face tracks started (each discontinuity drops the previous track's evidence).
    public var tracksStarted: Int
    /// Mean / max wall time of one landmark analysis, milliseconds.
    public var meanAnalysisMs: Double?
    public var maxAnalysisMs: Double?

    /// Plain-text lines for Copy diagnostics.
    public var lines: [String] {
        func age(_ t: TimeInterval?) -> String { t.map { String(format: "%.1fs ago", $0) } ?? "never" }
        let ms = meanAnalysisMs.map { String(format: "%.1f ms mean", $0) } ?? "n/a"
        let mx = maxAnalysisMs.map { String(format: "%.1f ms max", $0) } ?? "n/a"
        return [
            "  last live evidence: \(age(lastEvidenceAge)) (window \(Int(defaultLivenessWindowSeconds))s)",
            "  window (re)started: \(age(windowAge))",
            "  blinks: \(blinks), non-rigid motion events: \(motionEvents), face tracks started: \(tracksStarted)",
            "  frames analyzed: \(framesAnalyzed) (with face: \(framesWithFace)), dropped busy: \(framesDropped)",
            "  analysis cost: \(ms), \(mx)",
        ]
    }
}

/// Receives camera frames for liveness analysis (ND-116). Called on the camera's queue:
/// implementations must return immediately (never block capture).
public protocol LiveFrameSink: AnyObject, Sendable {
    func submit(_ frame: CapturedFrame)
}

/// Live-evidence analyzer (ND-116). Evidence is bound to a continuous FACE TRACK
/// (`FaceTrack`): a discontinuity (box jump, scale jump, > 0.5 s gap) starts a new track
/// with no evidence and resets both detectors, and `currentVerdict(matchedFaceBox:)` only
/// counts the current track's evidence when the recognizer's matched box is that track.
/// Receives ~7 fps frames from `CameraController`'s
/// tap, runs `VNDetectFaceLandmarksRequest` on its own serial queue (dropping a frame
/// if the previous analysis is still running), feeds the largest face's landmarks to a
/// `BlinkDetector` and a `NonRigidMotionDetector`, and records `lastEvidence` — the
/// host time of the last blink or motion event. `currentVerdict()` applies the pure
/// `isLive` policy (60 s window + bootstrap window from `beginWindow()`).
///
/// Skips all work while anti-spoofing is off (`resolvedAntiSpoofEnabled()`): liveness is
/// part of "Reject photos of me". Turning it back on opens a fresh bootstrap window so
/// the toggle itself can't cause an instant lock.
///
/// Largest face only, like the recognizer; faces under `minimumFaceSideFraction` are
/// ignored (same quality gate). No downscale: the camera already delivers 640×480.
public final class LivenessAnalyzer: LiveFrameSink, LivenessProviding, @unchecked Sendable {
    private struct Shared {
        var busy = false
        var track = FaceTrack()
        var tracksStarted = 0
        var windowStart: TimeInterval?
        var blinks = 0
        var motionEvents = 0
        var analyzed = 0
        var withFace = 0
        var dropped = 0
        var totalMs = 0.0
        var maxMs = 0.0
        var wasEnabled: Bool?
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "com.nodonuts.liveness", qos: .utility)
    private let log = Logger(subsystem: Log.subsystem, category: "liveness")
    private let window: TimeInterval
    private let antiSpoofEnabled: @Sendable () -> Bool

    // Touched ONLY on `queue` (one analysis at a time).
    private var blink = BlinkDetector()
    private var motion = NonRigidMotionDetector()
    private var periodStart: TimeInterval = 0
    private var periodMaxMotionRatio = 0.0

    public init(window: TimeInterval = defaultLivenessWindowSeconds,
                antiSpoofEnabled: @escaping @Sendable () -> Bool = { resolvedAntiSpoofEnabled() }) {
        self.window = window
        self.antiSpoofEnabled = antiSpoofEnabled
    }

    /// Open a bootstrap window (enforcement started / resumed). Also ends the face track
    /// and drops the detectors' history (the frames before a suspend are another moment).
    public func beginWindow() {
        let now = livenessHostNow()
        shared.withLock { $0.windowStart = now; $0.track.end() }
        queue.async { [self] in blink.reset(); motion.reset() }
    }

    public func currentVerdict(matchedFaceBox: CGRect?) -> LivenessVerdict {
        let now = livenessHostNow()
        return shared.withLock {
            LivenessVerdict.evaluate(now: now, track: $0.track, matchedBox: matchedFaceBox,
                                     windowStart: $0.windowStart, window: window)
        }
    }

    public func diagnostics() -> LivenessDiagnostics {
        let now = livenessHostNow()
        return shared.withLock { s in
            LivenessDiagnostics(
                lastEvidenceAge: s.track.evidenceAt.map { max(0, now - $0) },
                windowAge: s.windowStart.map { max(0, now - $0) },
                blinks: s.blinks, motionEvents: s.motionEvents,
                framesAnalyzed: s.analyzed, framesDropped: s.dropped, framesWithFace: s.withFace,
                tracksStarted: s.tracksStarted,
                meanAnalysisMs: s.analyzed > 0 ? s.totalMs / Double(s.analyzed) : nil,
                maxAnalysisMs: s.analyzed > 0 ? s.maxMs : nil)
        }
    }

    // MARK: LiveFrameSink

    public func submit(_ frame: CapturedFrame) {
        guard frame.pixelBuffer != nil, let time = frame.captureTime else { return }
        let enabled = antiSpoofEnabled()
        let accept: Bool = shared.withLock { s in
            // Off → on: a fresh bootstrap window, so flipping the toggle can't lock at once.
            if enabled, s.wasEnabled == false { s.windowStart = time }
            s.wasEnabled = enabled
            guard enabled else { return false }
            if s.busy { s.dropped += 1; return false }
            s.busy = true
            return true
        }
        guard accept else { return }
        queue.async { [self] in
            autoreleasepool { analyze(frame, time: time) }
            shared.withLock { $0.busy = false }
        }
    }

    // MARK: Analysis (on `queue`)

    private func analyze(_ frame: CapturedFrame, time: TimeInterval) {
        guard let buffer = frame.pixelBuffer else { return }
        let started = livenessHostNow()
        let sample = landmarks(in: buffer)
        let ms = (livenessHostNow() - started) * 1000
        shared.withLock { s in
            s.analyzed += 1
            if sample != nil { s.withFace += 1 }
            s.totalMs += ms
            s.maxMs = max(s.maxMs, ms)
        }
        guard let sample else { return }

        // Track continuity first: a new track owns no evidence, and history from the
        // previous face must never feed this one's blink baseline / motion references.
        let continued = shared.withLock { s -> Bool in
            let c = s.track.observe(box: sample.box, interOcular: sample.interOcular, time: time)
            if !c { s.tracksStarted += 1 }
            return c
        }
        if !continued {
            blink.reset(); motion.reset()
            log.debug("liveness: new face track (discontinuity) — evidence reset")
        }

        var evidence: String?
        if let l = sample.leftOpenness, let r = sample.rightOpenness {
            if let e = blink.ingest(time: time, left: l, right: r) {
                evidence = "blink"
                log.debug("liveness: blink (closed \(e.closedDuration * 1000, format: .fixed(precision: 0), privacy: .public) ms, min ratio \(e.minRatio, format: .fixed(precision: 2), privacy: .public))")
                shared.withLock { $0.blinks += 1 }
            }
        }
        if let m = motion.ingest(time: time, points: sample.points, interOcular: sample.interOcular) {
            periodMaxMotionRatio = max(periodMaxMotionRatio, m.score / max(m.requiredScore, 1e-9))
            if m.event {
                evidence = evidence ?? "motion"
                log.debug("liveness: non-rigid motion (score \(m.score, format: .fixed(precision: 4), privacy: .public) > required \(m.requiredScore, format: .fixed(precision: 4), privacy: .public), floor \(m.noiseFloor, format: .fixed(precision: 4), privacy: .public), lag \(m.lag, format: .fixed(precision: 2), privacy: .public)s)")
                shared.withLock { $0.motionEvents += 1 }
            }
        }
        if evidence != nil {
            shared.withLock { $0.track.recordEvidence(at: time) }
        }

        // Tuning summary every 30 s (numbers only): how close the signals came.
        if time - periodStart >= 30 {
            let d = diagnostics()
            log.info("liveness summary: blinks \(d.blinks, privacy: .public), motion \(d.motionEvents, privacy: .public), peak motion/required \(self.periodMaxMotionRatio, format: .fixed(precision: 2), privacy: .public), jitter floor \(self.motion.noiseFloor ?? -1, format: .fixed(precision: 4), privacy: .public), analysis \(d.meanAnalysisMs ?? -1, format: .fixed(precision: 1), privacy: .public) ms mean / \(d.maxAnalysisMs ?? -1, format: .fixed(precision: 1), privacy: .public) max, dropped \(d.framesDropped, privacy: .public)")
            periodStart = time
            periodMaxMotionRatio = 0
        }
    }

    private struct Sample {
        let box: CGRect
        let points: [LandmarkXY]
        let interOcular: Double
        let leftOpenness: Double?
        let rightOpenness: Double?
    }

    /// Landmarks of the largest face, in oriented pixels. `nil` = no usable face / error
    /// (no evidence either way; the detectors' gap handling copes).
    private func landmarks(in buffer: CVPixelBuffer) -> Sample? {
        let orientation = resolvedVisionOrientation()
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let faces = request.results,
              let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                          < $1.boundingBox.width * $1.boundingBox.height }),
              let lm = face.landmarks else { return nil }

        var w = Double(CVPixelBufferGetWidth(buffer)), h = Double(CVPixelBufferGetHeight(buffer))
        if orientation.rawValue >= 5 { swap(&w, &h) }          // .leftMirrored ... .left rotate 90°
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        guard faceIsLargeEnough(faceBoundingBox: face.boundingBox, orientedExtent: extent) else { return nil }
        let size = CGSize(width: w, height: h)
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [LandmarkXY] {
            region?.pointsInImage(imageSize: size).map { LandmarkXY(Double($0.x), Double($0.y)) } ?? []
        }
        let all = pts(lm.allPoints)
        let left = pts(lm.leftEye), right = pts(lm.rightEye)
        guard all.count >= 6, let iod = interOcularDistance(leftEye: left, rightEye: right) else { return nil }
        let scale = faceVerticalScale(leftEye: left, rightEye: right, lips: pts(lm.outerLips))
        return Sample(box: face.boundingBox, points: all, interOcular: iod,
                      leftOpenness: scale.flatMap { eyeOpenness(eye: left, faceVerticalScale: $0) },
                      rightOpenness: scale.flatMap { eyeOpenness(eye: right, faceVerticalScale: $0) })
    }
}
