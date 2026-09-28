import Foundation

/// The app's identity strings, in one place (ND-065). Owner: gordon.
///
/// Every Logger subsystem, UserDefaults suite and Keychain service in the code base
/// reads from here instead of repeating the `"com.nodonuts.app"` literal.
///
/// **Decision (ND-065): the Keychain service is FIXED, forever.**
/// `keychainService` is deliberately a separate constant from `bundleID`, even though
/// the two strings are equal today. The enrollment item (`EnrollmentStore`) is looked up
/// by this service string. If it tracked the bundle id, renaming the bundle id for
/// distribution (ND-050) would make every existing enrollment invisible: the item would
/// still sit in the Keychain, but the app would read "not enrolled" and the user would
/// silently lose their face signature. So:
///
/// - `keychainService` stays `"com.nodonuts.app"` even if `bundleID` changes.
/// - Never derive it from `Bundle.main.bundleIdentifier` or from `bundleID`.
/// - Changing it needs an ADR and a migration that reads the old item, writes the new
///   one, then deletes the old one.
///
/// Note that a new bundle id is also a new code identity, so the Keychain item's ACL
/// may still prompt once after a rename. The fixed service string avoids data loss; it
/// does not avoid that one prompt. ND-050 must plan for it.
///
/// `bundleID` must match `CFBundleIdentifier` in `Resources/Info.plist`. The logging
/// subsystem and the app's defaults domain follow the bundle id, because that is what
/// `log stream` and `defaults read` users expect, and losing old log lines or defaults
/// on a rename is harmless.
///
/// Privacy: static identifiers only, no user data.
public enum AppIdentity {
    /// `CFBundleIdentifier` of the app. Keep in sync with `Resources/Info.plist`.
    public static let bundleID = "com.nodonuts.app"

    /// Unified-logging subsystem for every No Donuts logger (`Log.subsystem` aliases it).
    public static let logSubsystem = bundleID

    /// The app's UserDefaults domain (what `UserDefaults.standard` resolves to inside the
    /// app). Off-app tools such as FaceScore open it by name to read the app's settings.
    public static let defaultsDomain = bundleID

    /// Keychain `kSecAttrService` for the enrollment item. FIXED at `"com.nodonuts.app"`
    /// and independent of `bundleID` — see the type doc. Do not change it.
    public static let keychainService = "com.nodonuts.app"
}
