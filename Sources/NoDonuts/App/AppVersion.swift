import Foundation

// Owner: krusty — the running build's version, for the menu and Settings (ADR-0021:
// no in-app updater, so the user must be able to see which build they run).
// scripts/make-app.sh stamps CFBundleShortVersionString (git describe) and
// CFBundleVersion (commit count) into the bundle's Info.plist.

enum AppVersion {
    /// CFBundleShortVersionString, nil when absent (e.g. a bare `swift run`).
    static var shortVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// CFBundleVersion, nil when absent.
    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "No Donuts 0.4.0 (123)". Without a bundle Info.plist: "No Donuts (development build)".
    static var displayString: String {
        guard let shortVersion, !shortVersion.isEmpty else {
            return String(localized: "No Donuts (development build)")
        }
        let build = (self.build?.isEmpty == false) ? self.build! : "?"
        return String(localized: "No Donuts \(shortVersion) (\(build))")
    }

    /// "0.4.0 (123)" for a labeled row.
    static var versionAndBuild: String {
        guard let shortVersion, !shortVersion.isEmpty else {
            return String(localized: "development build")
        }
        let build = (self.build?.isEmpty == false) ? self.build! : "?"
        return "\(shortVersion) (\(build))"
    }
}
