import SwiftUI
import NoDonutsCore

// Owner: krusty — Settings panes: Diagnostics and About (ND-117). Privacy: everything
// shown is local (device names, lock-mechanism names, crash presence). No network.

// MARK: - Diagnostics

/// Copy diagnostics (ND-044), the camera and lock-mechanism facts (ND-058/099), and a
/// one-line note when a local crash summary exists (ND-108).
@MainActor
struct DiagnosticsSettingsPane: View {
    let actions: SettingsActions

    @State private var copiedConfirmation = false
    /// ND-108: whether any local crash summary exists (MetricKit record or .ips file).
    /// Read off main on appear (the .ips scan touches files); nil until known.
    @State private var hasCrashSummary: Bool?

    var body: some View {
        SettingsPane(category: .diagnostics) {
            Section {
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
                if hasCrashSummary == true {
                    Text("No Donuts has crashed on this Mac at least once (a recorded crash report exists). The crash summary is included in Copy diagnostics.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                LiveRecognitionInfo(actions: actions) { info in
                    SettingsStatusRowsView(rows: Self.systemRows(info))
                }
            }
        }
        .task {
            hasCrashSummary = await Task.detached(priority: .utility) {
                // Read-only: a fresh collector just decodes the stored summaries.
                !CrashSummaryCollector().records().isEmpty
                    || !CrashSummaryReport.crashReportSummaries(
                        in: CrashSummaryReport.defaultReportsDirectory).isEmpty
            }.value
        }
    }

    /// Camera and lock-mechanism rows (moved from the ND-099 Recognition section).
    static func systemRows(_ info: RecognitionInfo) -> [SettingsStatusRow] {
        var rows: [SettingsStatusRow] = []
        var camera = info.cameraName ?? String(localized: "Built-in camera (not opened yet)")
        if let reason = info.cameraUnavailableReason {
            // The reason comes from NoDonutsCore (CameraController) in English; known
            // values are localized here, an unknown one is shown as-is.
            let localizedReason = CoreStrings.cameraUnavailableReason(reason)
            camera = String(localized: "\(camera), unavailable: \(localizedReason)")
        }
        rows.append(SettingsStatusRow(label: String(localized: "Camera"), value: camera,
                                      warning: info.cameraUnavailableReason != nil))

        rows.append(SettingsStatusRow(label: String(localized: "Lock mechanisms"),
                                      value: info.lockMechanisms.isEmpty
                                          ? String(localized: "None: can\u{2019}t lock on this macOS")
                                          : info.lockMechanisms.joined(separator: ", "),
                                      warning: info.lockMechanisms.isEmpty))
        return rows
    }
}

// MARK: - About

struct AboutSettingsPane: View {
    var body: some View {
        SettingsPane(category: .about) {
            Section {
                // ADR-0021: which build is running (stamped by scripts/make-app.sh).
                HStack(alignment: .firstTextBaseline) {
                    Text("Version")
                    Spacer(minLength: 12)
                    Text(verbatim: AppVersion.versionAndBuild)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                Text("Locks your Mac when you step away, so nobody can volunteer you for the next donut run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Everything happens on this Mac. No camera image, face data, or Wi-Fi name ever leaves it: nothing is uploaded and there is no telemetry. Camera images are checked in memory and discarded; your face enrollment is stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("No Donuts is a safety net, not a replacement for locking your Mac yourself. Lock it any time with Control-Command-Q or \u{201C}Lock now\u{201D} in the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
