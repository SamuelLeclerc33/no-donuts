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
//
// ND-101 localization: SwiftUI literals (Text("…"), Button("…"), Section("…")…) resolve
// as LocalizedStringKey against Bundle.main; anything built as a `String` (row labels,
// computed values, errors) goes through `String(localized:)` because Text(String) is
// verbatim. Numbers use the user's locale (`displayNumber`), e.g. "0,75" in French.

/// Locale-aware fixed-precision number for display (never String(format:), which is POSIX).
func displayNumber(_ value: Double, digits: Int) -> String {
    value.formatted(.number.precision(.fractionLength(digits)))
}

/// ND-099: read-only snapshot of what recognition is ACTUALLY doing right now, for the
/// Settings "Recognition" section. Built by the AppDelegate from the same live sources
/// diagnostics uses (active embedder descriptor, threshold resolver, identity status,
/// camera, lock self-test). Model version strings and device names only; never face data.
struct RecognitionInfo: Equatable {
    /// Active model's display name + version tag (e.g. FaceNet / "facenet-vggface2-v2").
    var modelName: String
    var modelVersion: String
    /// True while the Core ML model is still loading off-main (ND-095).
    var modelLoading: Bool
    /// The active model's default threshold is measured (ND-056), not a provisional guess.
    var thresholdIsTuned: Bool
    /// The threshold the recognizer uses this tick (override if valid, else the default).
    var effectiveThreshold: Double
    var defaultThreshold: Double
    /// Identity status (ND-073): drives the enrollment-version row.
    var identity: IdentityStatus
    /// Anti-spoof toggle state (the resolver's live value, so a `defaults write` shows).
    var antiSpoofEnabled: Bool
    /// Whether the active model's embedder computes the texture score the anti-spoof
    /// gate needs. nil = unknown model (shown as such rather than guessed).
    var antiSpoofSupportedByModel: Bool?
    /// Name of the camera No Donuts opened, nil before the first capture.
    var cameraName: String?
    /// Last camera-unavailable reason, nil when frames are flowing.
    var cameraUnavailableReason: String?
    /// Lock self-test (ND-058): mechanism names available on this macOS.
    var lockMechanisms: [String]
}

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
    /// ND-099: current recognition facts for the read-only "Recognition" section.
    /// Cheap (UserDefaults reads + cached state); polled while the window is open.
    var recognitionInfo: () -> RecognitionInfo
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
            recognitionSection
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
                    Text(verbatim: displayNumber(store.matchThreshold, digits: 2))
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
                .accessibilityValue(displayNumber(store.matchThreshold, digits: 2))
                .accessibilityHint("Higher is stricter.")
                Text("How closely a face must match your enrollment to keep the Mac unlocked. Higher is stricter.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Honest about provenance: an un-tuned default is a provisional guess.
                    Text(store.thresholdIsTuned
                         ? String(localized: "Model default \(displayNumber(store.modelDefaultThreshold, digits: 2)) (tuned)")
                         : String(localized: "Model default \(displayNumber(store.modelDefaultThreshold, digits: 2)) (not yet tuned)"))
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
                .accessibilityLabel("Grace period")
                .accessibilityValue("\(Int(store.graceSeconds.rounded())) seconds")
                Text("How long you can be away before the Mac locks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Check interval (tickIntervalSeconds).
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

    // MARK: - Anti-spoofing

    private var antiSpoofSection: some View {
        Section("Security") {
            Toggle("Reject photos of me (anti-spoofing)", isOn: $store.antiSpoofEnabled)
            // ND-099: honest now that ND-072 landed — the texture check runs on both
            // recognition models. Still a basic check (no blink/motion liveness), and its
            // floor hasn't been re-measured against a clean spoof test yet.
            Text("Ignores a flat printed or on-screen photo of your face by checking its texture. Works with both recognition models. It\u{2019}s a basic, conservative check (no blink or motion test) and isn\u{2019}t fully hardened — turn it off if a live face is ever rejected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Recognition (read-only, ND-099)

    /// What recognition is actually doing, so the user never has to trust a claim they
    /// can't check. Read-only; polled every 2 s because a retained window doesn't re-fire
    /// `.onAppear`, and model load / camera / identity can change while it's open.
    private var recognitionSection: some View {
        Section("Recognition") {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let info = actions.recognitionInfo()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.recognitionRows(info), id: \.label) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                            Spacer(minLength: 12)
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(row.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Read-only. Everything here is computed on this Mac; no face data is shown or sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    struct RecognitionRow {
        let label: String
        let value: String
        /// Rendered in orange: something here weakens or disables protection.
        var warning = false
    }

    /// Pure mapping from the snapshot to display rows (kept static so it has no view state).
    static func recognitionRows(_ info: RecognitionInfo) -> [RecognitionRow] {
        var rows: [RecognitionRow] = []

        let model = info.modelLoading
            ? String(localized: "\(info.modelName) (\(info.modelVersion)), loading\u{2026}")
            : "\(info.modelName) (\(info.modelVersion))"
        rows.append(RecognitionRow(label: String(localized: "Model"), value: model))

        rows.append(RecognitionRow(label: String(localized: "Threshold tuned"),
                                   value: info.thresholdIsTuned
                                       ? String(localized: "Yes")
                                       : String(localized: "No (provisional default)"),
                                   warning: !info.thresholdIsTuned))

        let threshold: String
        if abs(info.effectiveThreshold - info.defaultThreshold) < 0.000_5 {
            threshold = String(localized: "\(displayNumber(info.effectiveThreshold, digits: 2)) (model default)")
        } else {
            let effective = displayNumber(info.effectiveThreshold, digits: 2)
            let modelDefault = displayNumber(info.defaultThreshold, digits: 2)
            threshold = String(localized: "\(effective) (custom; default \(modelDefault))")
        }
        rows.append(RecognitionRow(label: String(localized: "Effective threshold"), value: threshold))

        let enrollment: String
        var enrollmentWarning = false
        switch info.identity {
        case .active:
            enrollment = String(localized: "\(info.modelVersion), matches the active model")
        case .notEnrolled:
            enrollment = String(localized: "Not enrolled (any face keeps the Mac unlocked)")
            enrollmentWarning = true
        case .off(.modelMismatch(let stored, _)):
            let storedName = stored ?? String(localized: "legacy, unversioned")
            enrollment = String(localized: "\(storedName): re-enroll needed (identity check off)")
            enrollmentWarning = true
        case .off(.enrollmentMissing(let expected)):
            enrollment = String(localized: "Missing (was \(expected)): re-enroll needed (identity check off)")
            enrollmentWarning = true
        case .unknown:
            enrollment = String(localized: "Checking\u{2026}")
        }
        rows.append(RecognitionRow(label: String(localized: "Enrollment"), value: enrollment, warning: enrollmentWarning))

        let antiSpoof: String
        var antiSpoofWarning = false
        switch (info.antiSpoofEnabled, info.antiSpoofSupportedByModel) {
        case (false, _):
            antiSpoof = String(localized: "Off (turned off above)")
            antiSpoofWarning = true
        case (true, true?):
            antiSpoof = String(localized: "Active on this model")
        case (true, false?):
            antiSpoof = String(localized: "Not supported by this model")
            antiSpoofWarning = true
        case (true, nil):
            antiSpoof = String(localized: "Unknown for this model")
            antiSpoofWarning = true
        }
        rows.append(RecognitionRow(label: String(localized: "Photo rejection"), value: antiSpoof, warning: antiSpoofWarning))

        var camera = info.cameraName ?? String(localized: "Built-in camera (not opened yet)")
        if let reason = info.cameraUnavailableReason {
            // The reason itself comes from NoDonutsCore (CameraController) and stays English.
            camera = String(localized: "\(camera), unavailable: \(reason)")
        }
        rows.append(RecognitionRow(label: String(localized: "Camera"), value: camera,
                                   warning: info.cameraUnavailableReason != nil))

        rows.append(RecognitionRow(label: String(localized: "Lock mechanisms"),
                                   value: info.lockMechanisms.isEmpty
                                       ? String(localized: "None: can\u{2019}t lock on this macOS")
                                       : info.lockMechanisms.joined(separator: ", "),
                                   warning: info.lockMechanisms.isEmpty))
        return rows
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
                Text("A network is trusted only on the router it was trusted on (Wi-Fi name + router address), so a hotspot using the same name isn\u{2019}t trusted.")
                    .font(.caption).foregroundStyle(.secondary)
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
