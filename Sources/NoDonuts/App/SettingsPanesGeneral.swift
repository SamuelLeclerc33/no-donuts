import SwiftUI
import NoDonutsCore

// Owner: krusty — Settings panes: General, Trusted Wi-Fi, Timing (ND-117). Controls
// moved from the old single-form Settings (ND-040/081/082); semantics unchanged.

// MARK: - General

/// Start at login (ND-082 managed-copy handling) and how pausing works. Pausing itself
/// stays in the menu bar (ND-035): the pane only explains it.
@MainActor
struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions

    @State private var loginError: String?

    var body: some View {
        SettingsPane(category: .general) {
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(
                    get: { store.startAtLogin },
                    set: { newValue in setStartAtLogin(newValue) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Pausing") {
                Text("Pause from the No Donuts menu in the menu bar: for 15 minutes, for 1 hour, or until you resume. While paused, No Donuts doesn\u{2019}t use the camera or lock your Mac, and the menu bar shows that it\u{2019}s paused. A timed pause resumes on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("On a trusted Wi-Fi network, locking is paused automatically (see Trusted Wi-Fi).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setStartAtLogin(_ enabled: Bool) {
        // ND-082: from the launchd-managed copy, "off" means quitting now. Leave the
        // toggle on (store unchanged) until the user confirms in that window.
        if !enabled, actions.isAgentManaged() {
            loginError = nil
            actions.confirmDisableStartAtLogin()
            return
        }
        do {
            try LoginItem.setEnabled(enabled)
            // Reflect the effective status (may be .requiresApproval even after a
            // successful register on an ad-hoc build).
            store.startAtLogin = LoginItem.isEnabled()
            if enabled && LoginItem.status() == .requiresApproval {
                loginError = String(localized: "Needs approval in System Settings › General › Login Items.")
            } else {
                loginError = nil
            }
            if enabled && store.startAtLogin {
                // Let SwiftUI draw the toggle as on before a possible handover exit.
                let didEnable = actions.didEnableStartAtLogin
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    didEnable()
                }
            }
        } catch {
            // Keep the toggle honest: reflect actual status, surface the reason.
            store.startAtLogin = LoginItem.isEnabled()
            loginError = String(localized: "Couldn't change this. It may need approval in System Settings › General › Login Items.")
        }
    }
}

// MARK: - Trusted Wi-Fi

@MainActor
struct TrustedWiFiSettingsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions

    var body: some View {
        SettingsPane(category: .trustedWiFi) {
            Section {
                if store.trustedNetworks.isEmpty {
                    Text("No trusted networks. On a trusted network, No Donuts pauses locking. Add one from the menu bar (\u{201C}Trust this Wi-Fi network\u{201D}).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.trustedNetworks) { network in
                        HStack {
                            Image(systemName: "wifi").foregroundStyle(.secondary)
                                .accessibilityHidden(true)   // ND-100: decorative
                            VStack(alignment: .leading, spacing: 1) {
                                Text(network.ssid)
                                Text(Self.routerLabel(for: network))
                                    .font(.caption)
                                    .foregroundStyle(network.needsReTrust ? .orange : .secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                store.trustedNetworks = actions.removeTrustedNetwork(network)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(network.ssid)")   // ND-100: which one
                        }
                    }
                }
            }
            if !store.trustedNetworks.isEmpty {
                Section {
                    Text("A network is trusted only on the router it was trusted on (Wi-Fi name + router address), so a hotspot using the same name isn\u{2019}t trusted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Second line of a trusted-network row (ND-081). Shows only the router MAC's last
    /// two octets: enough to tell several routers of one SSID apart.
    static func routerLabel(for network: TrustedNetwork) -> String {
        guard let mac = network.gatewayMAC else {
            return String(localized: "Needs re-confirming: join it and choose \u{201C}Trust this Wi-Fi network\u{201D} again (not trusted until then)")
        }
        let tail = mac.split(separator: ":").suffix(2).joined(separator: ":")
        return String(localized: "Router \u{2026}\(tail) (trusted only on this router)")
    }
}

// MARK: - Timing

/// Grace period and check interval (homer's tunables; the store clamps and persists).
@MainActor
struct TimingSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPane(category: .timing) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Grace period")
                        Spacer()
                        Text("\(Int(store.graceSeconds.rounded())) s")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $store.graceSeconds,
                           in: SettingsStore.Range.grace,
                           step: 1)
                    .accessibilityLabel("Grace period")
                    .accessibilityValue("\(Int(store.graceSeconds.rounded())) seconds")
                    Text("How long you can be away before the Mac locks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Check interval")
                        Spacer()
                        Text("\(displayNumber(store.tickIntervalSeconds, digits: 1)) s")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $store.tickIntervalSeconds,
                           in: SettingsStore.Range.tick,
                           step: 0.5)
                    .accessibilityLabel("Check interval")
                    .accessibilityValue("\(displayNumber(store.tickIntervalSeconds, digits: 1)) seconds")
                    Text("How often No Donuts checks the camera. Faster reacts sooner; slower uses less power.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
