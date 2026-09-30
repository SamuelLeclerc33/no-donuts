import Foundation
import NoDonutsCore

// Owner: krusty — ND-123: privacy notice + explicit consent before enrollment.

@MainActor
func runPrivacyConsentChecks(_ c: Checks) async {
    print("\nND-123 privacy consent checks:")
    let v1 = "v1", v2 = "v2"
    let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // Enrollment gate: only an agreement to the CURRENT notice lets a capture start.
    do {
        c.expect(PrivacyConsentPolicy.enrollmentNeedsConsent(record: .none, currentVersion: v1),
                 "ND-123: no record → notice before enrollment")
        c.expect(!PrivacyConsentPolicy.enrollmentNeedsConsent(record: .agreed(version: v1, at: day), currentVersion: v1),
                 "ND-123: agreed to the current notice → enrollment proceeds")
        c.expect(PrivacyConsentPolicy.enrollmentNeedsConsent(record: .agreed(version: v1, at: day), currentVersion: v2),
                 "ND-123: agreed to an older notice → asked again (version bump)")
        c.expect(PrivacyConsentPolicy.enrollmentNeedsConsent(record: .declined(version: v1, at: day), currentVersion: v1),
                 "ND-123: a decline asks again at the next enroll attempt")
    }

    // Launch check: only stored face data without current consent asks.
    do {
        let mismatch = IdentityStatus.off(.modelMismatch(stored: "old", active: "new"))
        let missing = IdentityStatus.off(.enrollmentMissing(expected: "old"))
        let agreed = PrivacyConsentRecord.agreed(version: v1, at: day)
        let declined = PrivacyConsentRecord.declined(version: v1, at: day)
        func prompt(_ id: IdentityStatus, _ r: PrivacyConsentRecord, _ v: String = v1) -> PrivacyLaunchPrompt {
            PrivacyConsentPolicy.launchPrompt(identity: id, record: r, currentVersion: v)
        }
        c.expect(prompt(.active, .none) == .existingEnrollment,
                 "ND-123: enrolled, no consent → ask at launch")
        c.expect(prompt(.active, agreed) == .none, "ND-123: enrolled + agreed → no launch notice")
        c.expect(prompt(.active, agreed, v2) == .existingEnrollment,
                 "ND-123: enrolled + agreed to an older notice → ask at launch")
        c.expect(prompt(mismatch, .none) == .existingEnrollment,
                 "ND-123: stale vectors still stored (model mismatch) count as face data")
        c.expect(prompt(.notEnrolled, .none) == .none, "ND-123: never enrolled → no launch notice")
        c.expect(prompt(.notEnrolled, declined) == .none,
                 "ND-123: declined (data deleted) → no re-ask every launch")
        c.expect(prompt(missing, .none) == .none,
                 "ND-123: enrollment missing (nothing stored) → no launch notice")
        c.expect(prompt(.unknown, .none) == .none,
                 "ND-123: Keychain not read yet → no launch notice (evaluated once known)")
        c.expect(prompt(.active, declined) == .existingEnrollment,
                 "ND-123: face data stored despite a decline (e.g. restored) → ask again")
    }

    // Store round-trip, damaged records, withdrawal.
    do {
        let suite = "com.nodonuts.enginecheck.privacyconsent"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PrivacyConsentStore(defaults: defaults)
        c.expect(store.record == .none, "ND-123: empty defaults → no consent")
        store.recordAgreement(version: v1, at: day)
        c.expect(store.record == .agreed(version: v1, at: day), "ND-123: agreement persists version + date")
        c.expect(!PrivacyConsentPolicy.enrollmentNeedsConsent(record: PrivacyConsentStore(defaults: defaults).record,
                                                              currentVersion: v1),
                 "ND-123: a fresh store instance reads the agreement back")
        store.recordDecline(version: v2, at: day)
        c.expect(store.record == .declined(version: v2, at: day), "ND-123: a decline replaces the agreement")
        store.clear()
        c.expect(store.record == .none, "ND-123: withdrawing clears the record")
        defaults.set("agreed", forKey: PrivacyConsentStore.Key.decision)
        defaults.set(day, forKey: PrivacyConsentStore.Key.date)
        c.expect(store.record == .none, "ND-123: agreement without a version is not consent")
        defaults.set(v1, forKey: PrivacyConsentStore.Key.version)
        defaults.set("yes", forKey: PrivacyConsentStore.Key.decision)
        c.expect(store.record == .none, "ND-123: an unknown decision word is not consent")
        defaults.set("agreed", forKey: PrivacyConsentStore.Key.decision)
        defaults.set("2026-09-29", forKey: PrivacyConsentStore.Key.date)
        c.expect(store.record == .none, "ND-123: a date that isn't a Date is not consent")
        defaults.removePersistentDomain(forName: suite)
    }

    // Diagnostics line: version + day only.
    do {
        let line = PrivacyConsentRecord.agreed(version: v1, at: day).diagnosticsDescription(currentVersion: v2)
        c.expect(line.contains("OLD") && line.contains(v1) && line.contains(v2),
                 "ND-123: diagnostics flags consent to an old notice")
        c.expect(PrivacyConsentRecord.none.diagnosticsDescription(currentVersion: v1).hasPrefix("not given"),
                 "ND-123: diagnostics says when consent isn't given")
        c.expect(!PrivacyConsentPolicy.currentNoticeVersion.isEmpty, "ND-123: a notice version is set")
        // Review fix: the diagnostics day is the LOCAL calendar day (matches the review window).
        let late = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: late)
        let localDay = String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        c.expect(PrivacyConsentRecord.agreed(version: v1, at: late).diagnosticsDescription(currentVersion: v1).contains(localDay),
                 "ND-123: diagnostics consent day uses the local time zone (23:30 local stays that day)")
    }
}
