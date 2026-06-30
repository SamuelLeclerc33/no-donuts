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
        // Keep the menu-bar glyph as a simple placeholder; SF Symbol + tint deferred.
        statusItem.button?.title = "🍩"
        // Surface honest, visible status as the menu header (core trust rule).
        statusItemHeader.title = headerTitle(for: state)
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
        case .lockFailed:         return "No Donuts — ⚠️ can't lock (grant Accessibility)"
        }
    }
}
