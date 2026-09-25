import Foundation

// Owner: blart — ND-055 stale-frame guard.
//
// Pure, AVFoundation-free freshness policy so it is checkable by EngineCheck.
//
// Time base: every value here is HOST-CLOCK seconds, i.e.
// `CMClockGetTime(CMClockGetHostTimeClock()).seconds` (mach absolute time,
// monotonic, does not jump with wall-clock changes). Frame times are the
// sample's presentation timestamp converted into the host clock, falling back
// to the host-clock arrival time when the PTS is unusable. See
// `CameraController` for the stamping.

/// Decides whether a cached camera frame may be used for a presence decision.
///
/// Fail-closed by design: a frame that is too old, or that predates the last
/// `clear(notBefore:)` (suspend/resume/tear-down), is NOT fresh and must never
/// be returned as `.frame` — the caller falls through to its honest
/// busy/unavailable outcomes instead.
public struct FrameFreshness {
    /// A frame older than this (seconds) is stale. The session runs at ~1 fps,
    /// so a healthy camera always has a frame well inside this window.
    public static let maxAge: TimeInterval = 3.0

    /// A running session that has produced no fresh frame for this long
    /// (seconds) is considered wedged and gets torn down so the next tick
    /// reconfigures from scratch.
    public static let wedgedAfter: TimeInterval = 10.0

    /// Tolerance for a frame stamped slightly in the future (clock-conversion
    /// rounding). Anything further ahead is treated as bogus → not fresh.
    public static let futureTolerance: TimeInterval = 1.0

    /// True iff a frame stamped `frameTime` may be used at `now`.
    /// - Fresh when `now - frameTime <= maxAge` (the boundary is inclusive).
    /// - Not fresh when earlier than `notBefore` (a frame queued before a
    ///   suspend/resume/tear-down), or implausibly far in the future.
    public static func isFresh(frameTime: TimeInterval,
                               now: TimeInterval,
                               notBefore: TimeInterval?) -> Bool {
        if let notBefore, frameTime < notBefore { return false }
        let age = now - frameTime
        if age < -futureTolerance { return false }
        return age <= maxAge
    }

    /// True when a session that has been running since `runningSince` has not
    /// delivered a frame for `wedgedAfter` seconds. The baseline is the later of
    /// the last frame and the (re)start time, so a session that just started or
    /// resumed is given the full window before being declared wedged.
    public static func isWedged(lastFrameTime: TimeInterval?,
                                runningSince: TimeInterval,
                                now: TimeInterval) -> Bool {
        let baseline = max(lastFrameTime ?? runningSince, runningSince)
        return now - baseline >= wedgedAfter
    }

    /// Whether a wedged session should actually be torn down (ADR-0003).
    ///
    /// Never tear down while another app holds the device (a video call): the
    /// camera is shared, a reconfigure would re-lock the device and could
    /// throttle / flicker the call app's stream, and the caller's busy check
    /// already reports `.cameraBusyNoFrames`. An `AVCaptureSessionWasInterrupted`
    /// notification also defers tear-down, but only for `wedgedAfter` seconds
    /// after it arrived — `interruptionEnded` is not guaranteed, so a stale
    /// interruption flag must not block recovery forever.
    public static func shouldTearDownWedged(isWedged: Bool,
                                            deviceInUseByAnotherApp: Bool,
                                            interruptedSince: TimeInterval?,
                                            now: TimeInterval) -> Bool {
        guard isWedged else { return false }
        if deviceInUseByAnotherApp { return false }
        if let interruptedSince, now - interruptedSince < wedgedAfter { return false }
        return true
    }
}
