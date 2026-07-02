import Foundation
import Combine
import NoDonutsCore

// Owner: krusty — the Settings model (ND-040). A thin, UserDefaults-backed
// ObservableObject that the SwiftUI Settings form binds to.
//
// LIVE-APPLY CONTRACT (the whole point of this type):
//   - `matchThreshold` and `antiSpoofEnabled` are written under the EXACT SAME
//     UserDefaults keys the recognizer reads every tick via `resolvedMatchThreshold`
//     / `resolvedAntiSpoofEnabled` (NoDonutsCore/Recognition). Writing them here
//     applies on the recognizer's next tick with no engine round-trip.
//   - `tickIntervalSeconds` and `graceSeconds` are consumed through `Config`: on any
//     change we fire `onChange`, and the AppDelegate rebuilds `Config` from this
//     store, calls `engine.updateConfig(_:)`, and the loop (which now reads
//     `self.config.tickIntervalSeconds` each iteration) picks up the new cadence.
//
// This type embeds NO policy and NO defaulting logic beyond clamping — the Core
// resolvers remain the single source of truth for what values are *valid* at read
// time. Clamping here just keeps the UI from ever writing a nonsensical value.
//
// Privacy: writes local UserDefaults only. No network, no telemetry.
@MainActor
final class SettingsStore: ObservableObject {
    /// UserDefaults keys. `matchThresholdKey` / `antiSpoofKey` MUST match the
    /// recognizer's resolver keys (see FaceEmbedding.swift / FaceLiveness.swift).
    private enum Keys {
        static let tickInterval = "tickIntervalSeconds"
        static let grace = "graceSeconds"
        static let matchThreshold = "matchThreshold"       // == resolvedMatchThreshold key
        static let antiSpoof = "antiSpoofEnabled"          // == resolvedAntiSpoofEnabled key
    }

    /// Sane clamp ranges, consistent with the Core resolvers and defaults.
    /// `matchThreshold` mirrors `resolvedMatchThreshold`'s accepted open interval
    /// (0.0, 1.0); we clamp to a slightly inset closed range so the slider can never
    /// write a value the resolver would reject and silently fall back on.
    enum Range {
        static let tick: ClosedRange<Double> = 0.5...10
        // Lower bound is 2s (not 0): there must always be some away-grace so a brief
        // look-away never locks instantly (code-review #3). Upper bound unchanged.
        static let grace: ClosedRange<Double> = 2...60
        static let threshold: ClosedRange<Double> = 0.05...0.95
    }

    private let defaults: UserDefaults

    /// Fired after any published value changes (and after UserDefaults is written).
    /// The AppDelegate sets this to rebuild Config + `engine.updateConfig(_:)`.
    /// Recognizer-consumed keys (threshold / anti-spoof) are already persisted before
    /// this fires, so a plain refresh is enough for them.
    var onChange: (() -> Void)?

    /// Reads the current trusted-SSID list. Injected by the AppDelegate (backed by the
    /// shared `TrustedNetworksStore`) so this type stays free of the concrete store.
    /// Used by `refresh()` to re-pull the list when the Settings window is (re-)shown.
    var trustedNetworksProvider: (() -> [String])?

    /// Guards against `onChange`/writes firing while we seed the initial values.
    private var isLoading = false

    // MARK: - Published tunables (each mirrors a UserDefaults key)

    @Published var tickIntervalSeconds: Double = Config().tickIntervalSeconds {
        didSet {
            let clamped = clamp(tickIntervalSeconds, to: Range.tick)
            if clamped != tickIntervalSeconds { tickIntervalSeconds = clamped; return }
            commit(clamped, key: Keys.tickInterval)
        }
    }

    @Published var graceSeconds: Double = Config().graceSeconds {
        didSet {
            let clamped = clamp(graceSeconds, to: Range.grace)
            if clamped != graceSeconds { graceSeconds = clamped; return }
            commit(clamped, key: Keys.grace)
        }
    }

    @Published var matchThreshold: Double = Config().matchThreshold {
        didSet {
            let clamped = clamp(matchThreshold, to: Range.threshold)
            if clamped != matchThreshold { matchThreshold = clamped; return }
            commit(clamped, key: Keys.matchThreshold)
        }
    }

    @Published var antiSpoofEnabled: Bool = true {
        didSet {
            guard !isLoading else { return }
            defaults.set(antiSpoofEnabled, forKey: Keys.antiSpoof)
            onChange?()
        }
    }

    // MARK: - Externally-sourced published state (refreshed on window show, code-review #2)

    // These two mirror state owned OUTSIDE this store (the macOS login-item registration
    // and the shared trusted-networks store). They can change while the Settings window
    // is closed-but-retained (e.g. the menu-bar "Trust this Wi-Fi" action, or a login-item
    // toggle elsewhere), and SwiftUI's `.onAppear` does NOT re-fire when an existing
    // NSWindow is merely re-fronted. `refresh()` (called every time the window is shown)
    // re-reads them here so the @Published change drives the view to reflect current truth.
    // They are NOT persisted here and do NOT fire `onChange` — pure display mirrors.

    /// Whether the app is registered to start at login (mirror of `LoginItem.isEnabled()`).
    @Published var startAtLogin: Bool = false

    /// The current trusted Wi-Fi SSIDs (mirror of the shared TrustedNetworksStore).
    @Published var trustedNetworks: [String] = []

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Re-read the externally-sourced state (login-item registration + trusted-network
    /// list) into the published mirrors. Call this EVERY time the Settings window is
    /// presented — not just on first creation — because a re-fronted NSWindow won't
    /// re-fire SwiftUI `.onAppear`, so this is the only thing that keeps those fields
    /// honest on reopen (code-review #2). Publishing here drives the SwiftUI view to
    /// update. The persisted tunables are already live via their own `@Published` didSets,
    /// so they don't need refreshing.
    func refresh() {
        startAtLogin = LoginItem.isEnabled()
        trustedNetworks = trustedNetworksProvider?() ?? trustedNetworks
    }

    /// Seed published values from UserDefaults, falling back to Config defaults when a
    /// key is absent or out of range. `isLoading` suppresses the didSet write-back so
    /// loading never mutates UserDefaults or fires `onChange`.
    private func load() {
        isLoading = true
        defer { isLoading = false }

        let d = Config()
        tickIntervalSeconds = readDouble(Keys.tickInterval, default: d.tickIntervalSeconds, in: Range.tick)
        graceSeconds = readDouble(Keys.grace, default: d.graceSeconds, in: Range.grace)
        matchThreshold = readDouble(Keys.matchThreshold, default: d.matchThreshold, in: Range.threshold)
        // Anti-spoof defaults ON when absent — matches resolvedAntiSpoofEnabled.
        antiSpoofEnabled = defaults.object(forKey: Keys.antiSpoof) == nil
            ? true
            : defaults.bool(forKey: Keys.antiSpoof)
    }

    // MARK: - Helpers

    /// Read a stored Double, falling back to `def` when absent, non-numeric, or out of
    /// range. Mirrors the Core resolvers' "absent or nonsensical → default" behavior.
    private func readDouble(_ key: String, default def: Double, in range: ClosedRange<Double>) -> Double {
        guard let n = defaults.object(forKey: key) as? NSNumber else { return def }
        let v = n.doubleValue
        guard range.contains(v) else { return def }
        return v
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Persist an already-clamped value and fire `onChange`. Suppressed while loading.
    /// Callers re-assign the published property first if clamping changed it, so by the
    /// time we reach here the stored value is the final, in-range one.
    private func commit(_ value: Double, key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        onChange?()
    }
}
