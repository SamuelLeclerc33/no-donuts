import Foundation
import Combine
import NoDonutsCore

// Owner: krusty — ND-122. The live "Your current match" readout beside the threshold
// slider, so the user sees where they would lock before releasing the thumb.
//
// Fed by the AppDelegate once per loop tick with `PresenceEngine.lastMatchScore`, and
// only counted while identity is `.active` (the presence-only fallback reports a fake
// 1.0 — same filter as the ND-119 drift wiring). Cleared when the loop stops (pause,
// suspend, trusted Wi-Fi, enrollment) so the readout never shows a stale match. The
// hold / expiry rules are `LiveMatchScoreHold` in NoDonutsCore (EngineCheck'd).
//
// Privacy: in-memory, local UI only. Never persisted, never logged, never in diagnostics.
@MainActor
final class LiveMatchScoreModel: ObservableObject {
    @Published private(set) var hold = LiveMatchScoreHold()

    /// One tick's reading (at most one publish per tick).
    func record(score: Double?, identityActive: Bool, tickIntervalSeconds: TimeInterval,
                now: Date = Date()) {
        var next = hold
        next.record(score: score, identityActive: identityActive, now: now,
                    tickIntervalSeconds: tickIntervalSeconds)
        if next != hold { hold = next }
    }

    /// The loop stopped: nothing is being verified, so show "—" at once.
    func clear() {
        guard hold.lastScore != nil else { return }
        hold.clear()
    }
}
