import SwiftUI
import NoDonutsCore

// Owner: krusty — ND-122. A Slider for a security tunable whose committed value is
// live-applied to the engine (match threshold, grace, check interval). A mouse drag
// edits a local draft (the readout follows it) and writes the store ONCE on release, so
// values the thumb merely passes through never take effect — dragging the threshold to
// 0.90 used to apply 0.86, 0.87, … and fast-lock a user whose score was ~0.85.
// Keyboard and VoiceOver steps arrive outside a drag and apply per step. External
// changes to the bound value (Reset to default, a model descriptor adopt, a
// `defaults write` picked up on refresh, the store clamping) resync the draft when not
// dragging. The draft/commit rules are `SliderDraft` in NoDonutsCore (EngineCheck'd).

@MainActor
struct CommitOnReleaseSlider<Content: View>: View {
    /// The store value. Written only on release / per keyboard or VoiceOver step.
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Identity of the slider's SCALE (e.g. the active model version). A change abandons
    /// an in-flight drag: a draft on the old model's scale must not land on the new one.
    var scaleID: String = ""
    let label: Text
    var minimumValueLabel: Text?
    var maximumValueLabel: Text?
    let accessibilityValue: (Double) -> Text
    var accessibilityHint: Text?
    /// Lays out the header/captions around the slider; receives the DRAFT value (what the
    /// readout should show) and the slider control itself.
    @ViewBuilder let content: (_ draftValue: Double, _ slider: AnyView) -> Content

    @State private var draft: SliderDraft

    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double,
         scaleID: String = "",
         label: Text,
         minimumValueLabel: Text? = nil,
         maximumValueLabel: Text? = nil,
         accessibilityValue: @escaping (Double) -> Text,
         accessibilityHint: Text? = nil,
         @ViewBuilder content: @escaping (_ draftValue: Double, _ slider: AnyView) -> Content) {
        self._value = value
        self.range = range
        self.step = step
        self.scaleID = scaleID
        self.label = label
        self.minimumValueLabel = minimumValueLabel
        self.maximumValueLabel = maximumValueLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityHint = accessibilityHint
        self.content = content
        self._draft = State(initialValue: SliderDraft(value: value.wrappedValue))
    }

    var body: some View {
        content(draft.value, AnyView(slider))
            .onChange(of: value) { _, newValue in draft.externalChanged(newValue) }
            .onChange(of: scaleID) { _, _ in draft.reset(to: value) }
            // Defensive: a pane switch / window close mid-drag still lands the release.
            .onDisappear { apply(draft.editingChanged(false)) }
    }

    private var draftBinding: Binding<Double> {
        Binding(get: { draft.value }, set: { apply(draft.set($0)) })
    }

    @ViewBuilder
    private var slider: some View {
        Group {
            if let minimumValueLabel, let maximumValueLabel {
                Slider(value: draftBinding, in: range, step: step) {
                    label
                } minimumValueLabel: {
                    minimumValueLabel
                } maximumValueLabel: {
                    maximumValueLabel
                } onEditingChanged: { editing in
                    apply(draft.editingChanged(editing))
                }
            } else {
                Slider(value: draftBinding, in: range, step: step) {
                    label
                } onEditingChanged: { editing in
                    apply(draft.editingChanged(editing))
                }
                .labelsHidden()
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue(draft.value))
        .accessibilityHint(accessibilityHint ?? Text(verbatim: ""))
        // ND-100 / ND-122: VoiceOver increments are explicit single steps that commit
        // immediately (never part of a drag).
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: apply(draft.set(stepped(draft.value, by: step)))
            case .decrement: apply(draft.set(stepped(draft.value, by: -step)))
            @unknown default: break
            }
        }
    }

    /// One step from `current`, snapped to the step grid and clamped to the range.
    private func stepped(_ current: Double, by delta: Double) -> Double {
        let steps = ((current + delta - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + steps * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func apply(_ commit: Double?) {
        guard let commit else { return }
        value = commit
    }
}
