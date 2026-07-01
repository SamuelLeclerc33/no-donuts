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
    /// Last state we actually rendered. The presence loop calls render(state:) every
    /// tick (1s); skip the NSImage rebuild + redraw when nothing changed (perf).
    private var lastRenderedState: PresenceState?

    public init(onLockNow: @escaping @MainActor () -> Void) {
        self.onLockNow = onLockNow
        super.init()
        configureMenu()
        render(state: .unknown)
    }

    private func configureMenu() {
        let menu = NSMenu()
        // Minimal walking-skeleton menu (ND-010/ND-015): live status header + Lock now + Quit.
        // TODO(krusty): Pause (ND-035), Enroll my face… (ND-022), Settings… (ND-040).
        statusItemHeader.isEnabled = false
        menu.addItem(statusItemHeader)
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
            if let image = NSImage(systemSymbolName: glyph.symbolName,
                                   accessibilityDescription: glyph.label) {
                image.isTemplate = true            // adapt to light/dark menu bars
                button.image = image
                button.title = ""                  // image-only; clear any fallback text
                button.contentTintColor = glyph.tint
            } else {
                // Never leave the status item blank if the symbol is missing.
                button.image = nil
                button.contentTintColor = glyph.tint
                button.title = glyph.fallbackText
            }
        }
        // Surface honest, visible status as the menu header (core trust rule).
        statusItemHeader.title = headerTitle(for: state)
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
        }
    }

    /// Map a PresenceState to a short, honest human-readable header string.
    private func headerTitle(for state: PresenceState) -> String {
        switch state {
        case .unknown:            return "No Donuts — starting…"
        case .present:            return "No Donuts — present"
        case .absent:             return "No Donuts — away"
        case .paused:             return "No Donuts — paused"
        case .callAssumedPresent: return "No Donuts — on a call"
        case .suspended:          return "No Donuts — locked/asleep"
        case .lockFailed:         return "No Donuts — ⚠️ couldn't lock the screen"
        case .cameraUnavailable:  return "No Donuts — ⚠️ camera unavailable (grant access)"
        }
    }
}
