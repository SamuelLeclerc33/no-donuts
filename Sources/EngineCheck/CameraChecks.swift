import Foundation
import CoreImage
import CoreVideo
import ImageIO
import IOKit.audio
import NoDonutsCore
// Owner: see CLAUDE.md module table. Split out of main.swift (ND-114) — pure move.

/// ND-055 stale-frame guard.
@MainActor
func runFrameFreshnessChecks(_ c: Checks) async {
    // ND-055: stale-frame guard (pure policy; host-clock seconds).
    print("\nFrameFreshness checks (ND-055):")
    do {
        let maxAge = FrameFreshness.maxAge
        let now: TimeInterval = 1_000
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.5, now: now, notBefore: nil),
                 "freshness: a 0.5s-old frame is fresh")
        c.expect(FrameFreshness.isFresh(frameTime: now - maxAge, now: now, notBefore: nil),
                 "freshness: a frame exactly maxAge old is fresh (inclusive boundary)")
        c.expect(!FrameFreshness.isFresh(frameTime: now - maxAge - 0.01, now: now, notBefore: nil),
                 "freshness: a frame just past maxAge is stale (never served)")
        c.expect(!FrameFreshness.isFresh(frameTime: now - 60, now: now, notBefore: nil),
                 "freshness: a long-stale frame (camera stopped delivering) is stale")
        c.expect(!FrameFreshness.isFresh(frameTime: now - 1, now: now, notBefore: now - 0.5),
                 "freshness: a frame before notBefore (queued pre-suspend) is rejected even if young")
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.2, now: now, notBefore: now - 0.5),
                 "freshness: a frame after notBefore is fresh")
        c.expect(FrameFreshness.isFresh(frameTime: now - 0.5, now: now, notBefore: now - 0.5),
                 "freshness: a frame exactly at notBefore is accepted")
        c.expect(!FrameFreshness.isFresh(frameTime: now + FrameFreshness.futureTolerance + 5, now: now, notBefore: nil),
                 "freshness: an implausibly future-stamped frame is rejected")

        let wedged = FrameFreshness.wedgedAfter
        c.expect(!FrameFreshness.isWedged(lastFrameTime: nil, runningSince: now - wedged + 1, now: now),
                 "wedged: running too briefly with no frame → not wedged yet")
        c.expect(!FrameFreshness.isWedged(lastFrameTime: now - 1, runningSince: now - 100, now: now),
                 "wedged: a recent frame → not wedged")
        c.expect(FrameFreshness.isWedged(lastFrameTime: now - wedged - 1, runningSince: now - 100, now: now),
                 "wedged: no frame for > wedgedAfter while running → wedged")
        c.expect(FrameFreshness.isWedged(lastFrameTime: nil, runningSince: now - wedged, now: now),
                 "wedged: never delivered since start, exactly wedgedAfter → wedged")
        c.expect(!FrameFreshness.isWedged(lastFrameTime: now - 100, runningSince: now - 2, now: now),
                 "wedged: just resumed (old last frame predates restart) → not wedged yet")

        // Tear-down decision (ADR-0003: never reconfigure-churn during a call).
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: false, deviceInUseByAnotherApp: false,
                                                      interruptedSince: nil, now: now),
                 "wedged tear-down: not wedged → no tear-down")
        c.expect(FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                     interruptedSince: nil, now: now),
                 "wedged tear-down: wedged, no call, no interruption → tear down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: true,
                                                      interruptedSince: nil, now: now),
                 "wedged tear-down: device in use by another app (call) → never tear down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: true,
                                                      interruptedSince: now - 1_000, now: now),
                 "wedged tear-down: call + old interruption → still no tear-down")
        c.expect(!FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                      interruptedSince: now - 1, now: now),
                 "wedged tear-down: recent interruption → deferred")
        c.expect(FrameFreshness.shouldTearDownWedged(isWedged: true, deviceInUseByAnotherApp: false,
                                                     interruptedSince: now - wedged, now: now),
                 "wedged tear-down: stale interruption flag (no interruptionEnded) can't block recovery forever")
    }
}

/// ND-075 camera trust policy.
@MainActor
func runCameraTrustPolicyChecks(_ c: Checks) async {
    print("\nCameraTrustPolicy checks (ND-075):")
    do {
        c.expect(CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: true, transportIsBuiltIn: true),
                 "trust: built-in type + built-in transport → trusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: true, transportIsBuiltIn: false),
                 "trust: built-in type on a non-built-in transport (spoofing virtual device) → untrusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: false, transportIsBuiltIn: true),
                 "trust: built-in transport but not a built-in wide-angle type (e.g. Desk View) → untrusted")
        c.expect(!CameraTrustPolicy.isTrusted(deviceTypeIsBuiltIn: false, transportIsBuiltIn: false),
                 "trust: external/virtual camera → untrusted")
        c.expect(CameraTrustPolicy.builtInTransportType == Int32(kIOAudioDeviceTransportTypeBuiltIn),
                 "trust: policy built-in transport matches kIOAudioDeviceTransportTypeBuiltIn")
        c.expect(CameraTrustPolicy.fourCC(CameraTrustPolicy.builtInTransportType) == "bltn",
                 "trust: built-in transport renders as 'bltn'")
    }
}
