import SwiftUI

// Owner: krusty — ND-070 non-blocking message window. Replaces the remaining
// `NSAlert.runModal()` sites (enrollment result, Keychain explainer, "couldn't turn
// off Start at login"). Hosted in a normal window via AppWindows, like
// QuitConfirmView, so the presence loop, the heartbeat and the menu keep running
// while it's on screen. A modal run loop would starve the main actor (no ticks, no
// lock) for as long as the alert stayed up.
//
// Closing the window (red button / Escape) dismisses; the button can be wired to a
// separate `onConfirm` so "Continue" and "close" can differ (e.g. the Keychain
// explainer only starts enrollment on Continue).
struct MessageView: View {
    enum Style {
        case informational
        case warning
    }

    let style: Style
    let title: String
    let message: String
    var buttonTitle = "OK"
    let onDismiss: () -> Void
    /// Primary button (Return). Defaults to `onDismiss` for plain OK-style messages.
    var onConfirm: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    if style == .warning {
                        // Same cue NSAlert's .warning style gives: a badge on the icon.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 18))
                            .offset(x: 4, y: 4)
                    }
                }
                .accessibilityHidden(true)   // ND-100: decorative; title + message carry it
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button(buttonTitle, action: onConfirm ?? onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand(perform: onDismiss)
    }
}
