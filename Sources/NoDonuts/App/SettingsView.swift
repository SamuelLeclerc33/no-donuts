import SwiftUI
import ServiceManagement
import NoDonutsCore

// Owner: krusty — the Settings window UI (ND-040). A native SwiftUI Form bound to
// the SettingsStore, plus a few injected actions for things the view shouldn't own
// (login item, trusted-network removal, diagnostics). No policy lives here: the view
// reflects/writes the store and forwards intent, exactly like the menu bar does.
//
// Privacy: no network, no external assets. Trusted networks are shown by name (plus the
// router MAC's last two octets) only in the local UI (they already live in the user's
// UserDefaults); diagnostics is the privacy-safe reporter (counts only, never SSIDs/MACs).

/// Dependencies the Settings view needs that don't belong to the SettingsStore.
/// All are injected by the AppDelegate so the view reaches into no singletons.
@MainActor
struct SettingsActions {
    /// Remove one trusted entry (SSID + router, ND-081), then re-apply enforcement.
    /// Returns the new list. The view reflects the trusted list from
    /// `SettingsStore.trustedNetworks` (refreshed on show, code-review #2); this action
    /// mutates it and hands back the updated list.
    var removeTrustedNetwork: (TrustedNetwork) -> [TrustedNetwork]
    /// Copy the privacy-safe diagnostics summary to the pasteboard.
    var copyDiagnostics: () -> Void
    /// ND-082: whether this process is the launchd-managed agent copy. Turning "Start
    /// at login" off from that copy stops the job, i.e. quits the app.
    var isAgentManaged: () -> Bool
    /// ND-082: show the "turn off and quit" confirmation; the AppDelegate runs the
    /// clean Quit path and unregisters on confirm.
    var confirmDisableStartAtLogin: () -> Void
    /// ND-082: called after a successful enable so an unmanaged copy can hand over
    /// to the agent (may exit this process).
    var didEnableStartAtLogin: () -> Void
}

@MainActor
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions

    // Local UI state (not persisted). `startAtLogin` and the trusted list now live on the
    // SettingsStore as @Published mirrors so they can be refreshed when the retained
    // window is re-fronted (code-review #2); the view binds to them, not local @State.
    @State private var loginError: String?
    @State private var copiedConfirmation = false

    var body: some View {
        Form {
            behaviorSection
            antiSpoofSection
            startupSection
            trustedNetworksSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // First-creation seed. On REOPEN of the retained window this won't re-fire,
            // so the AppDelegate also calls store.refresh() in the open path (code-review
            // #2) — that publishes fresh values the view picks up either way.
            store.refresh()
        }
    }

    // MARK: - Behavior (sensitivity / grace / interval)

    private var behaviorSection: some View {
        Section("Behavior") {
            // Lock sensitivity (matchThreshold). Higher = stricter match required
            // (locks more readily for lookalikes); lower = more lenient.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Lock sensitivity")
                    Spacer()
                    Text(String(format: "%.2f", store.matchThreshold))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                // Bounds come from the ACTIVE model (ND-076) — per-model score scales differ.
                Slider(value: $store.matchThreshold,
                       in: store.thresholdRange,
                       step: 0.01) {
                    Text("Lock sensitivity")
                } minimumValueLabel: {
                    Text("Lenient").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Strict").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Lock sensitivity")
                .accessibilityValue(String(format: "%.2f", store.matchThreshold))
                Text("How closely a face must match your enrollment to keep the Mac unlocked. Higher is stricter.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Honest about provenance: an un-tuned default is a provisional guess.
                    Text(String(format: "Model default %.2f", store.modelDefaultThreshold)
                         + (store.thresholdIsTuned ? " (tuned)" : " (not yet tuned)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") { store.resetMatchThreshold() }
                        .controlSize(.small)
                        .disabled(!store.hasThresholdOverride)
                }
            }

            // Grace period (graceSeconds).
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
                Text("How long you can be away before the Mac locks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Check interval (tickIntervalSeconds).
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Check interval")
                    Spacer()
                    Text(String(format: "%.1f s", store.tickIntervalSeconds))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $store.tickIntervalSeconds,
                       in: SettingsStore.Range.tick,
                       step: 0.5)
                Text("How often No Donuts checks the camera. Faster reacts sooner; slower uses less power.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Anti-spoofing

    private var antiSpoofSection: some View {
        Section("Security") {
            Toggle("Reject photos of me (anti-spoofing)", isOn: $store.antiSpoofEnabled)
            Text("Tries to ignore a printed or on-screen photo of your face. This check is conservative and not fully hardened — turn it off if a live face is ever rejected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Start at login

    private var startupSection: some View {
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
                loginError = "Needs approval in System Settings › General › Login Items."
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
            loginError = "Couldn't change this. It may need approval in System Settings › General › Login Items."
        }
    }

    // MARK: - Trusted Wi-Fi

    private var trustedNetworksSection: some View {
        Section("Trusted Wi-Fi networks") {
            if store.trustedNetworks.isEmpty {
                Text("No trusted networks. On a trusted network, No Donuts pauses locking. Add one from the menu bar (\u{201C}Trust this Wi-Fi network\u{201D}).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.trustedNetworks) { network in
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
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
                    }
                }
                Text("A network is trusted only on the router it was trusted on (Wi-Fi name + router address), so a hotspot using the same name isn\u{2019}t trusted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Second line of a trusted-network row (ND-081). Shows only the router MAC's last
    /// two octets: enough to tell several routers of one SSID apart.
    static func routerLabel(for network: TrustedNetwork) -> String {
        guard let mac = network.gatewayMAC else {
            return "Needs re-confirming: join it and choose \u{201C}Trust this Wi-Fi network\u{201D} again (not trusted until then)"
        }
        let tail = mac.split(separator: ":").suffix(2).joined(separator: ":")
        return "Router \u{2026}\(tail) (trusted only on this router)"
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            HStack {
                Button("Copy diagnostics") {
                    actions.copyDiagnostics()
                    withAnimation { copiedConfirmation = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { copiedConfirmation = false }
                    }
                }
                if copiedConfirmation {
                    Text("Copied").font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
            }
            Text("A local, privacy-safe summary you can paste into a bug report. Never includes photos, face data, or network names.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
