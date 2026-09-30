import Foundation

// Owner: krusty — ND-122. Pure, AppKit-free halves of two Settings behaviours, kept
// here so EngineCheck can pin them:
//
//   - `SliderDraft`: a security slider (match threshold, grace, check interval) edits a
//     local draft while the mouse drags it and commits ONCE on release. Every committed
//     value is live-applied to the engine, so committing each intermediate drag value
//     used to apply thresholds the user only passed through (2026-09-29: dragging to
//     0.90 with a ~0.85 score fast-locked them 5 times mid-drag). Keyboard / VoiceOver
//     steps arrive outside a drag and commit per step.
//   - `LiveMatchScoreHold`: the "Your current match" readout next to the threshold
//     slider. Holds the last live-verified score for a few seconds so a single
//     non-match tick doesn't flicker it to "—". Display-only state: never persisted,
//     never logged.

/// Draft / commit state for a slider whose committed value has consequences (ND-122).
///
/// The view owns one of these per slider. `value` is what the slider and its number
/// show; `committed` mirrors the store. Mutators return the value to write to the store
/// NOW, or nil (still dragging, or nothing changed — a click that doesn't move the
/// thumb must not write, e.g. it would create a threshold override at the default).
public struct SliderDraft: Equatable, Sendable {
    /// What the slider and its readout show (follows the thumb while dragging).
    public private(set) var value: Double
    /// Last value known to be in the store (committed by us or changed externally).
    public private(set) var committed: Double
    /// True between drag start and drag end.
    public private(set) var isEditing = false
    /// True after `reset(to:)` abandoned a drag whose mouse is still down: the rest of
    /// that drag writes nothing (ND-122 review fix), until its release.
    public private(set) var isAbandoned = false

    public init(value: Double) {
        self.value = value
        self.committed = value
    }

    /// The slider moved. While dragging, only the draft moves; otherwise (keyboard,
    /// VoiceOver, programmatic step) the new value commits immediately.
    public mutating func set(_ newValue: Double) -> Double? {
        if isAbandoned { return nil }        // abandoned drag: ignore until release
        value = newValue
        return isEditing ? nil : commitIfChanged()
    }

    /// The slider's `onEditingChanged`. Ending a drag commits the draft (if it moved).
    public mutating func editingChanged(_ editing: Bool) -> Double? {
        if editing {
            isEditing = true
            isAbandoned = false
            return nil
        }
        if isAbandoned {                     // release of an abandoned drag: no write
            isAbandoned = false
            return nil
        }
        guard isEditing else { return nil }
        isEditing = false
        return commitIfChanged()
    }

    /// The store's value changed from outside the slider (reset to default, a model
    /// descriptor adopt, a `defaults write` picked up on refresh, the store clamping a
    /// commit, or our own commit echoing back). Resyncs the draft unless a drag is in
    /// progress — the user's thumb wins until release.
    public mutating func externalChanged(_ newValue: Double) {
        committed = newValue
        if !isEditing { value = newValue }
    }

    /// Abandon any drag and show `newValue` (e.g. the slider's scale changed under the
    /// thumb because the active face model changed — a draft on the old scale must not
    /// be committed onto the new one).
    /// If a drag is in progress it is ABANDONED, not ended: the mouse is still down, so
    /// the remaining drag steps are swallowed (they must not commit per step on the new
    /// scale) until the release.
    public mutating func reset(to newValue: Double) {
        if isEditing { isAbandoned = true }
        isEditing = false
        value = newValue
        committed = newValue
    }

    private mutating func commitIfChanged() -> Double? {
        guard value != committed else { return nil }
        committed = value
        return value
    }
}

/// Last live-verified match score, held briefly for display (ND-122).
///
/// Feed it once per tick. A score counts only when identity is enforced (`.active`):
/// the presence-only fallback reports a fake 1.0 (same filter as ND-119). A tick
/// without a score (stranger / no face / hold) keeps the last one for `holdSeconds`;
/// identity leaving `.active` or the loop stopping (pause, suspend, trusted Wi-Fi,
/// enrollment) clears it at once so the readout never shows a stale "match".
public struct LiveMatchScoreHold: Equatable, Sendable {
    public static let defaultHoldSeconds: TimeInterval = 10

    /// Minimum hold. The effective hold is `max(holdSeconds, 2 × tick interval)` so a
    /// slow check interval (up to 10 s) doesn't flicker the readout between ticks.
    public let holdSeconds: TimeInterval
    public private(set) var tickIntervalSeconds: TimeInterval = 1
    public private(set) var lastScore: Double?
    public private(set) var lastScoreAt: Date?

    public init(holdSeconds: TimeInterval = LiveMatchScoreHold.defaultHoldSeconds) {
        self.holdSeconds = holdSeconds
    }

    /// One tick's reading. `score` is `PresenceEngine.lastMatchScore`.
    public mutating func record(score: Double?, identityActive: Bool, now: Date,
                                tickIntervalSeconds: TimeInterval = 1) {
        if tickIntervalSeconds.isFinite, tickIntervalSeconds > 0 {
            self.tickIntervalSeconds = tickIntervalSeconds
        }
        guard identityActive else { clear(); return }
        guard let score, score.isFinite else { return }   // hold the previous one
        lastScore = score
        lastScoreAt = now
    }

    /// `max(holdSeconds, 2 × tickIntervalSeconds)`.
    public var effectiveHoldSeconds: TimeInterval { max(holdSeconds, 2 * tickIntervalSeconds) }

    public mutating func clear() {
        lastScore = nil
        lastScoreAt = nil
    }

    /// The score to show at `now`, or nil ("—") when none was seen within the hold.
    /// A clock that went backwards counts as expired (never show an undated score).
    public func displayScore(now: Date) -> Double? {
        guard let lastScore, let lastScoreAt else { return nil }
        let age = now.timeIntervalSince(lastScoreAt)
        guard age >= 0, age <= effectiveHoldSeconds else { return nil }
        return lastScore
    }
}
