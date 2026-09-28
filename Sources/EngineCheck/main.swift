import Foundation
import NoDonutsCore

// EngineCheck entry point. The checks live in per-domain files (ND-114); they run
// here in the original order so output (and pass count) is unchanged. Fakes and
// helpers are in Support.swift.

@MainActor
func runAll() async -> Bool {
    let c = Checks()
    print("PresenceEngine checks:")
    await runPresenceBasicsChecks(c)
    await runCameraUnavailableEscalationChecks(c)
    await runAbsenceAndStrangerChecks(c)
    await runLockFailureRetryChecks(c)
    await runRecognitionErrorHoldChecks(c)
    await runRecoveryManualLockAndPauseChecks(c)
    await runTrustedDisableSuspendAndConfigChecks(c)
    await runWiFiTrustChecks(c)
    await runRecognitionCoreChecks(c)
    await runEmbeddingVersioningChecks(c)
    await runIdentityStatusChecks(c)
    await runAntiSpoofChecks(c)
    await runLivenessAndRecognitionSettingsChecks(c)
    await runThresholdAnalysisChecks(c)
    await runScreenLockerChainChecks(c)
    await runFrameFreshnessChecks(c)
    await runCameraTrustPolicyChecks(c)
    await runProtectionAuditChecks(c)
    await runFaceQualityGateChecks(c)
    await runFaceQualityVersionChecks(c)
    await runEnrollmentQualityChecks(c)
    await runEnrollmentInputValidationChecks(c)
    await runPauseLivenessPolicyChecks(c)
    await runStartupReminderChecks(c)
    await runLauncherHandoverChecks(c)
    await runSessionSuspendChecks(c)
    await runEngineHardeningChecks(c)
    await runCoreMLOutputShapeChecks(c)
    await runAppIdentityChecks(c)

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

let ok = await runAll()
exit(ok ? 0 : 1)
