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
//   - The match threshold is PER-MODEL (ND-076): it lives under the ACTIVE embedder's
//     `descriptor.thresholdOverrideKey`, clamped to `descriptor.matchThresholdRange`.
//     Loading NEVER writes that key — only a user edit does — so an untouched install
//     keeps following the model's `defaultMatchThreshold` as the model is retuned, and
//     "Reset to default" (`resetMatchThreshold()`) simply removes the key.
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
    /// UserDefaults keys. `antiSpoofKey` MUST match the recognizer's resolver key
    /// (FaceLiveness.swift). The threshold key is per-model — see `thresholdKey`.
    private enum Keys {
        static let tickInterval = "tickIntervalSeconds"
        static let grace = "graceSeconds"
        static let antiSpoof = "antiSpoofEnabled"          // == resolvedAntiSpoofEnabled key
    }

    /// Sane clamp ranges for the Config-backed tunables. The match-threshold range is
    /// NOT here: it belongs to the active model (`thresholdRange`), so the slider can
    /// never write a value the resolver would reject and silently fall back on.
    enum Range {
        static let tick: ClosedRange<Double> = 0.5...10
        // Lower bound is 2s (not 0): there must always be some away-grace so a brief
        // look-away never locks instantly (code-review #3). Upper bound unchanged.
        static let grace: ClosedRange<Double> = 2...60
    }

    private let defaults: UserDefaults

    /// The ACTIVE embedder's descriptor (ND-076). Owns the threshold key, range and default.
    private let descriptor: FaceEmbeddingModelDescriptor

    /// Per-model override key, e.g. `matchThreshold.facenet-vggface2-v1`.
    private var thresholdKey: String { descriptor.thresholdOverrideKey }

    // MARK: - Model threshold facts (read-only, for the Settings caption / slider)

    /// The accepted threshold range for the active model — the slider's bounds.
    var thresholdRange: ClosedRange<Double> { descriptor.matchThresholdRange }
    /// The active model's own default threshold (what "Reset to default" returns to).
    var modelDefaultThreshold: Double { descriptor.defaultMatchThreshold }
    /// Whether the model default has been measured (ND-056) or is still provisional.
    var thresholdIsTuned: Bool { descriptor.thresholdIsTuned }

    /// True when ANY value is stored under the per-model key — including one the resolver
    /// rejects as out of range — so "Reset to default" can always clear it.
    @Published private(set) var hasThresholdOverride: Bool = false

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

    /// Seeded in `load()` from the resolver's EFFECTIVE value (a rejected stored value
    /// shows the model default and is left untouched). Only a user edit persists.
    @Published var matchThreshold: Double = 0 {
        didSet {
            guard !isLoading else { return }
            let clamped = clamp(matchThreshold, to: thresholdRange)
            if clamped != matchThreshold { matchThreshold = clamped; return }
            commit(clamped, key: thresholdKey)
            hasThresholdOverride = true
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

    init(descriptor: FaceEmbeddingModelDescriptor, defaults: UserDefaults = .standard) {
        self.descriptor = descriptor
        self.defaults = defaults
        load()
    }

    /// "Reset to default" (ND-076): remove the per-model override so the recognizer falls
    /// back to the model's `defaultMatchThreshold`, then re-seed the slider from the
    /// resolver without writing anything back. Fires `onChange` like any other edit.
    func resetMatchThreshold() {
        defaults.removeObject(forKey: thresholdKey)
        loadMatchThreshold()
        onChange?()
    }

    /// Re-read the externally-sourced state (login-item registration + trusted-network
    /// list) into the published mirrors. Call this EVERY time the Settings window is
    /// presented — not just on first creation — because a re-fronted NSWindow won't
    /// re-fire SwiftUI `.onAppear`, so this is the only thing that keeps those fields
    /// honest on reopen (code-review #2). Publishing here drives the SwiftUI view to
    /// update. The persisted tunables are already live via their own `@Published` didSets,
    /// so they don't need refreshing.
    func refresh() {
        // Re-read the threshold too: it may have been changed via `defaults write` while
        // the window was closed. Read-only — never persists.
        loadMatchThreshold()
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
        loadMatchThreshold(alreadyLoading: true)
        // Anti-spoof defaults ON when absent — matches resolvedAntiSpoofEnabled.
        antiSpoofEnabled = defaults.object(forKey: Keys.antiSpoof) == nil
            ? true
            : defaults.bool(forKey: Keys.antiSpoof)
    }

    /// Seed `matchThreshold` from the SAME resolver the recognizer uses (so the slider
    /// shows what is actually in effect — the model default if the stored value is absent
    /// or rejected) and mirror whether a key is stored. Never writes UserDefaults.
    private func loadMatchThreshold(alreadyLoading: Bool = false) {
        if !alreadyLoading { isLoading = true }
        defer { if !alreadyLoading { isLoading = false } }
        matchThreshold = resolvedMatchThreshold(for: descriptor, defaults: defaults)
        hasThresholdOverride = defaults.object(forKey: thresholdKey) != nil
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
