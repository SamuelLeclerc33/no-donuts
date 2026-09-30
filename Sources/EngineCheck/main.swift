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
    await runLivenessChecks(c)
    await runThresholdAnalysisChecks(c)
    await runScreenLockerChainChecks(c)
    await runFrameFreshnessChecks(c)
    await runCameraTrustPolicyChecks(c)
    await runCaptureFormatPolicyChecks(c)
    await runProtectionAuditChecks(c)
    await runFaceQualityGateChecks(c)
    await runFaceQualityVersionChecks(c)
    await runEnrollmentQualityChecks(c)
    await runEnrollmentInputValidationChecks(c)
    await runPauseLivenessPolicyChecks(c)
    await runStartupReminderChecks(c)
    await runLauncherHandoverChecks(c)
    await runSessionSuspendChecks(c)
    await runTickScheduleChecks(c)
    await runEngineHardeningChecks(c)
    await runCoreMLOutputShapeChecks(c)
    await runCoreMLEmbeddingHelperChecks(c)
    await runDeferredEmbedderChecks(c)
    await runAppIdentityChecks(c)
    await runEnrollmentDriftChecks(c)
    await runMultiFaceSelectionChecks(c)
    await runMultiFaceEmbedderAPIChecks(c)
    await runMultiFaceRecognizerChecks(c)
    await runMultiFaceLivenessChecks(c)
    await runMultiFaceReviewChecks(c)
    await runMultiFaceEnrollmentChecks(c)
    await runSettingsSliderChecks(c)
    await runPrivacyConsentChecks(c)

    print("\n\(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

/// Remove the throwaway UserDefaults suites EngineCheck creates. `removePersistentDomain`
/// empties a domain but cfprefsd leaves the .plist behind, and UUID-named suites would
/// otherwise pile up in ~/Library/Preferences (found 843 of them). Only files with
/// EngineCheck's OWN prefixes are touched — never the app's `com.nodonuts.app`.
func cleanUpTestPreferenceFiles() {
    let prefixes = ["com.nodonuts.enginecheck.", "nd062.check."]
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    for name in names where name.hasSuffix(".plist") && prefixes.contains(where: { name.hasPrefix($0) }) {
        let domain = String(name.dropLast(".plist".count))
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? fm.removeItem(at: dir.appendingPathComponent(name))
    }
}

let ok = await runAll()
cleanUpTestPreferenceFiles()
exit(ok ? 0 : 1)
