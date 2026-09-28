import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// Lock failure: no fail-open; bounded-backoff retries (ND-054, ND-079).
@MainActor
func runLockFailureRetryChecks(_ c: Checks) async {
    // Lock failure: no fail-open; bounded-backoff retries (ND-054)
    do {
        let config = Config()
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        c.expect(e.state == .lockFailed && locker.lockCallCount == 1 && e.lockFailureCount == 1,
                 "lock fails → .lockFailed, lockFailureCount 1 (no fail-open)")
    }

    // ND-054: lockRetryDelay is pure: 10/20/40/60/60…, n<=0 → 10, huge n capped.
    c.expect(lockRetryDelay(afterFailures: 0) == 10 && lockRetryDelay(afterFailures: -3) == 10,
             "lockRetryDelay(n<=0) == 10 (ND-054)")
    c.expect([1, 2, 3, 4, 5, 6].map { lockRetryDelay(afterFailures: $0) } == [10, 20, 40, 60, 60, 60],
             "lockRetryDelay(1...6) == 10/20/40/60/60/60 (ND-054)")
    c.expect(lockRetryDelay(afterFailures: Int.max) == 60, "lockRetryDelay(Int.max) == 60, no overflow (ND-054)")

    // ND-054: first failure → no retry before +10s, retry AT +10s; backoff schedule
    // 10/20/40/60/60 on continued failure; state stays .lockFailed (never .absent).
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        let firstAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 9.9))
        let noEarlyRetry = locker.lockCallCount == 1 && e.state == .lockFailed
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        let retriedAt10 = locker.lockCallCount == 2 && e.lockFailureCount == 2 && e.state == .lockFailed
        c.expect(noEarlyRetry, "failed auto-lock → no retry before +10s (ND-054)")
        c.expect(retriedAt10, "failed auto-lock → retried at +10s, lockFailureCount 2 (ND-054)")

        // Continue 1s ticks and record the times each lock call happens.
        var callTimes: [Double] = [firstAt, firstAt + 10]
        var stayedFailed = true
        var t = firstAt + 10
        while t < firstAt + 10 + 20 + 40 + 60 + 60 + 5 {
            t += 1
            let before = locker.lockCallCount
            await e.tick(now: t0.addingTimeInterval(t))
            if locker.lockCallCount > before { callTimes.append(t) }
            if e.state != .lockFailed { stayedFailed = false }
        }
        let gaps = zip(callTimes.dropFirst(), callTimes).map { $0 - $1 }
        c.expect(gaps == [10, 20, 40, 60, 60], "retry gaps follow 10/20/40/60/60 (ND-054), got \(gaps)")
        c.expect(stayedFailed && e.lockFailureCount == callTimes.count,
                 "retries keep .lockFailed (never clobbered to .absent); lockFailureCount tracks attempts (ND-054)")
    }

    // ND-054: a retry that SUCCEEDS stops retries → .suspended, no further lock calls.
    do {
        let config = Config()
        let locker = ScriptedLocker([false, true])
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        await driveUntilGraceElapsed(e, config)
        let firstAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))    // retry → success
        let lockedOnRetry = e.state == .suspended && locker.lockCallCount == 2
        for i in 1...200 {
            await e.tick(now: t0.addingTimeInterval(firstAt + 10 + Double(i)))
        }
        c.expect(lockedOnRetry && e.state == .suspended && locker.lockCallCount == 2,
                 "successful retry → .suspended, no further lock calls (ND-054)")
    }

    // ND-054: presence clears episode state — count back to 0, and a new absence
    // gets a fresh full consensus + grace, then a fresh first attempt.
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let recognizer = StubRecognizer(.noFace)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await driveUntilGraceElapsed(e, config)
        let failedFirst = e.lockFailureCount == 1
        recognizer.result = .enrolledUserPresent(confidence: 1)
        await e.tick(now: t0.addingTimeInterval(500))
        let cleared = e.state == .present && e.lockFailureCount == 0
        recognizer.result = .noFace
        // Within the new episode's grace: no lock even though the old retry time passed.
        for i in 0...config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(600 + Double(i)))
        }
        let noCarryOver = locker.lockCallCount == 1 && e.state == .absent
        await e.tick(now: t0.addingTimeInterval(600 + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(failedFirst && cleared && noCarryOver && locker.lockCallCount == 2 && e.lockFailureCount == 1,
                 "presence clears lock-failure episode state; new absence starts fresh (ND-054)")
    }

    // ND-054: a failed MANUAL lockNow() while present does not start retries or
    // count toward lockFailureCount.
    do {
        let locker = SpyLocker(succeed: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.enrolledUserPresent(confidence: 1)), locker)
        await e.lockNow()
        for i in 0..<120 { await e.tick(now: t0.addingTimeInterval(Double(i))) }
        c.expect(locker.lockCallCount == 1 && e.lockFailureCount == 0 && e.state == .present,
                 "failed manual lockNow while present → no retries, not counted (ND-054)")
    }

    // ND-079: a manual lockNow() still in flight at grace expiry → the auto path
    // skips WITHOUT recording an attempt; after the manual lock fails, the auto
    // path attempts on the very next tick.
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let manual = Task { @MainActor in await e.lockNow() }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        let held = locker.isHeld && locker.lockCallCount == 1
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(graceAt))         // auto path: manual in flight
        let skippedUnrecorded = locker.lockCallCount == 1 && e.lockFailureCount == 0
        locker.release(false)                                      // manual lock fails
        await manual.value
        let manualFailed = e.state == .lockFailed
        await e.tick(now: t0.addingTimeInterval(graceAt + 1))     // next tick → auto attempt
        c.expect(held && skippedUnrecorded, "manual lock in flight at grace expiry → auto skip not recorded (ND-079)")
        c.expect(manualFailed && locker.lockCallCount == 2 && e.state == .suspended,
                 "manual lock failed → auto path attempts on the next tick (ND-079)")
    }

    // ND-054: the busy-cap escalation path (ND-033) retries on the same backoff.
    do {
        let config = Config()
        let locker = ScriptedLocker([false])
        let e = makeEngine(StubCamera(.cameraBusyNoFrames), StubRecognizer(.noFace), locker, config)
        await e.tick(now: t0)
        let base = config.maxCallAssumedPresentSeconds
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        let firstAt = base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        await e.tick(now: t0.addingTimeInterval(firstAt))
        await e.tick(now: t0.addingTimeInterval(firstAt + 5))
        let noEarly = locker.lockCallCount == 1
        await e.tick(now: t0.addingTimeInterval(firstAt + 10))
        c.expect(noEarly && locker.lockCallCount == 2 && e.state == .lockFailed,
                 "busy-cap escalation: failed lock retried at +10s, not before (ND-054/ND-033)")
    }

    // ND-054: an episode reset DURING an in-flight auto-lock (e.g. the session
    // suspend caused by that very lock) must not leak lockSucceeded into the next
    // episode — the next absence must still be able to lock.
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        let autoTick = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(graceAt)) }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        e.sessionSuspended()               // the lock "took" → OS session suspend mid-await
        locker.release(true)
        await autoTick.value
        let base = graceAt + 100
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(base + Double(i)))
        }
        await e.tick(now: t0.addingTimeInterval(base + Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1))
        c.expect(locker.lockCallCount == 2 && e.state == .suspended,
                 "reset during in-flight auto-lock doesn't leak into next episode; next absence locks (ND-054)")
    }

    // ND-054 review fix: a pause DURING an in-flight auto-lock that then FAILS must
    // not clobber .paused with .lockFailed (that would raise a false "will keep
    // retrying" alarm while the loop is stopped).
    do {
        let config = Config()
        let locker = GatedLocker(laterResult: false)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, config)
        for i in 0..<config.consecutiveAbsentTicksToLock {
            await e.tick(now: t0.addingTimeInterval(Double(i)))
        }
        let graceAt = Double(config.consecutiveAbsentTicksToLock) + config.graceSeconds + 1
        let autoTick = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(graceAt)) }
        for _ in 0..<100 where !locker.isHeld { await Task.yield() }
        e.pause()
        locker.release(false)
        await autoTick.value
        c.expect(e.state == .paused && e.lockFailureCount == 0,
                 "pause during in-flight auto-lock that fails → stays .paused, no failure recorded (ND-054)")
    }

    // ND-061 review fix: stranger, stranger, error×3 (escalated), stranger → still
    // fast-locks on the 3rd stranger reading (escalated errors hold the streak).
    do {
        let config = Config()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.strangerOnly)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker, config)
        await e.tick(now: t0)
        await e.tick(now: t0.addingTimeInterval(1))
        recognizer.result = .error("blur")
        for i in 0..<config.maxConsecutiveErrorsBeforeAbsent {
            await e.tick(now: t0.addingTimeInterval(2 + Double(i)))
        }
        c.expect(locker.lockCallCount == 0, "escalated errors between strangers don't lock by themselves (ND-061)")
        recognizer.result = .strangerOnly
        await e.tick(now: t0.addingTimeInterval(2 + Double(config.maxConsecutiveErrorsBeforeAbsent)))
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "escalated error ticks hold the stranger streak → 3rd stranger fast-locks (ND-061)")
    }
}

/// ScreenLocker self-test + chain (fakes only, ND-058/ND-074).
@MainActor
func runScreenLockerChainChecks(_ c: Checks) async {
    print("\nScreenLocker self-test + chain checks (fakes only, ND-058/ND-074):")
    do {
        let both: Set<String> = ["SACLockScreenImmediate", "SACSwitchToLoginWindow"]
        c.expect(LockMechanism.allCases == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "LockMechanism chain order: immediate, then switch-to-login-window")
        c.expect(LockMechanism.sacLockScreenImmediate.symbolName == "SACLockScreenImmediate"
                 && LockMechanism.sacSwitchToLoginWindow.symbolName == "SACSwitchToLoginWindow",
                 "LockMechanism.symbolName maps to the login.framework exports")

        let none = ScreenLocker(resolveSymbol: fakeResolver([])).selfTest()
        c.expect(!none.canLock && none.available.isEmpty, "selfTest: nothing resolvable → canLock == false")

        let onlySwitch = ScreenLocker(resolveSymbol: fakeResolver(["SACSwitchToLoginWindow"])).selfTest()
        c.expect(onlySwitch.available == [.sacSwitchToLoginWindow] && onlySwitch.canLock,
                 "selfTest: only switch symbol → [.sacSwitchToLoginWindow]")

        let all = ScreenLocker(resolveSymbol: fakeResolver(both)).selfTest()
        c.expect(all == LockCapability(available: [.sacLockScreenImmediate, .sacSwitchToLoginWindow]),
                 "selfTest: both resolvable → chain order preserved")

        let probeSession = FakeLockSession(locksOn: nil)
        _ = probeSession.locker(resolving: both).selfTest()
        c.expect(probeSession.invoked.isEmpty, "selfTest NEVER invokes a mechanism")

        c.expect(SpyLocker(succeed: true).selfTest().canLock,
                 "ScreenLocking default selfTest() → fake lockers canLock (all mechanisms)")

        // lock() chain behaviour with injected invoke + probe.
        let s1 = FakeLockSession(locksOn: .sacLockScreenImmediate)
        let ok1 = await s1.locker(resolving: both).lock()
        c.expect(ok1 && s1.invoked == [.sacLockScreenImmediate],
                 "lock: immediate confirms → true, fallback NOT invoked")

        let s2 = FakeLockSession(locksOn: .sacSwitchToLoginWindow)
        let started = Date()
        let ok2 = await s2.locker(resolving: both).lock()
        c.expect(ok2 && s2.invoked == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "lock: immediate unconfirmed → falls through to switch-to-login-window → true")
        c.expect(Date().timeIntervalSince(started) < 1.0,
                 "lock: fallback confirmed within the shared deadline")

        let s3 = FakeLockSession(locksOn: nil)
        let started3 = Date()
        let ok3 = await s3.locker(resolving: both).lock()
        let elapsed3 = Date().timeIntervalSince(started3)
        c.expect(!ok3 && s3.invoked == [.sacLockScreenImmediate, .sacSwitchToLoginWindow],
                 "lock: nothing confirms → both tried in order, returns false (never fail open)")
        c.expect(elapsed3 < 0.3 + 0.5, "lock: whole chain bounded by ONE shared deadline")

        let s4 = FakeLockSession(locksOn: .sacSwitchToLoginWindow)
        let ok4 = await s4.locker(resolving: ["SACSwitchToLoginWindow"]).lock()
        c.expect(ok4 && s4.invoked == [.sacSwitchToLoginWindow],
                 "lock: only switch resolvable → invokes switch only → true")

        let s5 = FakeLockSession(locksOn: .sacLockScreenImmediate)
        let ok5 = await s5.locker(resolving: []).lock()
        c.expect(!ok5 && s5.invoked.isEmpty, "lock: nothing resolvable → false, nothing invoked")
    }
}

/// ND-077 protection audit.
@MainActor
func runProtectionAuditChecks(_ c: Checks) async {
    print("\nProtectionAudit checks (ND-077):")
    do {
        let suiteName = "com.nodonuts.enginecheck.protectionaudit"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        if let d = UserDefaults(suiteName: suiteName) {
            let fn = FaceEmbeddingModelDescriptor.facenetVGGFace2
            let key = fn.thresholdOverrideKey
            func reset() { d.removePersistentDomain(forName: suiteName) }

            reset()
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: all defaults → no reasons")

            reset(); d.set(0.45, forKey: key)
            let lowT = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(lowT.count == 1 && lowT[0].contains("match threshold"),
                     "audit: in-range threshold below default → flagged")

            reset(); d.set(0.01, forKey: key)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: out-of-range threshold (rejected → default) → not flagged")

            reset(); d.set(0.7, forKey: key)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: stricter threshold → not flagged")

            reset(); d.set(false, forKey: "antiSpoofEnabled")
            let off = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(off == ["anti-spoof off"], "audit: anti-spoof disabled → flagged")

            reset(); d.set(true, forKey: "antiSpoofEnabled")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: anti-spoof explicitly enabled → not flagged")

            reset(); d.set(0.0001, forKey: "spoofTextureFloor")
            let lowF = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(lowF.count == 1 && lowF[0].contains("floor"),
                     "audit: tiny positive spoof floor → flagged")

            reset(); d.set(0.0, forKey: "spoofTextureFloor")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: invalid 0 floor (rejected → default) → not flagged")

            reset(); d.set(40.0, forKey: "spoofTextureFloor")
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: stricter spoof floor → not flagged")

            reset(); d.set(0.45, forKey: key); d.set(false, forKey: "antiSpoofEnabled")
            d.set(0.0001, forKey: "spoofTextureFloor")
            let all = reducedProtectionReasons(descriptor: fn, defaults: d)
            c.expect(all.count == 2 && all.contains("anti-spoof off"),
                     "audit: threshold + anti-spoof off → both; floor folded into anti-spoof off")

            reset(); d.set(0.55, forKey: FaceEmbeddingModelDescriptor.visionFeaturePrint.thresholdOverrideKey)
            c.expect(reducedProtectionReasons(descriptor: fn, defaults: d).isEmpty,
                     "audit: another model's lowered override doesn't flag the active model")
            c.expect(reducedProtectionReasons(descriptor: .visionFeaturePrint, defaults: d).count == 1,
                     "audit: lowered override flags its own model")
            reset()
        } else {
            c.expect(false, "audit: could not create isolated UserDefaults suite")
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
