import Foundation
import CoreWLAN
import CoreLocation
import NoDonutsCore

// Owner: krusty — Wi-Fi trust monitoring (ND-036).
// Reads the current Wi-Fi SSID and asks the injected TrustedNetworksStore whether
// it's trusted. On a trusted network the App layer pauses enforcement (the single
// enforcement gate in main.swift). FAIL-SAFE: an unknown SSID (Location denied,
// no Wi-Fi, hardware) → isTrusted(nil)==false → NOT trusted → enforcement stays ON.
//
// Location: modern macOS returns nil from ssid() unless Location auth is granted.
// We request it LAZILY — only when the user first invokes "Trust this Wi-Fi
// network" — so we never prompt at launch. An auth change re-fires onChange so the
// menu updates once the SSID becomes readable.
//
// Lives in the App target (CoreWLAN/CoreLocation); NoDonutsCore stays framework-
// light (ADR-0007). The store is the only Core dependency and it's injected.
@MainActor
public final class WiFiMonitor: NSObject {
    private let store: TrustedNetworksStore
    private let locationManager = CLLocationManager()

    /// Fired when the SSID or Location auth changes (menu/enforcement refresh).
    public var onChange: (() -> Void)?

    /// Fallback poll: CWEventDelegate events can be flaky depending on entitlements,
    /// so we also poll on a modest cadence to catch network changes we missed.
    /// Only runs while the trusted set is non-empty (poll is pointless otherwise;
    /// the ssidDidChange event still catches joins). Saves battery when unused.
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 15
    /// Last SSID we observed, used to suppress no-op onChange from the poll.
    private var lastSSID: String?
    /// Set when the user asked to trust the current network but the SSID was
    /// unreadable (Location not yet authorized). Consumed once auth is granted.
    private var pendingTrust = false

    public init(store: TrustedNetworksStore) {
        self.store = store
        super.init()
        locationManager.delegate = self
    }

    /// Begin monitoring SSID changes. Prefers CoreWLAN's ssidDidChange event;
    /// the 15s poll is a robustness fallback that only runs while at least one
    /// network is trusted (both paths funnel through refreshIfChanged()).
    public func start() {
        lastSSID = currentSSID()
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        updatePollTimer()
    }

    /// Stop all monitoring. Invalidates the poll timer and stops CoreWLAN event
    /// monitoring. Symmetric counterpart to start(); safe to call more than once.
    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
    }

    /// Start/keep the poll only while the trusted set is non-empty; tear it down
    /// when empty. Idempotent — safe to call after any trusted-set change.
    private func updatePollTimer() {
        let shouldPoll = !store.all().isEmpty
        if shouldPoll {
            guard pollTimer == nil else { return }
            let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshIfChanged() }
            }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// The current Wi-Fi SSID, or nil if unknown (no Wi-Fi, Location denied, etc).
    public func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Whether the current network is user-trusted. Fail-safe: unknown SSID →
    /// isTrusted(nil)==false → NOT trusted → enforcement stays ON.
    public var isOnTrustedNetwork: Bool {
        store.isTrusted(currentSSID())
    }

    /// Current Location authorization (drives the menu's "grant Location" hint).
    public func authorizationStatus() -> CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    /// Whether Location is granted such that CoreWLAN will return an SSID. On
    /// macOS the granted case is `.authorizedAlways`; `.authorized` is the
    /// deprecated iOS alias, kept for back-compat. Single source of truth so the
    /// menu hint and any future callers agree.
    public var isLocationGranted: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorized: return true
        default: return false
        }
    }

    /// Request Location auth ONLY when still not-determined. Called lazily the
    /// first time the user tries to trust the current network — never at launch.
    public func requestLocationIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Toggle trust for the CURRENT Wi-Fi network, handling the first-run case
    /// where the SSID isn't yet readable because Location is not-determined.
    ///
    /// - If the SSID is readable: toggle it (untrust if already trusted, else
    ///   trust). Untrust always works synchronously (the SSID is known if it was
    ///   trusted). This is the steady-state path.
    /// - If the SSID is unreadable AND Location is not-determined: record a
    ///   pending trust and prompt for Location. When auth is granted, the
    ///   delegate reads the now-available SSID and completes the add. This fixes
    ///   the "first click is a no-op / must click twice" bug.
    /// - If unreadable for any other reason (Location denied, no Wi-Fi): nothing
    ///   to do; fail-safe keeps enforcement ON.
    ///
    /// Fires onChange for every effective change so the gate + menu stay honest.
    public func requestTrustCurrentNetwork(using store: TrustedNetworksStore) {
        if let ssid = currentSSID(), !ssid.isEmpty {
            if store.isTrusted(ssid) {
                store.remove(ssid)
            } else {
                store.add(ssid)
            }
            pendingTrust = false
            updatePollTimer()
            onChange?()
            return
        }
        // SSID unreadable — if we've never asked for Location, ask now and defer
        // the actual trust to the auth-granted callback.
        if locationManager.authorizationStatus == .notDetermined {
            pendingTrust = true
            requestLocationIfNeeded()
        }
    }

    /// Re-read the SSID and fire onChange only if it actually changed (poll path).
    private func refreshIfChanged() {
        let now = currentSSID()
        guard now != lastSSID else { return }
        lastSSID = now
        onChange?()
    }
}

// CoreWLAN event callback: SSID changed (join/leave/roam). Delivered off the main
// thread → hop to main and re-evaluate through the same change path as the poll.
extension WiFiMonitor: CWEventDelegate {
    public nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refreshIfChanged() }
    }
}

// Location auth change: once granted, ssid() starts returning a value, so refresh
// the SSID cache and notify (the menu/enforcement re-evaluate).
extension WiFiMonitor: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.lastSSID = self.currentSSID()
            // Complete a first-run trust that was deferred until the SSID became
            // readable (the "must click twice" fix). Only trusts if we now have
            // a real SSID; otherwise the pending intent is dropped (fail-safe).
            if self.pendingTrust, let ssid = self.currentSSID(), !ssid.isEmpty {
                self.store.add(ssid)
                self.pendingTrust = false
                self.updatePollTimer()
            } else if self.isLocationGranted {
                // Auth resolved without a readable SSID (e.g. Wi-Fi off) — drop
                // the pending intent so a later join doesn't silently auto-trust.
                self.pendingTrust = false
            }
            self.onChange?()
        }
    }
}
