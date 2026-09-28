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

/// ND-096 capture preset / format / frame-rate policy.
@MainActor
func runCaptureFormatPolicyChecks(_ c: Checks) async {
    print("\nND-096 — CaptureFormatPolicy (640×480 preset, lowest frame rate)")
    typealias P = CaptureFormatPolicy
    c.expect(P.preferredPreset(isSupported: { _ in true }) == "AVCaptureSessionPreset640x480",
             "preset: 640×480 preferred when supported")
    c.expect(P.preferredPreset(isSupported: { $0 != "AVCaptureSessionPreset640x480" }) == "AVCaptureSessionPreset960x540",
             "preset: next-smallest ≥ 480 lines when 640×480 is unsupported")
    c.expect(P.preferredPreset(isSupported: { _ in false }) == nil, "preset: none supported → leave the default")
    c.expect(!P.presetPreference.contains("AVCaptureSessionPreset352x288")
             && !P.presetPreference.contains("AVCaptureSessionPreset320x240"),
             "preset: nothing below 480 lines (face gate floor would drop under ~58px)")

    // The reference MacBook Pro camera's format list (enumerated 2026-09-28).
    let mbp: [(width: Int, height: Int)] = [(640, 480), (1280, 720), (1760, 1328), (1328, 1760),
                                            (1552, 1552), (1920, 1080), (1080, 1920)]
    c.expect(P.preferredFormatIndex(dimensions: mbp) == 0, "format: MBP camera → native 640×480")
    c.expect(P.preferredFormatIndex(dimensions: [(1920, 1080), (1280, 720)]) == 1,
             "format: no VGA → smallest landscape ≥ 480 lines (1280×720)")
    c.expect(P.preferredFormatIndex(dimensions: [(320, 240), (480, 640), (1920, 1080)]) == 2,
             "format: sub-480 and portrait formats are never chosen")
    c.expect(P.preferredFormatIndex(dimensions: [(352, 288)]) == nil, "format: nothing qualifies → nil")

    let r = P.RateRange.init
    var pick = P.lowestRate(in: [r(15, 30)])
    c.expect(pick?.index == 0 && pick?.fps == 15, "fps: built-in 15–30 range → 15 fps (1 fps target clamped up)")
    pick = P.lowestRate(in: [r(30, 60), r(1, 30)])
    c.expect(pick?.index == 1 && pick?.fps == 1, "fps: the LOWEST range is chosen, not merely the first")
    pick = P.lowestRate(in: [r(0.5, 30)])
    c.expect(pick?.fps == 1, "fps: never below the 1 fps target even if the device could go lower")
    c.expect(P.lowestRate(in: []) == nil, "fps: no ranges → leave the device default")
    c.expect(P.lowestRate(in: [r(0, 0), r(.nan, 30)]) == nil, "fps: degenerate ranges ignored")

    // Post-start verification: BOTH min and max duration must equal the target.
    let t = 1.0 / 15
    c.expect(P.isPinned(minDuration: t, maxDuration: t, targetDuration: t),
             "pin: min = max = 1/15 s → pinned (15 fps)")
    c.expect(!P.isPinned(minDuration: 1.0 / 30, maxDuration: t, targetDuration: t),
             "pin: min 1/30 s, max 1/15 s (on-device revert, can run 30 fps) → NOT pinned, re-pin")
    c.expect(!P.isPinned(minDuration: 1.0 / 30, maxDuration: 1.0 / 30, targetDuration: t),
             "pin: both at 1/30 s → NOT pinned")
    c.expect(P.isPinned(minDuration: 0.0667, maxDuration: 0.0667, targetDuration: t),
             "pin: rounding within tolerance (0.0667 vs 1/15) → pinned")
    c.expect(!P.isPinned(minDuration: .nan, maxDuration: t, targetDuration: t)
             && !P.isPinned(minDuration: 0, maxDuration: 0, targetDuration: t),
             "pin: invalid CMTime (NaN / zero) → never pinned")
}
