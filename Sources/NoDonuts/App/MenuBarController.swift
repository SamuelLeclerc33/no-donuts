import AppKit
import NoDonutsCore

// Owner: krusty — menu-bar UI, status, pause, enroll, settings.
// Backlog: ND-010, ND-022 (enroll UI), ND-035, ND-040, ND-043.

/// Owns the NSStatusItem and reflects PresenceState in the menu bar.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Disabled menu header that surfaces the live presence state honestly (ND-015).
    private let statusItemHeader = NSMenuItem(title: "No Donuts", action: nil, keyEquivalent: "")
    /// Injected lock action — the UI never owns lock policy (decision lives with homer/wiggum).
    private let onLockNow: @MainActor () -> Void
    /// Injected pause actions (ND-035). The UI never owns PauseController; it just
    /// forwards intent. `onPause(nil)` = pause indefinitely; a value = pause for N s.
    private let onPause: @MainActor (TimeInterval?) -> Void
    private let onResume: @MainActor () -> Void
    /// Injected trust-toggle action (ND-036): trust/untrust the *current* SSID.
    /// The UI never owns the store or the SSID read — it forwards intent.
    private let onToggleTrustCurrentNetwork: @MainActor () -> Void
    /// Injected enrollment actions (ND-022). The UI never owns the store or the
    /// enrollment coordinator — it just forwards intent. `onEnroll` starts an
    /// enroll/re-enroll capture; `onResetEnrollment` clears it (back to presence-only).
    private let onEnroll: @MainActor () -> Void
    private let onResetEnrollment: @MainActor () -> Void
    /// Injected "open Settings…" action (ND-040). The UI never owns the window or the
    /// SettingsStore — it forwards intent; the AppDelegate hosts the SwiftUI window.
    private let onOpenSettings: @MainActor () -> Void
    /// Last state we actually rendered. The presence loop calls render(state:) every
    /// tick (1s); skip the NSImage rebuild + redraw when nothing changed (perf).
    private var lastRenderedState: PresenceState?
    /// Whether the user has enrolled a face (identity mode) vs presence-only. Drives
    /// the header wording and the visibility of "Reset enrollment". Set by the
    /// AppDelegate via setEnrolled(_:) at launch and after enroll/reset.
    private var isEnrolled = false
    /// While true, the header shows an honest "enrolling…" line regardless of the
    /// presence state (which is frozen at .paused by the gate during capture).
    private var isEnrolling = false

    // Pause items shown when NOT paused; hidden and replaced by `resumeItem` when paused.
    private let pause15Item = NSMenuItem(title: "Pause for 15 minutes", action: #selector(pause15Clicked), keyEquivalent: "")
    private let pause1hItem = NSMenuItem(title: "Pause for 1 hour", action: #selector(pause1hClicked), keyEquivalent: "")
    private let pauseIndefiniteItem = NSMenuItem(title: "Pause until I resume", action: #selector(pauseIndefiniteClicked), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resumeClicked), keyEquivalent: "")
    /// Checkable "Trust this Wi-Fi network" item (ND-036).
    private let trustItem = NSMenuItem(title: "Trust this Wi-Fi network", action: #selector(trustClicked), keyEquivalent: "")
    /// "Enroll my face…" — always visible; re-enrolls/overwrites when already enrolled (ND-022).
    private let enrollItem = NSMenuItem(title: "Enroll my face…", action: #selector(enrollClicked), keyEquivalent: "")
    /// "Reset enrollment" — shown only when enrolled; clears back to presence-only.
    private let resetEnrollmentItem = NSMenuItem(title: "Reset enrollment", action: #selector(resetEnrollmentClicked), keyEquivalent: "")
    /// "Settings…" — opens the SwiftUI settings window (ND-040). ⌘, per macOS convention.
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")

    public init(onLockNow: @escaping @MainActor () -> Void,
                onPause: @escaping @MainActor (TimeInterval?) -> Void,
                onResume: @escaping @MainActor () -> Void,
                onToggleTrustCurrentNetwork: @escaping @MainActor () -> Void,
                onEnroll: @escaping @MainActor () -> Void,
                onResetEnrollment: @escaping @MainActor () -> Void,
                onOpenSettings: @escaping @MainActor () -> Void) {
        self.onLockNow = onLockNow
        self.onPause = onPause
        self.onResume = onResume
        self.onToggleTrustCurrentNetwork = onToggleTrustCurrentNetwork
        self.onEnroll = onEnroll
        self.onResetEnrollment = onResetEnrollment
        self.onOpenSettings = onOpenSettings
        super.init()
        configureMenu()
        render(state: .unknown)
    }

    private func configureMenu() {
        let menu = NSMenu()
        // Menu order (ND-010/015/035/036): [status header] [sep]
        //   [Pause items / Resume] [Trust this Wi-Fi network] [sep] [Lock now] [Quit].
        statusItemHeader.isEnabled = false
        menu.addItem(statusItemHeader)
        menu.addItem(.separator())

        // Pause (ND-035). All four items live in the menu; visibility is toggled in
        // refreshPauseItem(): the three "Pause for…" items OR the single "Resume".
        for item in [pause15Item, pause1hItem, pauseIndefiniteItem, resumeItem] {
            item.target = self
            menu.addItem(item)
        }
        resumeItem.isHidden = true

        // Trust this Wi-Fi network (ND-036). State/title refreshed via refreshTrustItem().
        trustItem.target = self
        menu.addItem(trustItem)

        // Enrollment (ND-022): [sep] Enroll my face… [Reset enrollment (if enrolled)].
        menu.addItem(.separator())
        enrollItem.target = self
        menu.addItem(enrollItem)
        resetEnrollmentItem.target = self
        resetEnrollmentItem.isHidden = true   // shown only when enrolled (setEnrolled(_:))
        menu.addItem(resetEnrollmentItem)

        // Settings… (ND-040): opens the SwiftUI settings window.
        menu.addItem(.separator())
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let lockNowItem = NSMenuItem(title: "Lock now", action: #selector(lockNowClicked), keyEquivalent: "l")
        lockNowItem.target = self
        menu.addItem(lockNowItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Target/action shim for the "Lock now" menu item — forwards to the injected closure (ND-014).
    @objc private func lockNowClicked() {
        onLockNow()
    }

    @objc private func pause15Clicked() { onPause(15 * 60) }
    @objc private func pause1hClicked() { onPause(60 * 60) }
    @objc private func pauseIndefiniteClicked() { onPause(nil) }
    @objc private func resumeClicked() { onResume() }
    @objc private func trustClicked() { onToggleTrustCurrentNetwork() }
    @objc private func enrollClicked() { onEnroll() }
    @objc private func resetEnrollmentClicked() { onResetEnrollment() }
    @objc private func settingsClicked() { onOpenSettings() }

    /// Reflect whether the user has enrolled a face (identity mode) vs presence-only.
    /// Shows/hides "Reset enrollment", updates the header wording, and — because the
    /// enrolled-vs-not distinction changes the header — re-renders the current state.
    /// Called by the AppDelegate at launch and after every enroll/reset.
    public func setEnrolled(_ enrolled: Bool) {
        isEnrolled = enrolled
        resetEnrollmentItem.isHidden = !enrolled
        // Header text depends on isEnrolled; refresh it without a state change by
        // re-deriving from the last rendered state.
        if let state = lastRenderedState {
            statusItemHeader.title = headerTitle(for: state)
        }
    }

    /// Freeze the header on an honest "enrolling your face…" line during capture, and
    /// disable the enroll items so a second enrollment can't be started mid-capture.
    /// The AppDelegate calls this with `true` before enroll and `false` after. The
    /// enforcement gate separately holds the glyph at .paused while enrolling (no Core
    /// change needed — see the AppDelegate). Re-renders so the header takes effect now.
    public func setEnrolling(_ enrolling: Bool) {
        isEnrolling = enrolling
        enrollItem.isEnabled = !enrolling
        resetEnrollmentItem.isEnabled = !enrolling
        if let state = lastRenderedState {
            statusItemHeader.title = headerTitle(for: state)
        }
    }

    /// Refresh the Pause/Resume items after the enforcement gate re-evaluates.
    /// When paused, show a single "Resume (<remaining>)" and hide the pause options;
    /// otherwise show the three pause options and hide Resume.
    public func refreshPauseItem(isPaused: Bool, remaining: String?) {
        pause15Item.isHidden = isPaused
        pause1hItem.isHidden = isPaused
        pauseIndefiniteItem.isHidden = isPaused
        resumeItem.isHidden = !isPaused
        if let remaining, isPaused {
            resumeItem.title = "Resume (\(remaining))"
        } else {
            resumeItem.title = "Resume"
        }
    }

    /// Refresh the "Trust this Wi-Fi network" item after the enforcement gate
    /// re-evaluates. When the SSID is known, show it in the title and reflect
    /// whether it's already trusted with a checkmark. When unknown (Location not
    /// granted or no Wi-Fi), disable the item with an explanatory title so the
    /// status stays honest — we never imply we can trust a network we can't name.
    public func refreshTrustItem(ssid: String?, isTrusted: Bool, locationGranted: Bool) {
        if let ssid, !ssid.isEmpty {
            trustItem.isEnabled = true
            trustItem.title = "Trust this Wi-Fi network (\"\(ssid)\")"
            trustItem.state = isTrusted ? .on : .off
        } else {
            trustItem.isEnabled = false
            trustItem.state = .off
            trustItem.title = locationGranted
                ? "Wi-Fi network unknown"
                : "Wi-Fi network unknown (grant Location)"
        }
    }

    /// Update the status icon/title to reflect the current presence state.
    public func render(state: PresenceState) {
        // Skip redundant work: render is called every tick (~1s) but the state
        // rarely changes. Only rebuild the glyph/header when it actually differs.
        guard state != lastRenderedState else { return }
        lastRenderedState = state
        // State-driven, always-visible menu-bar glyph (ND-017). Trust rule: the
        // glyph must read honestly at a glance — warnings/locked get a tint.
        let glyph = glyph(for: state)
        if let button = statusItem.button {
            if let base = NSImage(systemSymbolName: glyph.symbolName,
                                  accessibilityDescription: glyph.label) {
                // EXPERIMENTAL (multi-display bug): never set button.contentTintColor
                // to a non-nil value. A runtime-tinted status-item button only draws on
                // the active display's menu bar; a STATIC colored (non-template) image
                // replicates to all displays' menu bars. So:
                //  - tinted states -> bake the color into a non-template palette image
                //  - nil-tint states -> plain adaptive template (unchanged; replicates fine)
                button.contentTintColor = nil
                if let tint = glyph.tint {
                    let colored = coloredSymbol(base, tint: tint,
                                                accessibilityDescription: glyph.label)
                    colored.isTemplate = false     // static color; do NOT adapt/tint at draw time
                    button.image = colored
                } else {
                    base.isTemplate = true         // adapt to light/dark menu bars
                    button.image = base
                }
                button.title = ""                  // image-only; clear any fallback text
            } else {
                // Never leave the status item blank if the symbol is missing.
                button.image = nil
                button.contentTintColor = nil
                button.title = glyph.fallbackText
            }
        }
        // Surface honest, visible status as the menu header (core trust rule).
        statusItemHeader.title = headerTitle(for: state)
    }

    /// EXPERIMENTAL (multi-display bug): produce a STATIC, non-template symbol image
    /// with `tint` baked into the pixels, so the status item draws on every display's
    /// menu bar (runtime `contentTintColor` only draws on the active display).
    ///
    /// Primary path: `NSImage.SymbolConfiguration(paletteColors:)` applied via
    /// `withSymbolConfiguration(_:)` — a monochrome symbol takes the single palette
    /// color. Fallback (if that yields nothing): `lockFocus` + `sourceAtop` bake, which
    /// fills the symbol's alpha with the tint.
    private func coloredSymbol(_ base: NSImage, tint: NSColor,
                               accessibilityDescription: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        if let configured = base.withSymbolConfiguration(config) {
            configured.accessibilityDescription = accessibilityDescription
            return configured
        }
        // Fallback: bake the tint into the symbol's alpha via sourceAtop.
        let size = base.size
        let baked = NSImage(size: size)
        baked.lockFocus()
        base.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                  operation: .sourceOver, fraction: 1.0)
        tint.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        baked.unlockFocus()
        baked.accessibilityDescription = accessibilityDescription
        return baked
    }

    /// The visual mapping for a presence state: an SF Symbol name, an optional
    /// tint (nil = default template color), an accessibility label, and a short
    /// text fallback used only if the symbol can't be loaded.
    private struct Glyph {
        let symbolName: String
        let tint: NSColor?
        let label: String
        let fallbackText: String
    }

    /// Map a PresenceState to its menu-bar glyph. Exhaustive — every new state
    /// must declare how it looks in the menu bar (no `default`).
    private func glyph(for state: PresenceState) -> Glyph {
        switch state {
        case .unknown:
            return Glyph(symbolName: "hourglass", tint: nil,
                         label: "starting", fallbackText: "…")
        case .present:
            return Glyph(symbolName: "person.fill", tint: .systemGreen,
                         label: "present", fallbackText: "ok")
        case .absent:
            return Glyph(symbolName: "person.slash", tint: nil,
                         label: "away", fallbackText: "away")
        case .callAssumedPresent:
            return Glyph(symbolName: "video.fill", tint: .systemBlue,
                         label: "on a call", fallbackText: "call")
        case .suspended:
            return Glyph(symbolName: "lock.fill", tint: nil,
                         label: "locked / asleep", fallbackText: "lock")
        case .lockFailed:
            return Glyph(symbolName: "exclamationmark.triangle.fill", tint: .systemRed,
                         label: "couldn't lock the screen", fallbackText: "!lock")
        case .cameraUnavailable:
            return Glyph(symbolName: "video.slash.fill", tint: .systemOrange,
                         label: "camera unavailable — grant access", fallbackText: "!cam")
        case .paused:
            return Glyph(symbolName: "pause.circle.fill", tint: .systemGray,
                         label: "paused", fallbackText: "||")
        case .trustedNetwork:
            return Glyph(symbolName: "wifi", tint: .systemGray,
                         label: "paused on trusted Wi-Fi", fallbackText: "wifi")
        }
    }

    /// Map a PresenceState to a short, honest human-readable header string.
    ///
    /// Two overlays sit on top of the raw state:
    /// - While `isEnrolling`, the gate freezes the glyph at .paused; the header must
    ///   say what's actually happening — capturing the user's face — not "paused".
    /// - When `isEnrolled` (identity mode), "present"/"away" become "watching for
    ///   you"/"you're away" so the header honestly reflects that we're matching the
    ///   enrolled user specifically, not merely detecting any face.
    private func headerTitle(for state: PresenceState) -> String {
        if isEnrolling { return "No Donuts — enrolling your face…" }
        switch state {
        case .unknown:            return "No Donuts — starting…"
        case .present:            return isEnrolled ? "No Donuts — watching for you" : "No Donuts — present"
        case .absent:             return isEnrolled ? "No Donuts — you're away" : "No Donuts — away"
        case .paused:             return "No Donuts — paused"
        case .trustedNetwork:     return "No Donuts — paused (trusted Wi-Fi)"
        case .callAssumedPresent: return "No Donuts — on a call"
        case .suspended:          return "No Donuts — locked/asleep"
        case .lockFailed:         return "No Donuts — ⚠️ couldn't lock the screen"
        case .cameraUnavailable:  return "No Donuts — ⚠️ camera unavailable (grant access)"
        }
    }
}
