import SwiftUI
import NoDonutsCore

// Owner: krusty — Settings panes for identity: Recognition and Security (ND-117).
// Controls moved from the old single-form Settings (ND-040/076/099); semantics unchanged.
// ND-101: String-typed values go through String(localized:); SwiftUI literals are keys.

// MARK: - Recognition

/// Read-only model / threshold / enrollment facts (ND-099) plus the lock-sensitivity
/// slider and "Reset to default" (ND-076).
@MainActor
struct RecognitionSettingsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions
    /// ND-122: the live match score shown beside the threshold slider.
    @ObservedObject var liveMatch: LiveMatchScoreModel

    var body: some View {
        SettingsPane(category: .recognition) {
            Section {
                LiveRecognitionInfo(actions: actions) { info in
                    SettingsStatusRowsView(rows: Self.recognitionRows(info))
                }
                Text("Read-only. Everything here is computed on this Mac; no face data is shown or sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                sensitivity
            }
        }
    }

    /// Lock sensitivity (matchThreshold). Higher = stricter match required (locks more
    /// readily for lookalikes); lower = more lenient. ND-122: a drag commits on release
    /// (the number follows the thumb), with the live match score shown beside it.
    private var sensitivity: some View {
        // Bounds come from the ACTIVE model (ND-076) — per-model score scales differ.
        CommitOnReleaseSlider(
            value: $store.matchThreshold,
            in: store.thresholdRange,
            step: 0.01,
            scaleID: store.descriptor.version,
            label: Text("Lock sensitivity"),
            minimumValueLabel: Text("Lenient").font(.caption).foregroundStyle(.secondary),
            maximumValueLabel: Text("Strict").font(.caption).foregroundStyle(.secondary),
            accessibilityValue: { Text(verbatim: displayNumber($0, digits: 2)) },
            accessibilityHint: Text("Higher is stricter.")
        ) { draftThreshold, slider in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Lock sensitivity")
                    Spacer()
                    Text(verbatim: displayNumber(draftThreshold, digits: 2))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                slider
                LiveMatchScoreReadout(model: liveMatch, threshold: draftThreshold)
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
        }
    }

    /// Pure mapping from the snapshot to the identity rows: model, threshold, enrollment.
    static func recognitionRows(_ info: RecognitionInfo) -> [SettingsStatusRow] {
        var rows: [SettingsStatusRow] = []

        let model = info.modelLoading
            ? String(localized: "\(info.modelName) (\(info.modelVersion)), loading\u{2026}")
            : "\(info.modelName) (\(info.modelVersion))"
        rows.append(SettingsStatusRow(label: String(localized: "Model"), value: model))

        rows.append(SettingsStatusRow(label: String(localized: "Threshold tuned"),
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
        rows.append(SettingsStatusRow(label: String(localized: "Effective threshold"), value: threshold))

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
        rows.append(SettingsStatusRow(label: String(localized: "Enrollment"), value: enrollment,
                                      warning: enrollmentWarning))
        return rows
    }
}

/// ND-122: "Your current match: 0.84" beside the threshold slider, so the user sees
/// where they would lock before releasing the thumb. "—" when nothing was verified in
/// the last 10 s (not enrolled, paused, away, camera down). Re-evaluated every second so
/// the hold expires on screen even while no ticks arrive. Local display only.
@MainActor
struct LiveMatchScoreReadout: View {
    @ObservedObject var model: LiveMatchScoreModel
    /// The slider's DRAFT threshold (follows the thumb while dragging).
    let threshold: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let score = model.hold.displayScore(now: context.date)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your current match: \(score.map { displayNumber($0, digits: 2) } ?? "\u{2014}")")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(score.map { $0 < threshold } == true ? .orange : .secondary)
                    // ND-100: read as "Your current match, 0.84" / "…, no recent match".
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Your current match")
                    .accessibilityValue(score.map { Text(verbatim: displayNumber($0, digits: 2)) }
                                        ?? Text("No recent match"))
                if let score, score < threshold {
                    // Same accept test as the recognizer (score >= threshold), on the raw score.
                    Text("Below this setting: at this sensitivity your own face would not match, and the Mac would lock.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if score == nil {
                    Text("Shown while No Donuts is recognizing you (enrolled, not paused).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Security

/// "Reject photos of me" (anti-spoof texture check + ADR-0022 liveness, one toggle), the
/// live photo-rejection status, and the ND-077 protection-reduced summary.
@MainActor
struct SecuritySettingsPane: View {
    @ObservedObject var store: SettingsStore
    let actions: SettingsActions

    var body: some View {
        SettingsPane(category: .security) {
            Section {
                Toggle("Reject photos of me (anti-spoofing)", isOn: $store.antiSpoofEnabled)
                // ADR-0022: the one toggle gates both the texture check and liveness.
                // Honest about the residual: a replayed video isn't stopped.
                Text("Checks that the face is live, not a printed or on-screen photo: it must blink or move naturally at least once a minute, and have the fine texture of a real face. A photo held up to the camera keeps the Mac unlocked for about a minute at most, plus the grace period. A video of you replayed on a screen can still get past it. Turn it off only if you\u{2019}re ever locked out while at your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LiveRecognitionInfo(actions: actions) { info in
                    SettingsStatusRowsView(rows: [
                        Self.photoRejectionRow(info),
                        Self.protectionRow(descriptor: store.descriptor),
                    ])
                }
                Text("Weakened security settings are also shown in the menu bar menu and in Copy diagnostics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func photoRejectionRow(_ info: RecognitionInfo) -> SettingsStatusRow {
        let value: String
        var warning = false
        switch (info.antiSpoofEnabled, info.antiSpoofSupportedByModel) {
        case (false, _):
            value = String(localized: "Off (turned off above)")
            warning = true
        case (true, true?):
            value = String(localized: "Active on this model")
        case (true, false?):
            value = String(localized: "Not supported by this model")
            warning = true
        case (true, nil):
            value = String(localized: "Unknown for this model")
            warning = true
        }
        return SettingsStatusRow(label: String(localized: "Photo rejection"), value: value, warning: warning)
    }

    /// ND-077: the same audit the menu header shows, so the two never disagree. Reads the
    /// live resolvers (a `defaults write` shows up on the next poll).
    static func protectionRow(descriptor: FaceEmbeddingModelDescriptor) -> SettingsStatusRow {
        let reasons = reducedProtectionReasons(descriptor: descriptor)
        guard !reasons.isEmpty else {
            return SettingsStatusRow(label: String(localized: "Security settings"),
                                     value: String(localized: "At the recommended defaults or stricter"))
        }
        let joined = reasons.map(CoreStrings.protectionReason).joined(separator: "; ")
        return SettingsStatusRow(label: String(localized: "Security settings"),
                                 value: String(localized: "Protection reduced: \(joined)"),
                                 warning: true)
    }
}
