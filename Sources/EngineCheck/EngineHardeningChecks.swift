import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// ND-060/062/091/092 engine hardening.
@MainActor
func runEngineHardeningChecks(_ c: Checks) async {
    print("\nND-060/062/091/092 engine hardening checks:")

    // ND-062: Config.validated() clamps every tunable into Config.Bounds.
    do {
        let d = Config()
        c.expect(d.validated() == d, "ND-062: shipped defaults are inside Bounds (validated() is a no-op)")
        var bad = Config()
        bad.tickIntervalSeconds = 0
        bad.graceSeconds = 100_000
        bad.consecutiveAbsentTicksToLock = 0
        bad.maxConsecutiveErrorsBeforeAbsent = -5
        bad.maxCallAssumedPresentSeconds = 1e9
        bad.maxCameraUnavailableSeconds = 0
        bad.consecutiveStrangerTicksToLock = 0
        bad.strangerGraceSeconds = -3
        let v = bad.validated()
        let B = Config.Bounds.self
        c.expect(v.tickIntervalSeconds == B.tickIntervalSeconds.lowerBound && v.tickIntervalSeconds == 0.5,
                 "ND-062: 0s tick → clamped to 0.5s (no CPU spin)")
        c.expect(v.graceSeconds == 60, "ND-062: huge grace → clamped to 60s (no fail-open)")
        c.expect(v.consecutiveAbsentTicksToLock == 2, "ND-062: 0 consensus → clamped to 2 ticks")
        c.expect(v.maxConsecutiveErrorsBeforeAbsent == 1, "ND-062: negative error cap → clamped to 1")
        c.expect(v.maxCallAssumedPresentSeconds == 3600, "ND-062: huge call cap → clamped to 3600s")
        c.expect(v.maxCameraUnavailableSeconds == 30, "ND-062: 0 unavailable cap → clamped to 30s")
        c.expect(v.consecutiveStrangerTicksToLock == 1, "ND-062: 0 stranger ticks → clamped to 1")
        c.expect(v.strangerGraceSeconds == 0, "ND-062: negative stranger grace → clamped to 0")
        c.expect(v.validated() == v, "ND-062: validated() is idempotent")
        var high = Config()
        high.tickIntervalSeconds = 99
        high.consecutiveAbsentTicksToLock = 1_000
        high.maxConsecutiveErrorsBeforeAbsent = 1_000
        high.consecutiveStrangerTicksToLock = 1_000
        high.strangerGraceSeconds = 99
        high.graceSeconds = 0
        high.maxCameraUnavailableSeconds = 1e9
        high.maxCallAssumedPresentSeconds = 0
        let hv = high.validated()
        c.expect(hv.tickIntervalSeconds == 10 && hv.consecutiveAbsentTicksToLock == 20
                 && hv.maxConsecutiveErrorsBeforeAbsent == 20 && hv.consecutiveStrangerTicksToLock == 10
                 && hv.strangerGraceSeconds == 10 && hv.graceSeconds == 2
                 && hv.maxCameraUnavailableSeconds == 600 && hv.maxCallAssumedPresentSeconds == 60,
                 "ND-062: every tunable clamps at the other end of its range too")
        var nan = Config()
        nan.tickIntervalSeconds = .nan
        nan.graceSeconds = .infinity
        nan.maxCallAssumedPresentSeconds = -.infinity
        nan.strangerGraceSeconds = .nan
        let nv = nan.validated()
        c.expect(nv.tickIntervalSeconds == d.tickIntervalSeconds && nv.graceSeconds == d.graceSeconds
                 && nv.maxCallAssumedPresentSeconds == d.maxCallAssumedPresentSeconds
                 && nv.strangerGraceSeconds == d.strangerGraceSeconds,
                 "ND-062: non-finite values fall back to the shipped default (not clamped)")
    }

    // ND-062: the engine validates at init AND on updateConfig — a 0-tick / 0-grace /
    // 0-consensus config cannot make a single no-face tick lock.
    do {
        var bad = Config()
        bad.graceSeconds = 0
        bad.consecutiveAbsentTicksToLock = 0
        bad.tickIntervalSeconds = 0
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker, bad)
        await e.tick(now: t0)
        c.expect(locker.lockCallCount == 0 && e.effectiveConfig == bad.validated()
                 && e.effectiveConfig.tickIntervalSeconds == 0.5,
                 "ND-062: init validates → 0 consensus/grace config can't lock on one no-face tick")
        let e2 = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.noFace), locker)
        e2.updateConfig(bad)
        await e2.tick(now: t0)
        c.expect(locker.lockCallCount == 0 && e2.effectiveConfig.consecutiveAbsentTicksToLock == 2
                 && e2.effectiveConfig.graceSeconds == 2,
                 "ND-062: updateConfig validates → unsafe live update clamped, no instant lock")
    }

    // ND-062: Config.resolved(from:) — the UserDefaults resolver (mirrors resolvedMatchThreshold).
    do {
        let suiteName = "nd062.check.\(UUID().uuidString)"
        if let ud = UserDefaults(suiteName: suiteName) {
            defer { ud.removePersistentDomain(forName: suiteName) }
            let K = Config.DefaultsKey.self
            let d = Config()
            c.expect(Config.resolved(from: ud) == d, "ND-062: resolver — absent keys → defaults")
            ud.set(3.0, forKey: K.tickIntervalSeconds); ud.set(12.0, forKey: K.graceSeconds)
            let ok = Config.resolved(from: ud)
            c.expect(ok.tickIntervalSeconds == 3 && ok.graceSeconds == 12, "ND-062: resolver — in-range values accepted")
            ud.set(0.0, forKey: K.tickIntervalSeconds); ud.set(100_000.0, forKey: K.graceSeconds)
            let out = Config.resolved(from: ud)
            c.expect(out.tickIntervalSeconds == d.tickIntervalSeconds && out.graceSeconds == d.graceSeconds,
                     "ND-062: resolver — out-of-range rejected → default (not clamped to the floor)")
            ud.set("fast", forKey: K.tickIntervalSeconds); ud.set(true, forKey: K.graceSeconds)
            let junk = Config.resolved(from: ud)
            c.expect(junk.tickIntervalSeconds == d.tickIntervalSeconds && junk.graceSeconds == d.graceSeconds,
                     "ND-062: resolver — String / Bool values rejected → default")
            ud.set(Double.nan, forKey: K.tickIntervalSeconds)
            c.expect(Config.resolved(from: ud).tickIntervalSeconds == d.tickIntervalSeconds,
                     "ND-062: resolver — NaN rejected → default")
            var base = Config(); base.graceSeconds = 0
            ud.removeObject(forKey: K.graceSeconds)
            c.expect(Config.resolved(from: ud, base: base).graceSeconds == 2,
                     "ND-062: resolver output is validated (an unsafe base can't leak through)")
        } else {
            c.expect(false, "ND-062: could not create a throwaway UserDefaults suite")
        }
    }

    // ND-091: pause() while a tick is suspended in capture() → the stale tick must not
    // overwrite .paused nor count an absence tick into the fresh episode.
    do {
        let config = Config()
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(camera, StubRecognizer(.noFace), locker, config)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        let held = camera.isHeld
        e.pause()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        let stayedPaused = e.state == .paused
        // Resume: if the stale tick had counted, consensus would be reached one tick
        // early (4 fresh ticks) and a tick at +grace would lock.
        let resumed = makeFeeder(camera)
        for n in 0..<(config.consecutiveAbsentTicksToLock - 1) {
            await resumed(e, t0.addingTimeInterval(10 + Double(n)), .frame(CapturedFrame()))
        }
        await resumed(e, t0.addingTimeInterval(10 + Double(config.consecutiveAbsentTicksToLock - 2) + config.graceSeconds + 0.5),
                      .frame(CapturedFrame()))
        c.expect(held && stayedPaused && locker.lockCallCount == 0,
                 "ND-091: pause during in-flight capture → stays .paused, stale tick counts no absence")
    }

    // ND-091: pause() while a tick is suspended in recognize() → same guarantee.
    do {
        let recognizer = GatedRecognizer()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !recognizer.isHeld { await Task.yield() }
        let held = recognizer.isHeld
        e.pause()
        recognizer.release(.enrolledUserPresent(confidence: 1))
        await inFlight.value
        c.expect(held && e.state == .paused && locker.lockCallCount == 0,
                 "ND-091: pause during in-flight recognize → stays .paused (not flipped to .present)")
    }

    // ND-091: sessionSuspended() during an in-flight capture that then returns a
    // stranger frame → stays .suspended, no stranger streak leaked.
    do {
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(camera, StubRecognizer(.strangerOnly), locker)
        let inFlight = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        e.sessionSuspended()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        let stayed = e.state == .suspended
        // Two fresh stranger ticks must NOT fast-lock (would if the stale one counted).
        let feed = makeFeeder(camera)
        await feed(e, t0.addingTimeInterval(1), .frame(CapturedFrame()))
        await feed(e, t0.addingTimeInterval(2), .frame(CapturedFrame()))
        c.expect(stayed && locker.lockCallCount == 0,
                 "ND-091: session suspend during in-flight tick → stays .suspended, stale stranger tick not counted")
    }

    // ND-091: the loop Task cancelled (stopLoop) mid-capture, with no reset → nothing mutates.
    do {
        let camera = GatedCamera()
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(camera, recognizer, locker)
        let first = Task { @MainActor in await e.tick(now: t0) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        camera.release(.frame(CapturedFrame()))
        await first.value
        let present = e.state == .present
        recognizer.result = .noFace
        let inFlight = Task { @MainActor in await e.tick(now: t0.addingTimeInterval(1)) }
        for _ in 0..<100 where !camera.isHeld { await Task.yield() }
        inFlight.cancel()
        camera.release(.frame(CapturedFrame()))
        await inFlight.value
        c.expect(present && e.state == .present && locker.lockCallCount == 0,
                 "ND-091: cancelled in-flight tick → state untouched (no stale .absent)")
    }

    // ND-091: cancelled auto-lock whose lock() then FAILS → no .lockFailed, no failure count.
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
        autoTick.cancel()
        locker.release(false)
        await autoTick.value
        c.expect(e.state == .absent && e.lockFailureCount == 0,
                 "ND-091: cancelled auto-lock that fails → no stale .lockFailed / failure recorded")
    }

    // ND-092: a successful lock clears the EC-10 error streak. Two held errors, a manual
    // lockNow() that succeeds, then ONE error tick: must be held (stay .suspended), not
    // escalate on the half-finished pre-lock streak to .absent.
    do {
        let locker = SpyLocker(succeed: true)
        let recognizer = StubRecognizer(.enrolledUserPresent(confidence: 1))
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), recognizer, locker)
        await e.tick(now: t0)
        recognizer.result = .error("glitch")
        await e.tick(now: t0.addingTimeInterval(1))
        await e.tick(now: t0.addingTimeInterval(2))
        await e.lockNow()
        let locked = e.state == .suspended
        await e.tick(now: t0.addingTimeInterval(3))
        c.expect(locked && e.state == .suspended && locker.lockCallCount == 1,
                 "ND-092: successful lock clears the error streak → next lone error is held, no .absent")
    }

    // ND-092: after an AUTO lock reached via EC-10 escalation, further errors neither
    // re-lock nor clobber .suspended (lockSucceeded preserved, streaks cleared).
    do {
        let locker = SpyLocker(succeed: true)
        let e = makeEngine(StubCamera(.frame(CapturedFrame())), StubRecognizer(.error("wedged")), locker)
        for n in 0..<40 { await e.tick(now: t0.addingTimeInterval(Double(n))) }
        c.expect(locker.lockCallCount == 1 && e.state == .suspended,
                 "ND-092: post-auto-lock error ticks → no re-lock, state stays .suspended")
    }
}

/// ND-087 Core ML output-dimension check.
@MainActor
func runCoreMLOutputShapeChecks(_ c: Checks) async {
    // ND-087: the Core ML output-dimension check refuses a model whose declared
    // output isn't exactly one multi-array of `expected` elements.
    do {
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 512]], expected: 512),
                 "ND-087: output [1, 512] matches a 512-d descriptor")
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[512]], expected: 512),
                 "ND-087: output [512] matches a 512-d descriptor")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 128]], expected: 512),
                 "ND-087: a 128-d model under a 512-d descriptor is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [], expected: 512),
                 "ND-087: no multi-array output is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[]], expected: 512),
                 "ND-087: an undeclared (flexible) output shape is refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 512], [1, 512]], expected: 512),
                 "ND-087: two multi-array outputs (ambiguous) are refused")
        c.expect(!coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, -1]], expected: 512),
                 "ND-087: a non-positive dimension is refused")
        c.expect(coreMLOutputDimensionMatches(multiArrayOutputShapes: [[1, 128]], expected: 0),
                 "ND-087: expected 0 (no fixed size) always passes")
    }
}

/// ND-065 Keychain service / bundle identity.
@MainActor
func runAppIdentityChecks(_ c: Checks) async {
    // ND-065: the Keychain service is fixed and independent of the bundle id.
    c.expect(AppIdentity.keychainService == "com.nodonuts.app",
             "ND-065: Keychain service stays com.nodonuts.app (never tracks the bundle id)")
    c.expect(Log.subsystem == AppIdentity.bundleID && AppIdentity.defaultsDomain == AppIdentity.bundleID,
             "ND-065: log subsystem and defaults domain follow the bundle id")
}
