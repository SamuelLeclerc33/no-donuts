import Foundation

// Owner: krusty — pause enforcement UX (ND-035).
// Trust rule: pausing is user-initiated and visible. This controller owns ONLY
// the pause flag + optional timed-expiry timer; it embeds no policy. main.swift
// funnels its onChange through the single enforcement gate (applyEnforcement()),
// which sets the engine's honest display state and stops the loop/camera.
//
// Lives in the App target (Foundation Timer on the main run loop). NoDonutsCore
// stays timer/AppKit-free (ADR-0007) — the engine just exposes pause()/resume().
@MainActor
public final class PauseController {
    /// True while enforcement is paused (timed or indefinite).
    public private(set) var isPaused = false
    /// When a timed pause auto-resumes; nil for indefinite pauses or when active.
    public private(set) var expiry: Date?

    /// Fired whenever the pause state changes. main.swift sets this to call
    /// applyEnforcement(). The single enforcement gate does the real work.
    public var onChange: (() -> Void)?

    /// Backing timer for a timed pause; invalidated on resume / re-pause.
    private var timer: Timer?

    public init() {}

    /// Pause enforcement. `seconds == nil` pauses indefinitely (until the user
    /// resumes). A timed pause schedules a main-run-loop Timer that resumes on
    /// fire. The timer may fire late after sleep — that's fine: applyEnforcement()
    /// re-evaluates on wake and the expiry is only a display hint.
    public func pause(for seconds: TimeInterval?) {
        timer?.invalidate()
        timer = nil
        isPaused = true
        if let seconds {
            expiry = Date().addingTimeInterval(seconds)
            let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            expiry = nil
        }
        onChange?()
    }

    /// Resume enforcement immediately. Invalidates any pending timed-pause timer.
    public func resume() {
        timer?.invalidate()
        timer = nil
        guard isPaused else { return }
        isPaused = false
        expiry = nil
        onChange?()
    }

    /// A short remaining-time string for the menu: "14 min left" for a timed
    /// pause, "Paused" for an indefinite pause, nil when not paused. Whole
    /// minutes; rounds up so "0 min left" never shows while still paused.
    public func remainingDescription() -> String? {
        guard isPaused else { return nil }
        guard let expiry else { return "Paused" }
        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else { return "Paused" }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return "\(minutes) min left"
    }
}
