import Foundation

// Owner: homer — the brain. State machine, grace timers, policy, orchestration.
// Backlog: ND-015, ND-025, ND-030, ND-033, ND-034. ADR-0003.

/// Drives the periodic loop: capture -> recognize -> decide -> (maybe) lock.
/// Holds the only mutable presence state; all policy decisions live here.
/// Main-actor-isolated: the loop is driven from the main actor (ADR-0005).
@MainActor
public final class PresenceEngine {
    private let camera: CameraCapturing
    private let recognizer: FaceRecognizing
    private let locker: ScreenLocking
    private var config: Config

    public private(set) var state: PresenceState = .unknown
    private var consecutiveAbsentTicks = 0
    private var consecutiveErrorTicks = 0
    private var absentSince: Date?
    private var lockAttempted = false
    /// First tick of an unbroken busy-no-frames run; nil when not in such a run.
    /// Bounds the ADR-0003 assume-present fail-open (see handleCameraBusy).
    private var callAssumedSince: Date?
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
            // EC-02/EC-13: locked/asleep/inactive (ND-013). Mirror `.unavailable`
            // and reset absence accounting so a lock/unlock (or sleep/wake) that
            // happens mid-absence can't trigger a grace-less false lock on
            // resume — the next absence episode must rebuild the full consensus.
            state = .suspended
            resetAbsenceAccounting()     // also ends any busy run (clears callAssumedSince)
            return
        case .unavailable:
            state = .cameraUnavailable   // EC-08: can't verify presence → honest status, do not lock
            resetAbsenceAccounting()     // camera down → we don't know; clears absence accounting + busy run
            return
        case .cameraBusyNoFrames:
            // ADR-0003 (bounded): a busy camera means the user is almost certainly
            // in front of it — but only assume so up to maxCallAssumedPresentSeconds.
            handleCameraBusy(now: now)
        case .frame(let frame):
            callAssumedSince = nil        // a real frame ends any busy run (ND-033)
            switch await recognizer.recognize(frame) {
            case .enrolledUserPresent:
                markPresent(.present)
            case .strangerOnly, .noFace:
                markAbsent(now: now)            // stranger never counts as present (EC-03)
            case .error:
                // EC-10 conservative HOLD (bounded): a transient Vision error
                // neither advances nor resets the absence consensus — we do NOT
                // call markAbsent (lock-storm on a glitchy frame) nor markPresent
                // (false-unlock). But the hold is bounded: a wedged recognizer
                // that keeps erroring must not hold unlocked forever (no
                // indefinite fail-open).
                consecutiveErrorTicks += 1
                if consecutiveErrorTicks >= config.maxConsecutiveErrorsBeforeAbsent {
                    // Sustained recognizer failure: stop holding unlocked — treat as absence
                    // so the normal grace→lock path runs (EC-10, no indefinite fail-open).
                    markAbsent(now: now)
                }
                // else: transient glitch → conservative hold (presence + absence counters untouched).
            }
        }
    }

    private func markPresent(_ newState: PresenceState) {
        state = newState
        resetAbsenceAccounting()    // a real reading clears the absence + error streaks
    }

    /// ADR-0003 with a bounded fail-open (ND-033). A busy-no-frames camera almost
    /// always means a call is in progress and the user is present, so we assume
    /// present and never lock — but only for up to maxCallAssumedPresentSeconds of
    /// CONTINUOUS busy ticks. Past that bound (a call app left running unattended),
    /// we stop assuming present and escalate to absence so the normal grace→lock
    /// path can eventually fire. callAssumedSince is reset only on non-busy
    /// outcomes (handled in tick()), so the window persists across consecutive
    /// busy ticks and the escalation sticks once it expires.
    private func handleCameraBusy(now: Date) {
        if callAssumedSince == nil { callAssumedSince = now }
        if let since = callAssumedSince,
           now.timeIntervalSince(since) >= config.maxCallAssumedPresentSeconds {
            // Bounded fail-open expired: a call app left running unattended too long
            // → stop assuming present, treat as absence so it can eventually lock.
            markAbsent(now: now)
        } else {
            // ADR-0003: camera busy → user almost certainly in front of it.
            // markPresent() sets the state and clears all accounting via
            // resetAbsenceAccounting() — which now also clears callAssumedSince.
            // We must restore it so the assume-present window stays OPEN across
            // consecutive busy ticks (otherwise the cap would never accumulate
            // and the bounded fail-open could never expire).
            let preserved = callAssumedSince
            markPresent(.callAssumedPresent)
            callAssumedSince = preserved
        }
    }

    /// Clear all absence/error accounting back to a clean slate. Used on a real
    /// present reading, on camera unavailable/suspended, and on session suspend —
    /// so the next absence episode must rebuild the full consensus + grace.
    /// Also ends any open busy/assume-present window (callAssumedSince): every
    /// reset path is a definitive non-busy outcome (real reading, camera down,
    /// or session suspend), so a stale window must not survive into the next
    /// episode and immediately escalate (ND-033 lock-during-fresh-call bug).
    private func resetAbsenceAccounting() {
        consecutiveAbsentTicks = 0
        absentSince = nil
        lockAttempted = false
        consecutiveErrorTicks = 0
        callAssumedSince = nil
    }

    /// Entry point the app calls when the OS session is suspended
    /// (lock/sleep/switch-away). Marks the engine suspended and clears absence
    /// accounting so a mid-absence lock/sleep can't cause a grace-less false lock
    /// on resume — the next absence episode rebuilds the full consensus.
    /// EC-02/EC-13; complements ND-013's SessionStateMonitor. The in-tick
    /// `.suspended` capture path is a backstop; this is the production reset path.
    public func sessionSuspended() {
        state = .suspended
        resetAbsenceAccounting()
    }

    @discardableResult
    private func attemptLock() -> Bool {
        if locker.lock() {
            state = .suspended
            consecutiveAbsentTicks = 0   // reset stale absence accounting on successful lock
            absentSince = nil
            return true
        } else {
            state = .lockFailed          // honest status; do NOT pretend suspended (no fail-open)
            return false
        }
    }

    private func markAbsent(now: Date) {
        consecutiveErrorTicks = 0    // a real (or escalated) reading clears the error streak
        consecutiveAbsentTicks += 1
        if consecutiveAbsentTicks < config.consecutiveAbsentTicksToLock { return }
        if absentSince == nil { absentSince = now }
        let graceElapsed = absentSince.map { now.timeIntervalSince($0) >= config.graceSeconds } ?? false
        if graceElapsed {
            if !lockAttempted {
                lockAttempted = true
                attemptLock()
            }
            // else: already attempted this episode — keep current state (.suspended/.lockFailed), no retry storm
        } else {
            state = .absent
        }
    }

    /// Manual lock trigger (menu "Lock now"). Updates state honestly via attemptLock().
    public func lockNow() { attemptLock() }
}
