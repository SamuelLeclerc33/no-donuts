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
    /// Seconds since the startup window was armed (enforcement (re)start).
    public var windowAge: TimeInterval?
    /// Seconds since the startup window STARTED (first analyzed face, ND-118a); `nil` =
    /// no face analyzed since it was armed.
    public var windowFaceAge: TimeInterval? = nil
    public var blinks: Int
    public var motionEvents: Int
    public var framesAnalyzed: Int
    public var framesDropped: Int
    public var framesWithFace: Int
    /// Face tracks started (each discontinuity drops the previous track's evidence).
    public var tracksStarted: Int
    /// Track handoffs: fresh probations issued / probations inherited (FaceTracker).
    public var freshHandoffs: Int = 0
    public var inheritedHandoffs: Int = 0
    /// Verdicts that returned NOT live (each = one `.notLive` recognition tick).
    public var notLiveTicks: Int = 0
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
            "  startup window: armed \(age(windowAge)), first face \(age(windowFaceAge))",
            "  blinks: \(blinks), non-rigid motion events: \(motionEvents), not-live ticks: \(notLiveTicks)",
            "  face tracks started: \(tracksStarted), handoffs: \(freshHandoffs) fresh / \(inheritedHandoffs) inherited",
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
/// (`FaceTracker`): a discontinuity (box jump, scale jump, > 1 s gap) starts a new track
/// with no evidence and resets both detectors, and `currentVerdict(matchedFaceBox:)` only
/// counts the current track's evidence when the recognizer's matched box is that track.
/// Receives ~7 fps frames from `CameraController`'s
/// tap, runs `VNDetectFaceLandmarksRequest` on its own serial queue (dropping a frame
/// if the previous analysis is still running), feeds the largest face's landmarks to a
/// `BlinkDetector` and a `NonRigidMotionDetector`, and records `lastEvidence` — the
/// host time of the last blink or motion event. `currentVerdict()` applies the pure
/// `isLive` policy (60 s window + a bootstrap window that starts at the first analyzed
/// face after `beginWindow()`, ND-118a — `LivenessStartWindow`).
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
        var tracker = FaceTracker()
        var startWindow = LivenessStartWindow()
        var notLiveTicks = 0
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
    private var periodStart: TimeInterval?
    private var periodMaxMotionRatio = 0.0
    private var periodBase = PeriodCounts()
    /// Summary cadence (ND-118b): one persisted line per this many seconds of frames.
    static let summaryInterval: TimeInterval = 60
    /// One landmarks request reused for every frame (queue-confined). Measured on the
    /// dev Mac at 7 fps pacing, `.utility`: ~7 ms median vs ~9 ms with a fresh request.
    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    public init(window: TimeInterval = defaultLivenessWindowSeconds,
                antiSpoofEnabled: @escaping @Sendable () -> Bool = { resolvedAntiSpoofEnabled() }) {
        self.window = window
        self.antiSpoofEnabled = antiSpoofEnabled
    }

    /// Arm a bootstrap window (enforcement started / resumed). It STARTS at the first
    /// analyzed face after this call (ND-118a) and never restarts until the next call.
    /// Also ends the face track and drops the detectors' history (the frames before a
    /// suspend are another moment).
    public func beginWindow() {
        let now = livenessHostNow()
        shared.withLock { $0.startWindow.begin(at: now); $0.tracker.end() }
        queue.async { [self] in blink.reset(); motion.reset() }
    }

    public func currentVerdict(matchedFaceBox: CGRect?) -> LivenessVerdict {
        let now = livenessHostNow()
        return shared.withLock { s in
            s.tracker.window = window
            let v = s.tracker.verdict(now: now, matchedBox: matchedFaceBox, windowStart: s.startWindow.start)
            if !v.live { s.notLiveTicks += 1 }
            return v
        }
    }

    public func diagnostics() -> LivenessDiagnostics {
        let now = livenessHostNow()
        return shared.withLock { s in
            LivenessDiagnostics(
                lastEvidenceAge: s.tracker.current?.evidenceAt.map { max(0, now - $0) },
                windowAge: s.startWindow.armedAt.map { max(0, now - $0) },
                windowFaceAge: s.startWindow.firstFaceAt.map { max(0, now - $0) },
                blinks: s.blinks, motionEvents: s.motionEvents,
                framesAnalyzed: s.analyzed, framesDropped: s.dropped, framesWithFace: s.withFace,
                tracksStarted: s.tracker.tracksStarted,
                freshHandoffs: s.tracker.freshHandoffs, inheritedHandoffs: s.tracker.inheritedHandoffs,
                notLiveTicks: s.notLiveTicks,
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
            if enabled, s.wasEnabled == false { s.startWindow.begin(at: time) }
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
            if sample != nil {
                s.withFace += 1
                s.startWindow.faceAnalyzed(at: time)        // ND-118a: first face starts the window
            }
            s.totalMs += ms
            s.maxMs = max(s.maxMs, ms)
        }
        defer { summarizeIfDue(time: time) }
        guard let sample else { return }

        // Track continuity first: a new track owns no evidence, and history from the
        // previous face must never feed this one's blink baseline / motion references.
        let broke = shared.withLock { $0.tracker.observe(box: sample.box, interOcular: sample.interOcular, time: time) }
        if let b = broke {
            blink.reset(); motion.reset()
            // Numbers only: why the track broke and what it inherited (tuning, ND-116).
            log.debug("liveness: new face track (\(b.reason.rawValue, privacy: .public); gap \(b.gap ?? -1, format: .fixed(precision: 2), privacy: .public)s, IoU \(b.iou ?? -1, format: .fixed(precision: 2), privacy: .public), IOD change \(b.iodChange ?? -1, format: .fixed(precision: 2), privacy: .public)) — own evidence reset; handoff \(b.handoff.rawValue, privacy: .public)")
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
            shared.withLock { $0.tracker.recordEvidence(at: time) }
        }
    }

    /// Counters at the start of a summary period (deltas are what tuning needs).
    struct PeriodCounts {
        var blinks = 0, motion = 0, tracks = 0, fresh = 0, inherited = 0, notLive = 0
        var analyzed = 0, withFace = 0, dropped = 0
        init() {}
        init(_ d: LivenessDiagnostics) {
            blinks = d.blinks; motion = d.motionEvents; tracks = d.tracksStarted
            fresh = d.freshHandoffs; inherited = d.inheritedHandoffs; notLive = d.notLiveTicks
            analyzed = d.framesAnalyzed; withFace = d.framesWithFace; dropped = d.framesDropped
        }
    }

    /// ND-118b: one PERSISTED (`.notice` = the unified log's default level; `.info` and
    /// `.debug` are memory-only unless a profile is installed) summary line every 60 s
    /// of analyzed frames, so on-device tuning doesn't need a `log stream --level debug`
    /// session. Numbers only — no image, landmark or identity data. Counts are for the
    /// last period, with running totals in brackets.
    private func summarizeIfDue(time: TimeInterval) {
        guard let start = periodStart else { periodStart = time; return }
        guard time - start >= Self.summaryInterval else { return }
        let d = diagnostics()
        let now = PeriodCounts(d), b = periodBase
        let faceAge = d.windowFaceAge.map { String(format: "%.0fs", $0) } ?? "none"
        let evAge = d.lastEvidenceAge.map { String(format: "%.1fs", $0) } ?? "never"
        log.notice("liveness summary (\(time - start, format: .fixed(precision: 0), privacy: .public)s): blinks \(now.blinks - b.blinks, privacy: .public) [\(now.blinks, privacy: .public)], motion \(now.motion - b.motion, privacy: .public) [\(now.motion, privacy: .public)], track starts \(now.tracks - b.tracks, privacy: .public) [\(now.tracks, privacy: .public)], handoffs \(now.fresh - b.fresh, privacy: .public) fresh / \(now.inherited - b.inherited, privacy: .public) inherited, notLive ticks \(now.notLive - b.notLive, privacy: .public) [\(now.notLive, privacy: .public)]; last evidence \(evAge, privacy: .public), window first face \(faceAge, privacy: .public) ago; frames \(now.analyzed - b.analyzed, privacy: .public) (face \(now.withFace - b.withFace, privacy: .public)), dropped \(now.dropped - b.dropped, privacy: .public); peak motion/required \(self.periodMaxMotionRatio, format: .fixed(precision: 2), privacy: .public), jitter floor \(self.motion.noiseFloor ?? -1, format: .fixed(precision: 4), privacy: .public); analysis \(d.meanAnalysisMs ?? -1, format: .fixed(precision: 1), privacy: .public) ms mean / \(d.maxAnalysisMs ?? -1, format: .fixed(precision: 1), privacy: .public) max")
        periodStart = time
        periodBase = now
        periodMaxMotionRatio = 0
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
        let request = landmarksRequest
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
