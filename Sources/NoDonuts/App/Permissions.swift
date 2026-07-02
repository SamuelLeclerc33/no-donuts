import AppKit

// Owner: krusty — permission priming UX.
// Trust rule: be honest about what we need and why. The app needs only the
// camera (to see you're at your Mac); frames are checked on-device and never
// recorded or sent anywhere. The screen lock no longer requires Accessibility
// (ADR-0010). At first launch we show a one-time explainer, then fire the
// camera prompt via the camera controller.

/// Thin facade for the app's first-run priming state. No policy lives here —
/// callers (main.swift) decide *when* to prime; this just exposes the
/// first-run flag.
@MainActor
enum Permissions {
    /// UserDefaults key recording that we've shown the one-time explainer.
    private static let didPrimeKey = "com.nodonuts.didPrimePermissions"

    /// First-run flag: have we already shown the explainer? Backed by
    /// UserDefaults so it persists across launches.
    static var hasPrimedPermissions: Bool {
        get { UserDefaults.standard.bool(forKey: didPrimeKey) }
        set { UserDefaults.standard.set(newValue, forKey: didPrimeKey) }
    }

    /// UserDefaults key recording that we've shown the one-time Keychain explainer.
    private static let didExplainKeychainKey = "com.nodonuts.didExplainKeychain"

    /// Have we shown the one-time "we store your face signature in the Keychain,
    /// macOS may ask you to Allow" explainer? macOS's Keychain-access prompt has no
    /// custom-text hook (unlike TCC), so we set expectations ourselves before the
    /// first enrollment write. Persisted across launches.
    static var hasExplainedKeychain: Bool {
        get { UserDefaults.standard.bool(forKey: didExplainKeychainKey) }
        set { UserDefaults.standard.set(newValue, forKey: didExplainKeychainKey) }
    }
}
