import SwiftUI
import ServiceManagement
import NoDonutsCore

// Owner: krusty — the Settings window UI (ND-040). SwiftUI bound to the SettingsStore,
// plus a few injected actions for things the view shouldn't own (login item,
// trusted-network removal, diagnostics). No policy lives here: the view reflects/writes
// the store and forwards intent, exactly like the menu bar does.
//
// ND-117 layout: macOS System Settings style. A left sidebar of categories
// (`SettingsCategory`) and a scrollable detail pane per category, so the window fits a
// 13" screen instead of one tall form. The panes live in SettingsPanes*.swift; this file
// holds the shared models, the shell, and the small shared row views. The last selected
// category is remembered in UserDefaults (`settings.selectedCategory`), a viewer
// convenience only; it has no effect on protection.
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


/// ND-117: the sidebar categories, in display order. Raw values are persisted (last
/// selected category), so keep them stable.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, recognition, security, trustedWiFi, timing, diagnostics, about

    var id: String { rawValue }

    /// UserDefaults key for the last selected category (per-user viewer convenience).
    static let selectionDefaultsKey = "settings.selectedCategory"

    var title: String {
        switch self {
        case .general:     return String(localized: "General")
        case .recognition: return String(localized: "Recognition")
        case .security:    return String(localized: "Security")
        case .trustedWiFi: return String(localized: "Trusted Wi-Fi")
        case .timing:      return String(localized: "Timing")
        case .diagnostics: return String(localized: "Diagnostics")
        case .about:       return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .recognition: return "person.crop.square"
        case .security:    return "lock.shield"
        case .trustedWiFi: return "wifi"
        case .timing:      return "timer"
        case .diagnostics: return "stethoscope"
        case .about:       return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general:     return .gray
        case .recognition: return .blue
        case .security:    return .red
        case .trustedWiFi: return .teal
        case .timing:      return .orange
        case .diagnostics: return .purple
        case .about:       return .indigo
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions
    /// ND-122: live match score for the Recognition pane (owned by the AppDelegate).
    let liveMatch: LiveMatchScoreModel

    /// ND-117: last selected category, remembered across opens and launches.
    @AppStorage(SettingsCategory.selectionDefaultsKey)
    private var selection: SettingsCategory = .general
    /// The sidebar always stays visible (there is no toolbar toggle to bring it back).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// ND-117 window geometry, shared with AppWindows so the NSWindow and the SwiftUI
    /// root agree. The minimum fits a 13" MacBook screen (1280×800 and up).
    nonisolated static let defaultSize = CGSize(width: 720, height: 520)
    nonisolated static let minimumSize = CGSize(width: 620, height: 420)

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsCategory.allCases, selection: Binding<SettingsCategory?>(
                get: { selection },
                set: { if let newValue = $0 { selection = newValue } }
            )) { category in
                SettingsSidebarRow(category: category)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
            .accessibilityLabel("Settings categories")
        } detail: {
            detail(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: columnVisibility) { _, newValue in
            if newValue != .all { columnVisibility = .all }
        }
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, maxHeight: .infinity)
        .onAppear {
            // First-creation seed. On REOPEN of the retained window this won't re-fire,
            // so the AppDelegate also calls store.refresh() in the open path (code-review
            // #2) — that publishes fresh values the view picks up either way.
            store.refresh()
        }
    }

    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .general:     GeneralSettingsPane(store: store, actions: actions)
        case .recognition: RecognitionSettingsPane(store: store, actions: actions, liveMatch: liveMatch)
        case .security:    SecuritySettingsPane(store: store, actions: actions)
        case .trustedWiFi: TrustedWiFiSettingsPane(store: store, actions: actions)
        case .timing:      TimingSettingsPane(store: store)
        case .diagnostics: DiagnosticsSettingsPane(actions: actions)
        case .about:       AboutSettingsPane()
        }
    }
}

// MARK: - Shared pieces

/// One sidebar row: a System-Settings-style tinted icon tile plus the category name.
struct SettingsSidebarRow: View {
    let category: SettingsCategory

    var body: some View {
        Label {
            Text(verbatim: category.title)
        } icon: {
            Image(systemName: category.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(category.tint.gradient))
                .accessibilityHidden(true)   // ND-100: decorative; the name is the label
        }
    }
}

/// The detail pane container: the category title, then a grouped Form (which scrolls
/// on its own when the content is taller than the window).
struct SettingsPane<Content: View>: View {
    let category: SettingsCategory
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(verbatim: category.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 2)
        }
    }
}

/// A read-only "label ... value" row (ND-099 recognition facts and friends).
struct SettingsStatusRow {
    let label: String
    let value: String
    /// Rendered in orange: something here weakens or disables protection.
    var warning = false
}

struct SettingsStatusRowsView: View {
    let rows: [SettingsStatusRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: row.label)
                    Spacer(minLength: 12)
                    Text(verbatim: row.value)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(row.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Polls the live recognition snapshot every 2 s: a retained window doesn't re-fire
/// `.onAppear`, and model load / camera / identity can change while it's open (ND-099).
struct LiveRecognitionInfo<Content: View>: View {
    let actions: SettingsActions
    @ViewBuilder let content: (RecognitionInfo) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            content(actions.recognitionInfo())
        }
    }
}
