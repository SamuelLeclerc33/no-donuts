import Foundation
import NoDonutsCore

// Owner: krusty — ND-122: security sliders commit on release; the live match score
// readout holds the last verified score for 10 s.

@MainActor
func runSettingsSliderChecks(_ c: Checks) async {
    print("\nND-122 settings slider checks:")

    // Drag: intermediate values never commit; release commits the final one once.
    do {
        var d = SliderDraft(value: 0.80)
        c.expect(d.editingChanged(true) == nil, "ND-122: drag start commits nothing")
        let mid = [0.82, 0.85, 0.88, 0.90].map { d.set($0) }
        c.expect(mid.allSatisfy { $0 == nil }, "ND-122: intermediate drag values do not commit")
        c.expect(d.value == 0.90 && d.committed == 0.80, "ND-122: readout follows the draft while dragging")
        c.expect(d.editingChanged(false) == 0.90, "ND-122: release commits the final draft")
        c.expect(d.committed == 0.90 && !d.isEditing, "ND-122: committed mirrors the release value")
        c.expect(d.editingChanged(false) == nil, "ND-122: a stray second release commits nothing")
    }

    // Drag back to the start, or a click without moving: nothing to write.
    do {
        var d = SliderDraft(value: 0.80)
        _ = d.editingChanged(true)
        _ = d.set(0.90)
        _ = d.set(0.80)
        c.expect(d.editingChanged(false) == nil, "ND-122: release at the committed value writes nothing")
        _ = d.editingChanged(true)
        c.expect(d.editingChanged(false) == nil, "ND-122: click without moving writes nothing (no override at default)")
    }

    // Keyboard / VoiceOver steps (no drag) commit per step.
    do {
        var d = SliderDraft(value: 0.80)
        c.expect(d.set(0.81) == 0.81, "ND-122: a step outside a drag commits immediately")
        c.expect(d.set(0.82) == 0.82 && d.committed == 0.82, "ND-122: each further step commits")
        c.expect(d.set(0.82) == nil, "ND-122: a step to the same value writes nothing")
    }

    // External changes resync when idle, and wait for release while dragging.
    do {
        var d = SliderDraft(value: 0.85)
        d.externalChanged(0.75)   // reset to default / defaults tamper / clamp echo
        c.expect(d.value == 0.75 && d.committed == 0.75, "ND-122: external change resyncs the idle draft")
        _ = d.editingChanged(true)
        _ = d.set(0.88)
        d.externalChanged(0.70)
        c.expect(d.value == 0.88 && d.committed == 0.70, "ND-122: external change mid-drag keeps the thumb")
        c.expect(d.editingChanged(false) == 0.88, "ND-122: release after an external change still commits the draft")
    }

    // Reset (model scale changed) abandons the drag without committing.
    do {
        var d = SliderDraft(value: 0.85)
        _ = d.editingChanged(true)
        _ = d.set(0.95)
        d.reset(to: 0.30)
        c.expect(d.value == 0.30 && d.committed == 0.30 && !d.isEditing,
                 "ND-122: reset abandons the drag and shows the new value")
        c.expect(d.editingChanged(false) == nil, "ND-122: release after a reset commits nothing")
    }
    // Review fix: the mouse is still down after a reset — the rest of that drag writes nothing.
    do {
        var d = SliderDraft(value: 0.85)
        _ = d.editingChanged(true)
        _ = d.set(0.90)
        d.reset(to: 0.50)
        let writes = [0.60, 0.70, 0.80].compactMap { d.set($0) }
        c.expect(writes.isEmpty && d.value == 0.50,
                 "ND-122: drag steps after a mid-drag reset are swallowed (no per-step commits)")
        c.expect(d.editingChanged(false) == nil && !d.isAbandoned,
                 "ND-122: the abandoned drag's release writes nothing and clears the flag")
        c.expect(d.set(0.55) == 0.55, "ND-122: after the release, a keyboard step commits again")
    }
    // Review fix: the hold covers slow check intervals.
    do {
        var h = LiveMatchScoreHold()
        h.record(score: 0.84, identityActive: true, now: t0, tickIntervalSeconds: 10)
        c.expect(h.effectiveHoldSeconds == 20 && h.displayScore(now: t0.addingTimeInterval(10.8)) == 0.84,
                 "ND-122: at a 10 s tick the hold is 20 s (no flicker between ticks)")
        c.expect(h.displayScore(now: t0.addingTimeInterval(20.5)) == nil, "ND-122: …and still expires")
        var d = LiveMatchScoreHold()
        d.record(score: 0.84, identityActive: true, now: t0, tickIntervalSeconds: 1)
        c.expect(d.effectiveHoldSeconds == 10, "ND-122: at the 1 s default the hold stays 10 s")
    }

    // Live match score hold.
    do {
        var h = LiveMatchScoreHold()
        c.expect(h.holdSeconds == 10 && h.displayScore(now: t0) == nil, "ND-122: no score yet → —")
        h.record(score: 0.84, identityActive: true, now: t0)
        c.expect(h.displayScore(now: t0) == 0.84, "ND-122: a verified score shows")
        h.record(score: nil, identityActive: true, now: t0.addingTimeInterval(1))
        c.expect(h.displayScore(now: t0.addingTimeInterval(10)) == 0.84,
                 "ND-122: a non-match tick holds the last score for 10 s")
        c.expect(h.displayScore(now: t0.addingTimeInterval(10.5)) == nil, "ND-122: older than 10 s → —")
        c.expect(h.displayScore(now: t0.addingTimeInterval(-1)) == nil, "ND-122: clock went backwards → —")
        h.record(score: 0.86, identityActive: true, now: t0.addingTimeInterval(12))
        c.expect(h.displayScore(now: t0.addingTimeInterval(12)) == 0.86, "ND-122: a new score replaces the old")
        h.record(score: 1.0, identityActive: false, now: t0.addingTimeInterval(13))
        c.expect(h.displayScore(now: t0.addingTimeInterval(13)) == nil,
                 "ND-122: identity not active (presence-only 1.0) clears and never shows")
        h.record(score: 0.9, identityActive: true, now: t0.addingTimeInterval(14))
        h.record(score: .nan, identityActive: true, now: t0.addingTimeInterval(15))
        c.expect(h.displayScore(now: t0.addingTimeInterval(15)) == 0.9, "ND-122: a NaN score is ignored")
        h.clear()
        c.expect(h.displayScore(now: t0.addingTimeInterval(15)) == nil, "ND-122: clear (loop stopped) → — at once")
    }
}
