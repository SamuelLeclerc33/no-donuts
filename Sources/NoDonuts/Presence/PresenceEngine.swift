import Foundation

// Owner: homer — the brain. State machine, grace timers, policy, orchestration.
// Backlog: ND-015, ND-025, ND-030, ND-033, ND-034. ADR-0003.

/// Drives the periodic loop: capture -> recognize -> decide -> (maybe) lock.
/// Holds the only mutable presence state; all policy decisions live here.
public final class PresenceEngine {
    private let camera: CameraCapturing
    private let recognizer: FaceRecognizing
    private let locker: ScreenLocking
    private var config: Config

    public private(set) var state: PresenceState = .unknown
    private var consecutiveAbsentTicks = 0
    private var absentSince: Date?
    public var isPaused = false

    public init(camera: CameraCapturing,
                recognizer: FaceRecognizing,
                locker: ScreenLocking,
                config: Config) {
        self.camera = camera
        self.recognizer = recognizer
        self.locker = locker
        self.config = config
    }

    /// One iteration of the loop. Call every `config.tickIntervalSeconds`.
    /// `now` is injected so the policy is deterministic + unit-testable.
    public func tick(now: Date) async {
        if isPaused { state = .paused; return }

        switch await camera.capture() {
        case .suspended:
            state = .suspended
            return
        case .unavailable:
            // TODO(homer/blart): EC-08/09 fail policy. Do not silently fail-open.
            return
        case .cameraBusyNoFrames:
            // ADR-0003: a busy camera means the user is almost certainly in front of it.
            markPresent(.callAssumedPresent)
        case .frame(let frame):
            switch await recognizer.recognize(frame) {
            case .enrolledUserPresent:
                markPresent(.present)
            case .strangerOnly, .noFace:
                markAbsent(now: now)            // stranger never counts as present (EC-03)
            case .error:
                // TODO(homer): EC-10 — don't reset absence on error; count conservatively.
                break
            }
        }
    }

    private func markPresent(_ newState: PresenceState) {
        state = newState
        consecutiveAbsentTicks = 0
        absentSince = nil
    }

    private func markAbsent(now: Date) {
        consecutiveAbsentTicks += 1
        if consecutiveAbsentTicks < config.consecutiveAbsentTicksToLock { return }
        if absentSince == nil { absentSince = now }
        state = .absent
        if let since = absentSince, now.timeIntervalSince(since) >= config.graceSeconds {
            locker.lock()
            state = .suspended
        }
    }
}
