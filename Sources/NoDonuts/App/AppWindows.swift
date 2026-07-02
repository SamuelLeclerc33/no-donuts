import AppKit
import SwiftUI

// Owner: krusty — window hosting for the LSUIElement (accessory) app (ND-040).
//
// The app has no Dock icon and no normal window surface (menu bar only). To show a
// real, focusable SwiftUI window (Settings and the first-run Onboarding walkthrough)
// we host it in a plain NSWindow via NSHostingController and take care of accessory-app
// activation.
//
// Activation notes: an .accessory app doesn't auto-front/focus its windows the way a
// .regular app does. We deliberately DO NOT flip the activation policy to .regular
// (that would add a Dock icon and violate LSUIElement). Instead we
// `NSApp.activate(ignoringOtherApps:)` and make the window key+front, which is enough
// for the accessory to show and receive keyboard focus. One retained window per kind
// is reused across opens (re-opening just re-fronts the existing window).
@MainActor
final class AppWindows {
    /// The kinds of windows this app can present. One retained NSWindow per kind.
    enum Kind: Hashable {
        case settings
        case onboarding   // first-run walkthrough (ND-043); hosting is identical
    }

    private var windows: [Kind: NSWindow] = [:]
    /// Per-kind window delegates, retained so they keep receiving close callbacks.
    private var delegates: [Kind: WindowCloseDelegate] = [:]

    /// Show (creating on first use, reusing thereafter) a window of `kind` hosting the
    /// given SwiftUI `content`. Reuses the retained window so re-opening from the menu
    /// bar just re-fronts it. Activates the accessory app so the window can take focus.
    ///
    /// - Parameters:
    ///   - kind: which retained window slot to use.
    ///   - title: window title.
    ///   - onClose: optional hook fired whenever the window closes — including via the
    ///     window's red close button, not just a programmatic `close(_:)`. Onboarding
    ///     uses this to guarantee the camera prompt on any exit (code-review #1). Set on
    ///     first creation and refreshed on every show so the latest closure is used.
    ///   - content: the SwiftUI root view (rebuilt each call for a fresh window; an
    ///     existing window keeps its already-hosted view so live @ObservedObject state
    ///     is preserved).
    func show<Content: View>(_ kind: Kind,
                             title: String,
                             onClose: (() -> Void)? = nil,
                             @ViewBuilder content: () -> Content) {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = windows[kind] {
            delegates[kind]?.onClose = onClose
            delegates[kind]?.resetForReopen()   // allow onClose to fire again this session
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false   // we retain it; reuse on next open
        window.center()
        // Fit the SwiftUI content's fitting size.
        window.setContentSize(hosting.view.fittingSize)

        // Retain a delegate so a close via the window's red button (not just a
        // programmatic close) still fires `onClose`. Guard prevents double-firing when a
        // programmatic close is followed by the same notification.
        let delegate = WindowCloseDelegate(onClose: onClose)
        window.delegate = delegate
        delegates[kind] = delegate

        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Order out the retained window of `kind` if it's showing. The window is kept
    /// (isReleasedWhenClosed == false) so a later `show(_:)` re-fronts it. Used by
    /// onboarding's "Finish"; a no-op if the window was never created. The window's
    /// `onClose` hook still fires via the delegate's `windowWillClose`.
    func close(_ kind: Kind) {
        windows[kind]?.close()
    }
}

/// NSWindowDelegate that invokes an `onClose` closure once when the window closes,
/// however it's dismissed (Finish button, programmatic close, or the red close button).
/// Fires at most once per open (reset when the window is shown again).
@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var didFire = false

    init(onClose: (() -> Void)?) {
        self.onClose = onClose
    }

    /// Re-arm so a later show/close cycle fires `onClose` again (the retained window is
    /// reused across opens).
    func resetForReopen() { didFire = false }

    func windowWillClose(_ notification: Notification) {
        guard !didFire else { return }
        didFire = true
        onClose?()
    }
}
