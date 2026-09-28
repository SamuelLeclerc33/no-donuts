import SwiftUI

// Owner: krusty — ND-082 Quit confirmation. Hosted in a regular (non-modal) window via
// AppWindows so the presence loop and heartbeat keep running while it's open (no
// NSAlert.runModal starving the main run loop). Closing the window = Cancel.
//
// Also reused for "Turn off Start at login" from the launchd-managed copy, which is a
// quit too (unregistering stops the job): same window, different copy.
struct QuitConfirmView: View {
    // ND-101: localized defaults; Text(String)/Button(String) render them verbatim.
    var title = String(localized: "Stop protecting this Mac?")
    var message = String(localized: "Your Mac won\u{2019}t lock when you walk away until No Donuts is opened again.")
    var quitButtonTitle = String(localized: "Quit No Donuts")
    let onQuit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)   // ND-100: decorative
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                // Cancel is the safe choice: Escape AND Return both keep protection on.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                Button(quitButtonTitle, role: .destructive, action: onQuit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onExitCommand(perform: onCancel)
    }
}
