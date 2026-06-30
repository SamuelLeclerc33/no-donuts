import AppKit

// Owner: krusty — menu-bar UI, status, pause, enroll, settings.
// Backlog: ND-010, ND-022 (enroll UI), ND-035, ND-040, ND-043.

/// Owns the NSStatusItem and reflects PresenceState in the menu bar.
@MainActor
public final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    public init() {
        configureMenu()
        render(state: .unknown)
    }

    private func configureMenu() {
        let menu = NSMenu()
        // TODO(krusty): live status header, Pause (timed + indefinite, ND-035),
        // Enroll my face… (ND-022), Settings… (ND-040), Lock now, Quit.
        menu.addItem(NSMenuItem(title: "No Donuts", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Update the status icon/title to reflect the current presence state.
    public func render(state: PresenceState) {
        // TODO(krusty): map state -> SF Symbol + tint (🟢 present / ⚪️ unknown / ⏸ paused / 🔒 suspended).
        statusItem.button?.title = "🍩"
    }
}
