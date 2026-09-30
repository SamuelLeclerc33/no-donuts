import Foundation

// Owner: krusty — ND-123 privacy notice + explicit consent before face enrollment
// (ADR-0024 (d), Québec Law 25: biometric identity verification needs express consent).
//
// Pure decision logic + a small UserDefaults-backed record, AppKit-free so EngineCheck
// covers it. The App shows the notice; the decisions (does enrollment need it? does this
// launch need it?) live here.
//
// Privacy: the record holds only a notice version string, a decision word and a date.
// No biometric data.

/// The user's recorded answer to the privacy notice.
public enum PrivacyConsentRecord: Equatable, Sendable {
    /// Never answered (or consent was withdrawn, which clears the record).
    case none
    /// Clicked "I agree" to notice `version`.
    case agreed(version: String, at: Date)
    /// Chose "Decline and delete my face data" on notice `version` (recorded only after
    /// the delete succeeded).
    case declined(version: String, at: Date)

    /// Consent to `version` specifically. Agreeing to an older notice doesn't count.
    public func hasAgreed(to version: String) -> Bool {
        if case .agreed(let v, _) = self { return v == version }
        return false
    }

    /// Privacy-safe one-liner for Copy diagnostics (version + day, nothing else).
    public func diagnosticsDescription(currentVersion: String) -> String {
        let day: (Date) -> String = { date in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            f.timeZone = .current   // same calendar day the review window shows (review fix)
            return f.string(from: date)
        }
        switch self {
        case .none:
            return "not given (current notice \(currentVersion))"
        case .agreed(let v, let at):
            return v == currentVersion
                ? "agreed to notice \(v) on \(day(at))"
                : "agreed to OLD notice \(v) on \(day(at)); current is \(currentVersion), will ask again"
        case .declined(let v, let at):
            return "declined notice \(v) on \(day(at)) (face data deleted)"
        }
    }
}

/// Which privacy-notice window to show at launch, if any.
public enum PrivacyLaunchPrompt: Equatable, Sendable {
    /// Nothing to ask.
    case none
    /// A face enrollment is stored but there is no consent to the current notice: ask
    /// once (non-blocking; protection keeps running). Offers "I agree" or "Decline and
    /// delete my face data".
    case existingEnrollment
}

/// ND-123 consent decisions. No I/O.
public enum PrivacyConsentPolicy {
    /// Current notice version. **Bump it whenever the notice's substance changes** (what
    /// is stored, where, who can see it, how to delete it): everyone is asked again, at
    /// their next enrollment and, if already enrolled, at next launch. A wording-only fix
    /// that doesn't change what the user agrees to doesn't need a bump.
    public static let currentNoticeVersion = "2026-09-29"

    /// Must the notice be shown (and agreed to) before an enrollment capture may start?
    /// True unless the user agreed to the CURRENT version. A decline or an older
    /// agreement asks again: every enroll attempt is a fresh decision.
    public static func enrollmentNeedsConsent(record: PrivacyConsentRecord,
                                              currentVersion: String = currentNoticeVersion) -> Bool {
        !record.hasAgreed(to: currentVersion)
    }

    /// The launch-time check (ND-123 rule 2). Ask when face data is stored
    /// (`hasStoredEnrollment`: `.active`, or `.off(.modelMismatch)` whose stale vectors
    /// are still in the Keychain) without consent to the current notice.
    ///
    /// - `.unknown` identity (Keychain not read yet / unreadable) → `.none`: we can't tell
    ///   whether face data exists; the caller evaluates again once it's known.
    /// - A recorded decline doesn't suppress the prompt when face data is stored anyway
    ///   (e.g. restored from a backup): data held without consent always asks. After a
    ///   successful decline nothing is stored, so there's nothing to ask about.
    public static func launchPrompt(identity: IdentityStatus,
                                    record: PrivacyConsentRecord,
                                    currentVersion: String = currentNoticeVersion) -> PrivacyLaunchPrompt {
        guard identity != .unknown, identity.hasStoredEnrollment else { return .none }
        return record.hasAgreed(to: currentVersion) ? .none : .existingEnrollment
    }
}

/// Persists the consent record in the app's defaults domain (`com.nodonuts.app` inside
/// the bundle, `AppIdentity.defaultsDomain`). Tamperable like any user default; it
/// records the user's answer, it isn't a security control (the lock policy never
/// depends on it).
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe; no other state.
public final class PrivacyConsentStore: @unchecked Sendable {
    public enum Key {
        public static let version = "privacyConsent.noticeVersion"
        public static let decision = "privacyConsent.decision"
        public static let date = "privacyConsent.date"
    }
    private static let agreedWord = "agreed"
    private static let declinedWord = "declined"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored record. Anything incomplete or unrecognised reads as `.none`, so a
    /// damaged record asks again rather than counting as consent.
    public var record: PrivacyConsentRecord {
        guard let version = defaults.string(forKey: Key.version), !version.isEmpty,
              let decision = defaults.string(forKey: Key.decision),
              let date = defaults.object(forKey: Key.date) as? Date else { return .none }
        switch decision {
        case Self.agreedWord: return .agreed(version: version, at: date)
        case Self.declinedWord: return .declined(version: version, at: date)
        default: return .none
        }
    }

    public func recordAgreement(version: String = PrivacyConsentPolicy.currentNoticeVersion,
                                at date: Date = Date()) {
        write(version: version, decision: Self.agreedWord, date: date)
    }

    public func recordDecline(version: String = PrivacyConsentPolicy.currentNoticeVersion,
                              at date: Date = Date()) {
        write(version: version, decision: Self.declinedWord, date: date)
    }

    /// Withdraw consent: forget the answer (the caller deletes the enrollment first).
    public func clear() {
        defaults.removeObject(forKey: Key.version)
        defaults.removeObject(forKey: Key.decision)
        defaults.removeObject(forKey: Key.date)
    }

    private func write(version: String, decision: String, date: Date) {
        defaults.set(version, forKey: Key.version)
        defaults.set(decision, forKey: Key.decision)
        defaults.set(date, forKey: Key.date)
    }
}
