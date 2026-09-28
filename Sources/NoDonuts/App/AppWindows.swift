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
        case quitConfirm  // ND-082: non-blocking "Stop protecting this Mac?" confirmation
        case disableLoginConfirm  // ND-082: "Turn off Start at login and quit?" (managed copy)
        // ND-070: non-blocking replacements for the old NSAlert.runModal() sites.
        case enrollmentResult     // outcome of "Enroll my face…"
        case keychainExplainer    // one-time "stored in your Keychain" note before the first enroll
        case startAtLoginError    // "Couldn't turn off Start at login"

        /// ND-117: resizable geometry for kinds that scroll their own content. nil = a
        /// fixed-size window fitted to its SwiftUI content (the message/onboarding kinds).
        var sizing: Sizing? {
            switch self {
            case .settings:
                return Sizing(initial: NSSize(width: SettingsView.defaultSize.width,
                                              height: SettingsView.defaultSize.height),
                              minimum: NSSize(width: SettingsView.minimumSize.width,
                                              height: SettingsView.minimumSize.height),
                              autosaveName: "NoDonutsSettingsWindow")
            default:
                return nil
            }
        }
    }

    /// Geometry of a resizable window: first-open content size, minimum content size,
    /// and the frame autosave name (the user's last size/position is restored).
    struct Sizing {
        let initial: NSSize
        let minimum: NSSize
        let autosaveName: String
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
    ///   - replaceContent: when true, an existing window gets the NEW `content` (and
    ///     title) instead of keeping its old view. Message windows (ND-070) need this:
    ///     their copy differs per show. Settings/onboarding leave it false.
    ///   - content: the SwiftUI root view (rebuilt each call for a fresh window; an
    ///     existing window keeps its already-hosted view so live @ObservedObject state
    ///     is preserved, unless `replaceContent`).
    func show<Content: View>(_ kind: Kind,
                             title: String,
                             replaceContent: Bool = false,
                             onClose: (() -> Void)? = nil,
                             @ViewBuilder content: () -> Content) {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = windows[kind] {
            delegates[kind]?.onClose = onClose
            delegates[kind]?.resetForReopen()   // allow onClose to fire again this session
            if replaceContent {
                let hosting = NSHostingController(rootView: content())
                existing.contentViewController = hosting
                existing.title = title
                existing.setContentSize(hosting.view.fittingSize)
                if !existing.isVisible { existing.center() }
            }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content())
        if kind.sizing != nil {
            // ND-117: the window, not SwiftUI's ideal size, owns the geometry, so the
            // user can resize it (the root view still declares the same minimum).
            hosting.sizingOptions = []
        }
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.isReleasedWhenClosed = false   // we retain it; reuse on next open
        if let sizing = kind.sizing {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = sizing.minimum
            window.setContentSize(sizing.initial)
            // Restore the last size/position if saved; otherwise center the default.
            if !window.setFrameUsingName(sizing.autosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(sizing.autosaveName)
            // A saved frame from an older, smaller layout must still meet the minimum.
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < sizing.minimum.width || content.height < sizing.minimum.height {
                window.setContentSize(NSSize(width: max(content.width, sizing.minimum.width),
                                             height: max(content.height, sizing.minimum.height)))
            }
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.center()
            // Fit the SwiftUI content's fitting size.
            window.setContentSize(hosting.view.fittingSize)
        }

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

    /// Whether the retained window of `kind` is currently on screen.
    func isShowing(_ kind: Kind) -> Bool {
        windows[kind]?.isVisible ?? false
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
