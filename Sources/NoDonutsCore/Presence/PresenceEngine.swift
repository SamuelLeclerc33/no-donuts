import Foundation

/// ND-054: backoff between automatic lock retries after the n-th consecutive
/// failed auto-lock in one absence episode: 10s, 20s, 40s, then capped at 60s.
/// Pure (no clock) so the retry cadence is unit-testable. `n <= 0` → 10s.
public func lockRetryDelay(afterFailures n: Int) -> TimeInterval {
    let base: TimeInterval = 10
    let cap: TimeInterval = 60
    guard n > 1 else { return base }
    // Clamp the exponent before shifting so huge n can't overflow.
    let exponent = min(n - 1, 3)                  // 2^3 * 10 = 80 → capped to 60
    return min(base * TimeInterval(1 << exponent), cap)
}

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
    // ND-054: per-absence-episode auto-lock state. Replaces the old one-shot
    // `lockAttempted` latch (which gave up after a single failure = silent
    // fail-open). A failed auto-lock is retried with bounded backoff
    // (lockRetryDelay) for as long as the absence lasts; a success ends the
    // episode's lock attempts. All three are cleared by resetAbsenceAccounting().
    private var lockSucceeded = false
    private var failedLockAttempts = 0
    private var nextLockRetryAt: Date?
    /// Bumped by every resetAbsenceAccounting(). Lets an auto-lock whose `await`
    /// straddled a reset (e.g. sessionSuspended() fired by the very lock it caused,
    /// or a pause mid-lock) avoid writing stale episode state into the NEXT episode.
    private var episodeGeneration = 0
    /// True while an async `locker.lock()` is in flight. Prevents a manual
    /// `lockNow()` and the auto tick loop (or two of either) from running two
    /// overlapping `locker.lock()` calls that would clobber `state`/accounting.
    /// Safe as a plain flag because the engine is `@MainActor`: it's read/written
    /// atomically between suspension points.
    private var isLocking = false
    /// First tick of an unbroken busy-no-frames run; nil when not in such a run.
    /// Bounds the ADR-0003 assume-present fail-open (see handleCameraBusy).
    private var callAssumedSince: Date?
    /// ND-078: first tick of an unbroken lid-open `.unavailable` run; nil when not
    /// in such a run. Bounds the camera-unavailable fail-open (see
    /// handleCameraUnavailable). Cleared by any non-unavailable outcome, by every
    /// full reset (pause / trusted network / suspend / presence) and whenever the
    /// lid is closed.
    private var unavailableSince: Date? {
        didSet { if unavailableSince == nil { unavailableEscalated = false } }
    }
    /// ND-078: true once the current lid-open unavailable run has passed
    /// maxCameraUnavailableSeconds (engine is heading to a lock). Cleared with the run.
    private var unavailableEscalated = false
    /// ND-078: injected lid probe. Production = LidState.current (IOKit);
    /// EngineCheck passes a fake so the policy stays deterministic.
    private let lidState: @Sendable () -> LidState

    /// ND-078: true while the camera has been unavailable (lid open) for longer than
    /// `maxCameraUnavailableSeconds` and the engine is escalating toward a lock. The
    /// display state stays `.cameraUnavailable` during this phase (until the lock
    /// path sets `.suspended` / `.lockFailed`), so the App can use this flag to say
    /// "locking soon" instead of treating it as recovered.
    public var cameraUnavailableEscalating: Bool { unavailableEscalated }

    /// ND-054: failed AUTO-lock attempts in the current absence episode (0 when
    /// none / after presence or any reset). The App re-alerts when it increases.
    /// Manual lockNow() failures are not counted (they never start retries).
    public var lockFailureCount: Int { failedLockAttempts }

    public init(camera: CameraCapturing,
                recognizer: FaceRecognizing,
                locker: ScreenLocking,
                config: Config,
                lidState: @escaping @Sendable () -> LidState = LidState.current) {
        self.camera = camera
        self.lidState = lidState
        self.recognizer = recognizer
        self.locker = locker
        self.config = config
    }

    /// One iteration of the loop. Call every `config.tickIntervalSeconds`.
    /// `now` is injected so the policy is deterministic + unit-testable.
    public func tick(now: Date) async {
        switch await camera.capture() {
        case .suspended:
            // EC-02/EC-13: locked/asleep/inactive (ND-013). The live CameraController
            // returns this whenever its session is suspended (lock/sleep/pause). Mirror `.unavailable`
            // and reset absence accounting so a lock/unlock (or sleep/wake) that
            // happens mid-absence can't trigger a grace-less false lock on
            // resume — the next absence episode must rebuild the full consensus.
            state = .suspended
            resetAbsenceAccounting()     // also ends any busy run (clears callAssumedSince)
            return
        case .unavailable:
            // EC-07/08/09, bounded by ND-078 (lid open) — see handleCameraUnavailable.
            await handleCameraUnavailable(now: now)
        case .cameraBusyNoFrames:
            unavailableSince = nil        // busy is not unavailable → ends any unavailable run (ND-078)
            // ADR-0003 (bounded): a busy camera means the user is almost certainly
            // in front of it — but only assume so up to maxCallAssumedPresentSeconds.
            await handleCameraBusy(now: now)
        case .frame(let frame):
            // ND-098: a frame does NOT by itself end the busy run. Only a real
            // enrolled-user reading (markPresent → full reset) does — or pause /
            // trusted network / suspend. A noFace / stranger / error frame leaves
            // callAssumedSince open, so busy/noFace interleavings (intermittent
            // multi-client frames while a call app holds the camera and the user
            // walked away) stay bounded by maxCallAssumedPresentSeconds and then lock.
            unavailableSince = nil        // a frame ends any unavailable run (ND-078)
            switch await recognizer.recognize(frame) {
            case .enrolledUserPresent:
                markPresent(.present)
            case .strangerOnly, .noFace:
                await markAbsent(now: now)            // stranger never counts as present (EC-03)
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
                    await markAbsent(now: now)
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
    /// busy ticks. The window is ended only by a real enrolled-user reading or a
    /// full reset — NOT by interleaved noFace/stranger/error frames or
    /// camera-unavailable ticks (ND-098/ND-078). An under-cap busy tick does reset
    /// the absence consensus built by interleaved absent frames, but that can only
    /// happen until the cap: past it every busy tick escalates, so absent frames and
    /// busy ticks all count toward the lock. Past that bound (a call app left running unattended),
    /// we stop assuming present and escalate to absence so the normal grace→lock
    /// path can eventually fire. callAssumedSince is reset only on non-busy
    /// outcomes (handled in tick()), so the window persists across consecutive
    /// busy ticks and the escalation sticks once it expires.
    private func handleCameraBusy(now: Date) async {
        if callAssumedSince == nil { callAssumedSince = now }
        if let since = callAssumedSince,
           now.timeIntervalSince(since) >= config.maxCallAssumedPresentSeconds {
            // Bounded fail-open expired: a call app left running unattended too long
            // → stop assuming present, treat as absence so it can eventually lock.
            await markAbsent(now: now)
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

    /// ND-078: bounded camera-unavailable fail-open (EC-07/08/09).
    ///
    /// - Lid CLOSED (clamshell) or NO LID (desktop Mac, no built-in camera — ADR-0015
    ///   makes it permanently unavailable): the camera is expected to be unavailable →
    ///   today's behavior: `.cameraUnavailable`, absence accounting reset, never lock,
    ///   and the window is cleared so a closed lid never builds toward a lock.
    /// - Lid OPEN, before `maxCameraUnavailableSeconds` of continuous unavailability:
    ///   conservative HOLD (like the EC-10 error hold) — no lock, and absence
    ///   accounting / ND-054 retry state / episodeGeneration are left UNTOUCHED.
    ///   Resetting here was a fail-open: unavailable ticks interleaved with absence
    ///   ticks (busy past the call cap, or no-face frames) kept zeroing the consensus
    ///   so it never reached the lock. Holding is safe on resume: a returning user's
    ///   frame goes through markPresent(), which resets everything.
    ///   Display: `.cameraUnavailable`, except an unresolved `.lockFailed` warning or
    ///   the post-lock `.suspended` is kept (don't hide "couldn't lock").
    /// - Lid OPEN, at/after the cap: escalate via markAbsent() — normal consensus +
    ///   grace + lock + ND-054 retry/backoff. Display stays `.cameraUnavailable`
    ///   (markAbsent's `.absent` is rewritten back) until the lock path sets
    ///   `.suspended` / `.lockFailed`: the user may well be present, and flipping to
    ///   "away" would read as "camera recovered" to the App. `cameraUnavailableEscalating`
    ///   is true in this phase so the App can warn "locking soon".
    ///
    /// In ALL branches the busy-run window (callAssumedSince) is preserved: an
    /// unavailable tick is not a real reading, so unavailable ticks interleaved with
    /// busy ticks must not restart the ND-033 call cap (ND-078). Lid-open ticks
    /// (hold or escalation) NEVER reset absence accounting — each reset bumps
    /// episodeGeneration and zeroes the consensus, so the lock could never build.
    private func handleCameraUnavailable(now: Date) async {
        if lidState() != .open {
            state = .cameraUnavailable
            resetAbsenceAccounting(endingWindows: false)
            unavailableSince = nil
            return
        }
        if unavailableSince == nil { unavailableSince = now }
        if let since = unavailableSince,
           now.timeIntervalSince(since) >= config.maxCameraUnavailableSeconds {
            // Bounded fail-open expired with the lid open: can't verify presence for
            // too long → treat as absence so the normal grace→lock path runs.
            unavailableEscalated = true
            await markAbsent(now: now)
            // Honest display: still "camera unavailable" (not "away") until locked /
            // lock failed. Only rewrite .absent, so a reset during the lock await
            // (.paused/.suspended/...) is never clobbered.
            if state == .absent { state = .cameraUnavailable }
        } else {
            // HOLD: neither advance nor reset the absence episode (see doc above).
            if state != .lockFailed && !lockSucceeded { state = .cameraUnavailable }
        }
    }

    /// Clear all absence/error accounting back to a clean slate. Used on a real
    /// present reading, on camera unavailable/suspended, and on session suspend —
    /// so the next absence episode must rebuild the full consensus + grace.
    /// Also ends any open busy/assume-present window (callAssumedSince): every
    /// reset path is a definitive non-busy outcome (real reading, camera down,
    /// or session suspend), so a stale window must not survive into the next
    /// episode and immediately escalate (ND-033 lock-during-fresh-call bug).
    /// Likewise ends any camera-unavailable window (unavailableSince, ND-078).
    /// `endingWindows: false` is used only by the lid-closed unavailable path, which
    /// must keep the call-cap window open (ND-078).
    private func resetAbsenceAccounting(endingWindows: Bool = true) {
        consecutiveAbsentTicks = 0
        absentSince = nil
        lockSucceeded = false
        failedLockAttempts = 0
        nextLockRetryAt = nil
        episodeGeneration &+= 1
        consecutiveErrorTicks = 0
        if endingWindows {
            callAssumedSince = nil
            unavailableSince = nil
        }
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

    /// Entry point the app calls when the user pauses enforcement (ND-035).
    /// Pause is ENFORCED by the App layer: it stops the tick loop AND suspends
    /// the camera (ADR-0011). The engine holds no pause latch of its own — a
    /// stray tick while "paused" would hit `capture() == .suspended` (camera
    /// off) → `.suspended`, which can't lock. This method therefore only sets
    /// the honest display state and clears absence accounting so re-enabling
    /// rebuilds the FULL consensus + grace (a mid-absence pause can't cause a
    /// grace-less false lock when the loop restarts). Same shape as
    /// `sessionSuspended()` / `disabledOnTrustedNetwork()`.
    public func pause() {
        state = .paused
        resetAbsenceAccounting()
    }

    /// Entry point the app calls when it detects a user-trusted Wi-Fi network
    /// (ND-036). Analogous to `sessionSuspended()`: the App layer stops the loop
    /// and camera; this just sets the honest display state and clears absence
    /// accounting so leaving the trusted network rebuilds the full consensus —
    /// no grace-less false lock when enforcement resumes.
    public func disabledOnTrustedNetwork() {
        state = .trustedNetwork
        resetAbsenceAccounting()
    }

    @discardableResult
    private func attemptLock() async -> Bool {
        if isLocking { return false }   // a lock attempt is already in flight (async) — skip; don't double-fire or clobber state (NOT a failure, so leave state untouched)
        isLocking = true
        defer { isLocking = false }
        let generation = episodeGeneration
        let locked = await locker.lock()
        // A pause / trusted-network / session suspend (or presence) reset the episode
        // during the await: that path already set the honest state (.paused,
        // .suspended, ...). Don't clobber it with a stale .lockFailed/.suspended —
        // a stale .lockFailed would raise a false "will keep retrying" alarm while
        // the loop is stopped.
        guard generation == episodeGeneration else { return locked }
        if locked {
            state = .suspended
            consecutiveAbsentTicks = 0   // reset stale absence accounting on successful lock
            absentSince = nil
            return true
        } else {
            state = .lockFailed          // honest status; do NOT pretend suspended (no fail-open)
            return false
        }
    }

    private func markAbsent(now: Date) async {
        consecutiveErrorTicks = 0    // a real (or escalated) reading clears the error streak
        consecutiveAbsentTicks += 1
        if lockSucceeded {
            // Locked this episode (.suspended already set) — don't overwrite with
            // .absent and don't re-lock.
            return
        }
        // Responsive, honest "away" from the first no-face tick (ND-017); the LOCK
        // below is still gated on the consensus + grace window. But do NOT clobber an
        // unresolved lock-failure warning (.lockFailed from a failed auto attempt
        // awaiting retry, or from a failed manual lockNow()) with .absent — that would
        // hide the "couldn't lock" status. markPresent() still clears it.
        if state != .lockFailed { state = .absent }
        if consecutiveAbsentTicks < config.consecutiveAbsentTicksToLock { return }
        if absentSince == nil { absentSince = now }
        guard let since = absentSince, now.timeIntervalSince(since) >= config.graceSeconds else { return }
        // ND-054: bounded-backoff retry. Attempt on first grace expiry, then only
        // once the backoff after the last failure has elapsed (no lock storm).
        if let retryAt = nextLockRetryAt, now < retryAt { return }
        // Cooperative cancellation guard ("nothing locks mid-capture / mid-pause"):
        // the App cancels the loop Task on pause / trusted-network / enrollment /
        // session-suspend, but Swift does not abort an already-suspended `await`,
        // so an in-flight tick can reach here AFTER the user hit "Enroll" or paused.
        // Bail before locking (recording nothing). This gate is placed here — NOT
        // inside attemptLock() — because the manual `lockNow()` path runs in its OWN
        // uncancelled Task and MUST still lock. All auto callers reach locking via
        // markAbsent (.strangerOnly/.noFace, EC-10 error escalation, the bounded
        // busy/callAssumedPresent escalation, and the bounded lid-open
        // camera-unavailable escalation, ND-078), so this single guard — and the retry
        // policy below — covers them all consistently.
        guard !Task.isCancelled else { return }
        // ND-079: a manual lockNow() is in flight. Skip WITHOUT recording an attempt
        // (attemptLock would return false, indistinguishable from a real failure) so
        // the next tick re-evaluates — if the manual lock failed, we attempt then.
        if isLocking { return }
        let generation = episodeGeneration
        let locked = await attemptLock()
        // The episode was reset during the await (session suspend caused by this very
        // lock, pause, presence...) → don't leak its lock state into the new episode.
        guard generation == episodeGeneration else { return }
        if locked {
            lockSucceeded = true
        } else {
            failedLockAttempts += 1
            nextLockRetryAt = now.addingTimeInterval(lockRetryDelay(afterFailures: failedLockAttempts))
        }
    }

    /// Manual lock trigger (menu "Lock now"). Updates state honestly via attemptLock().
    public func lockNow() async { await attemptLock() }

    /// Live-apply new tunables (ND-040). The App calls this when Settings change so
    /// the engine reflects them WITHOUT a relaunch. The new grace/consensus/error/
    /// call-cap values take effect on the NEXT tick — the engine reads them live from
    /// `config` during `tick()` / `markAbsent()` / `handleCameraBusy()`, so simply
    /// swapping the stored value is enough.
    ///
    /// We deliberately do NOT reset absence accounting here: a settings tweak should
    /// not throw away an in-progress absence episode (that would let someone dodge a
    /// pending lock by nudging a slider). The next tick evaluates the running episode
    /// against the new thresholds.
    ///
    /// `tickIntervalSeconds` is consumed by the App's loop, not the engine, so
    /// changing the cadence is the App's responsibility (out of scope here).
    public func updateConfig(_ config: Config) {
        self.config = config
    }
}
