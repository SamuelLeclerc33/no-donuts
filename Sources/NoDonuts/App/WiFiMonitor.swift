import AppKit
import CoreWLAN
import CoreLocation
import NoDonutsCore
import os.log

// Owner: krusty — Wi-Fi trust monitoring (ND-036, ND-081).
// Reads the current Wi-Fi SSID AND the MAC of the Wi-Fi interface's default gateway
// (GatewayResolver: route + ARP tables), and asks the injected TrustedNetworksStore
// whether that {SSID, router} pair is trusted. On a trusted network the App layer
// pauses enforcement (the single enforcement gate in main.swift). FAIL-SAFE: an
// unknown SSID (Location denied, no Wi-Fi) or an unreadable router MAC → NOT trusted
// → enforcement stays ON. A hotspot that copies a trusted SSID has a different router
// MAC, so it isn't trusted (EC-20).
//
// Router reads (ND-081 review):
//   - They run OFF the main actor (detached task). The gate and the menu read the last
//     landed result and re-evaluate (onChange) when a new one lands. While a read is
//     pending, the answer is "not trusted" — EXCEPT the periodic 15 s re-verification
//     of an unchanged key {interface, SSID, BSSID} with a fresh verified read: that
//     answer is HELD for at most `RouterReadCache.holdWindow` (5 s, > the resolver's
//     2 s tool timeouts) while the re-read runs. Otherwise the gate flipped to
//     enforcing for every re-read and the camera resumed every 15 s on a trusted
//     network. A mismatching/unreadable re-read drops trust at once; an expired hold
//     re-evaluates the gate (not trusted). Wi-Fi events, wake and Trust never hold.
//   - TRUST NEEDS A FRESH READ: a result counts toward "trusted" only if it was
//     started after the last invalidation (`generation`) and is under
//     `freshnessLimit` old. Invalidation happens on every 15 s poll, on wake
//     (NSWorkspace.didWake), on every CoreWLAN SSID/BSSID/link event, and on the
//     user's Trust click. The key {interface, SSID, BSSID} can be cloned by an evil
//     twin, so a key match alone never reuses an old MAC.
//   - Failed reads are negative-cached for `negativeCacheLifetime` per key (so a menu
//     open can't spawn arp(8) over and over); Wi-Fi events and wake clear that cache.
//   - Reads happen only for an SSID that has a trusted entry, or on a Trust click.
//
// Location: modern macOS returns nil from ssid() unless Location auth is granted.
// We request it LAZILY — only when the user first invokes "Trust this Wi-Fi
// network" — so we never prompt at launch. An auth change re-fires onChange so the
// menu updates once the SSID becomes readable.
//
// Lives in the App target (CoreWLAN/CoreLocation); NoDonutsCore stays framework-
// light (ADR-0007). The store is the only Core dependency and it's injected.

/// Router check for the current network (ND-081), for the gate, menu and diagnostics.
public enum RouterCheck: Equatable {
    /// A fresh read returned this MAC (canonical form).
    case verified(String)
    /// A read is in flight (or about to start) → not trusted until it lands.
    case checking
    /// The last read for this network failed (negative-cached) → not trusted.
    case unreadable
    /// Not read: this SSID has no trusted entry, so the router doesn't matter.
    case notChecked
}

@MainActor
public final class WiFiMonitor: NSObject {
    private let store: TrustedNetworksStore
    private let locationManager = CLLocationManager()

    /// Fired when the SSID, the router check, or Location auth changes
    /// (menu/enforcement refresh).
    public var onChange: (() -> Void)?

    /// Fallback poll: CWEventDelegate events can be flaky depending on entitlements,
    /// so we also poll on a modest cadence to catch network changes we missed. Each
    /// poll also invalidates the router read (fresh read required for trust).
    /// Only runs while the trusted set is non-empty (poll is pointless otherwise;
    /// the ssidDidChange event still catches joins). Saves battery when unused.
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 15
    /// Fresh-read + negative-cache rules (Core, EngineCheck-covered): a verified read
    /// counts for 25 s at most and only within its generation; failures are cached 30 s.
    private var cache = RouterReadCache(freshnessLimit: 25, negativeLifetime: 30, holdWindow: 5)
    /// Re-evaluates the gate when a poll's hold expires without a landed re-read.
    private var holdExpiryWork: DispatchWorkItem?

    /// Last SSID we observed, used to fire onChange on a change.
    private var lastSSID: String?
    /// Last answer handed to the gate, so a landing read that changes it re-fires onChange.
    private var lastGateAnswer = false
    /// Last router check the menu saw (labels), same purpose.
    private var lastNotifiedCheck: RouterCheck = .notChecked

    /// The read in flight, if any.
    private var inFlight: (key: String, generation: Int)?
    /// A Trust click (or deferred Location-granted trust) waiting for its fresh read.
    private var pendingCapture: (ssid: String, key: String)?

    /// Re-check shortly after a Wi-Fi event: DHCP/ARP usually aren't populated yet
    /// the instant the SSID changes, so the first read often fails (fail-safe).
    private var followUpWork: [DispatchWorkItem] = []
    private var wakeObserver: NSObjectProtocol?
    /// Set when the user asked to trust the current network but the SSID was
    /// unreadable (Location not yet authorized). Consumed once auth is granted.
    private var pendingTrust = false

    private static let log = OSLog(subsystem: Log.subsystem, category: "wifi")

    public init(store: TrustedNetworksStore) {
        self.store = store
        super.init()
        locationManager.delegate = self
    }

    /// Begin monitoring. Prefers CoreWLAN events; the 15s poll is a robustness
    /// fallback that only runs while at least one network is trusted.
    public func start() {
        lastSSID = currentSSID()
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        // ND-081: a router change can happen without an SSID change (roam, swap).
        try? client.startMonitoringEvent(with: .bssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        // ND-081: sleep at home, wake on a clone: coalesced/missed Wi-Fi events must not
        // leave a pre-sleep read standing.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWiFiEvent() }
        }
        updatePollTimer()
        _ = routerCheck(for: lastSSID)   // kick the first read if relevant
    }

    /// Stop all monitoring. Symmetric counterpart to start(); safe to call more than once.
    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        followUpWork.forEach { $0.cancel() }
        followUpWork.removeAll()
        holdExpiryWork?.cancel()
        holdExpiryWork = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
    }

    /// Start/keep the poll only while the trusted set is non-empty; tear it down
    /// when empty. Idempotent — safe to call after any trusted-set change.
    private func updatePollTimer() {
        let shouldPoll = !store.all().isEmpty
        if shouldPoll {
            guard pollTimer == nil else { return }
            let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
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

    // MARK: - Router check (ND-081)

    /// {interface, SSID, BSSID} + the interface name, or nil without a Wi-Fi interface.
    private func currentKey() -> (key: String, interface: String)? {
        guard let iface = CWWiFiClient.shared().interface(), let name = iface.interfaceName else { return nil }
        return ("\(name)|\(iface.ssid() ?? "")|\(iface.bssid() ?? "")", name)
    }

    private func isRelevant(_ ssid: String?) -> Bool {
        guard let ssid, !ssid.isEmpty else { return false }
        return store.all().contains { $0.ssid == ssid }
    }


    /// Router check for `ssid` (normally `currentSSID()`). Never blocks: when a read is
    /// needed it starts one in the background and answers `.checking`. Only SSIDs with a
    /// trusted entry are read (a pending Trust click also shows `.checking`).
    public func routerCheck(for ssid: String?) -> RouterCheck {
        guard let (key, interface) = currentKey() else { return isRelevant(ssid) ? .unreadable : .notChecked }
        switch cache.lookup(key: key, now: Date()) {
        case .fresh(let mac): return .verified(mac)
        case .held(let mac):
            // Periodic re-read of an unchanged key: keep the previous answer while it runs.
            startRead(key: key, interface: interface)
            return .verified(mac)
        case .recentlyFailed: return .unreadable
        case .none: break
        }
        if pendingCapture?.key == key { return .checking }
        guard isRelevant(ssid) else { return .notChecked }
        startRead(key: key, interface: interface)
        return .checking
    }

    /// Start a background read unless one is already running for this key + generation.
    private func startRead(key: String, interface: String) {
        if let f = inFlight, f.key == key, f.generation == cache.generation { return }
        let gen = cache.generation
        inFlight = (key, gen)
        Task.detached(priority: .utility) { [weak self] in
            let result = GatewayResolver.resolve(interfaceName: interface)
            await self?.readLanded(key: key, generation: gen, result: result)
        }
    }

    private func readLanded(key: String, generation gen: Int, result: GatewayReadResult) {
        if let f = inFlight, f.key == key, f.generation == gen { inFlight = nil }
        // Started before an invalidation (poll / wake / Wi-Fi event / Trust click) or
        // for a network we've left: discard, and re-read for the current state.
        guard currentKey()?.key == key,
              cache.record(key: key, generation: gen, mac: result.mac, now: Date()) else {
            if let pc = pendingCapture, let now = currentKey(), pc.key == now.key {
                startRead(key: now.key, interface: now.interface)
            } else {
                pendingCapture = nil
                _ = routerCheck(for: currentSSID())
            }
            notifyIfChanged()
            return
        }
        if let pc = pendingCapture, pc.key == key {
            pendingCapture = nil
            if store.trust(ssid: pc.ssid, gatewayMAC: result.mac) {
                updatePollTimer()
            } else {
                os_log("trust refused: router MAC unreadable", log: Self.log, type: .default)
            }
            onChange?()
            recordNotified()
            return
        }
        notifyIfChanged()
    }

    /// New generation: no earlier read can count toward trust any more.
    /// `clearFailures` (Wi-Fi events, wake, Trust click) also drops the negative cache.
    private func invalidate(clearFailures: Bool) {
        cache.invalidate(clearFailures: clearFailures)
    }

    /// Fire onChange when the gate's answer or the menu's router label would change.
    private func notifyIfChanged() {
        let ssid = currentSSID()
        let check = routerCheck(for: ssid)
        let trusted = isTrusted(ssid: ssid, check: check)
        guard ssid != lastSSID || trusted != lastGateAnswer || check != lastNotifiedCheck else { return }
        lastSSID = ssid
        onChange?()
        recordNotified()
    }

    private func recordNotified() {
        let ssid = currentSSID()
        lastSSID = ssid
        lastNotifiedCheck = routerCheck(for: ssid)
    }

    private func isTrusted(ssid: String?, check: RouterCheck) -> Bool {
        guard case .verified(let mac) = check else { return false }
        return store.isTrusted(ssid: ssid, gatewayMAC: mac)
    }

    /// Whether the current network is user-trusted: SSID AND a FRESH router MAC must
    /// match one entry (ND-081). Fail-safe: unknown SSID, unreadable router, or a read
    /// still pending → NOT trusted → enforcement stays ON.
    public var isOnTrustedNetwork: Bool {
        let ssid = currentSSID()
        let answer = isTrusted(ssid: ssid, check: routerCheck(for: ssid))
        lastGateAnswer = answer
        return answer
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
    /// - If the SSID is readable and this SSID + (fresh) router is trusted: untrust
    ///   it now.
    /// - If the SSID is readable otherwise: capture the router with a FRESH
    ///   background read, and trust {SSID, MAC} when it lands. No readable MAC → no
    ///   trust (the menu then shows "router can't be verified") and enforcement stays
    ///   ON. Trusting a legacy SSID-only entry is the re-confirm: it binds the entry to
    ///   this router.
    /// - If the SSID is unreadable AND Location is not-determined: record a
    ///   pending trust and prompt for Location. When auth is granted, the
    ///   delegate reads the now-available SSID and captures the router. This fixes
    ///   the "first click is a no-op / must click twice" bug.
    /// - If unreadable for any other reason (Location denied, no Wi-Fi): nothing
    ///   to do; fail-safe keeps enforcement ON.
    ///
    /// Fires onChange for every effective change so the gate + menu stay honest.
    public func requestTrustCurrentNetwork(using store: TrustedNetworksStore) {
        if let ssid = currentSSID(), !ssid.isEmpty {
            pendingTrust = false
            if case .verified(let mac) = routerCheck(for: ssid),
               store.isTrusted(ssid: ssid, gatewayMAC: mac) {
                store.untrust(ssid: ssid, gatewayMAC: mac)
                updatePollTimer()
                onChange?()
                recordNotified()
                return
            }
            beginCapture(ssid: ssid)
            return
        }
        // SSID unreadable — if we've never asked for Location, ask now and defer
        // the actual trust to the auth-granted callback.
        if locationManager.authorizationStatus == .notDetermined {
            pendingTrust = true
            requestLocationIfNeeded()
        }
    }

    /// Trust click: fresh read (new generation, failures cleared), trust on landing.
    private func beginCapture(ssid: String) {
        guard let (key, interface) = currentKey() else {
            os_log("trust refused: no Wi-Fi interface", log: Self.log, type: .default)
            return
        }
        invalidate(clearFailures: true)
        pendingCapture = (ssid, key)
        startRead(key: key, interface: interface)
        onChange?()          // menu shows "checking router…"
        recordNotified()
    }

    /// 15 s poll: new generation (a fresh read is required for trust), then re-read if
    /// relevant. The previous verified answer is held (≤ holdWindow) for an unchanged
    /// key so the gate doesn't flap. Failures stay negative-cached so a failing router
    /// isn't re-spawned more than every `negativeCacheLifetime`.
    private func poll() {
        cache.reverify(now: Date())
        _ = routerCheck(for: currentSSID())
        notifyIfChanged()
        holdExpiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notifyIfChanged() }
        }
        holdExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cache.holdWindow + 0.1, execute: work)
    }

    /// A Wi-Fi event or wake: new generation, failures cleared, re-read now, and again
    /// at +3 s and +10 s to catch the router once DHCP/ARP settle.
    fileprivate func handleWiFiEvent() {
        invalidate(clearFailures: true)
        _ = routerCheck(for: currentSSID())
        notifyIfChanged()
        followUpWork.forEach { $0.cancel() }
        followUpWork = [3.0, 10.0].map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.followUp() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// Follow-up after an event: retry only if we don't already have a good read.
    private func followUp() {
        if let key = currentKey()?.key, case .recentlyFailed = cache.lookup(key: key, now: Date()) {
            cache.clearFailure(for: key)
        }
        _ = routerCheck(for: currentSSID())
        notifyIfChanged()
    }
}

// CoreWLAN event callbacks: SSID / BSSID / link changed (join, leave, roam). Delivered
// off the main thread → hop to main and re-evaluate (fresh router read).
extension WiFiMonitor: CWEventDelegate {
    public nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.handleWiFiEvent() }
    }
    public nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.handleWiFiEvent() }
    }
    public nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.handleWiFiEvent() }
    }
}

// Location auth change: once granted, ssid() starts returning a value, so refresh
// and notify (the menu/enforcement re-evaluate).
extension WiFiMonitor: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Complete a first-run trust that was deferred until the SSID became
            // readable (the "must click twice" fix). Only trusts if we now have a
            // real SSID AND the fresh router read succeeds (ND-081); otherwise the
            // pending intent is dropped (fail-safe).
            if self.pendingTrust, let ssid = self.currentSSID(), !ssid.isEmpty {
                self.pendingTrust = false
                self.beginCapture(ssid: ssid)
            } else if self.isLocationGranted {
                // Auth resolved without a readable SSID (e.g. Wi-Fi off) — drop
                // the pending intent so a later join doesn't silently auto-trust.
                self.pendingTrust = false
            }
            self.lastSSID = self.currentSSID()
            self.onChange?()
            self.recordNotified()
        }
    }
}
