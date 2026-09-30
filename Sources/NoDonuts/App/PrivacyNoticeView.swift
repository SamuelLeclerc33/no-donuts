import SwiftUI
import NoDonutsCore

// Owner: krusty — ND-123 privacy notice + explicit consent before face enrollment
// (ADR-0024 (d), Québec Law 25). Hosted in a normal, non-modal window via AppWindows
// (ND-070: no runModal, the presence loop keeps protecting while it's open).
//
// No policy lives here: which variant to show and what a choice does are decided by the
// AppDelegate with `PrivacyConsentPolicy` (NoDonutsCore). This view only shows the text
// and forwards the button the user clicked.
//
// Every claim below was checked against the code (see docs/SECURITY_PRIVACY.md and the
// ND-123 note in docs/BACKLOG.md). Change the notice's substance → bump
// `PrivacyConsentPolicy.currentNoticeVersion` so everyone is asked again.
//
// Consent must be a deliberate click: NO button is the default action (Return does
// nothing), the destructive choice is never the default, and Escape / the close button
// is the non-committal "not now" / "ask me later".

/// ND-123: company contact shown in the notice. **PLACEHOLDER** — before rolling out to
/// colleagues, replace the English value in `Resources/en.lproj/Localizable.strings`
/// (and the French one) with the company's privacy officer / IT contact (name, email).
/// Changing only the contact doesn't need a notice-version bump.
enum PrivacyNoticeContact {
    static var text: String {
        String(localized: "your company\u{2019}s privacy officer or IT contact",
               comment: "ND-123 PLACEHOLDER: replace with the company's privacy contact before rollout")
    }
}

/// Which notice to show.
enum PrivacyNoticeVariant: Equatable {
    /// Right before an enrollment would start: "Not now" / "I agree".
    case beforeEnrollment
    /// At launch, face data stored without consent: "Decline and delete my face data" /
    /// "Ask me later" / "I agree". Protection keeps running meanwhile.
    case existingEnrollment
    /// Settings › About › "Privacy notice…": the notice, the recorded answer, and
    /// (when there's something to withdraw) "Withdraw consent and delete my face data".
    case review(status: String, canWithdraw: Bool)
}

/// The actions the notice forwards (wired by the AppDelegate).
@MainActor
struct PrivacyNoticeActions {
    var onAgree: () -> Void = {}
    /// Decline (launch variant) or withdraw (review variant): delete the face data.
    var onDeleteFaceData: () -> Void = {}
    /// "Not now" / "Ask me later" / "Close": record nothing, just close.
    var onDismiss: () -> Void
}

struct PrivacyNoticeView: View {
    let variant: PrivacyNoticeVariant
    let actions: PrivacyNoticeActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                noticeBody
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 380)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 520)
        .onExitCommand(perform: actions.onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)   // ND-100: decorative; the title says it
            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy notice: face recognition")
                    .font(.title3).bold()
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: intro)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var intro: String {
        switch variant {
        case .beforeEnrollment:
            return String(localized: "Before you enroll your face, here is what No Donuts does with it. Enrolling is your choice.")
        case .existingEnrollment:
            return String(localized: "Your face is already enrolled on this Mac, but you haven\u{2019}t agreed to this notice yet. Please read it and choose. No Donuts keeps protecting your Mac while you decide.")
        case .review(let status, _):
            return status
        }
    }

    // MARK: - Notice text

    private var noticeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("What it does",
                    "While protection is on, No Donuts uses the Mac\u{2019}s built-in camera to check, about once a second, that you are the person at this Mac. It locks the screen when you leave or when someone else sits down. The camera light stays on while it checks.")
            section("What is stored",
                    "A face template: a list of numbers calculated from the images taken when you enroll. It is not a photo. It is kept in your login Keychain on this Mac and isn\u{2019}t synced to iCloud. No photos or video are ever saved.")
            section("Nothing leaves this Mac",
                    "No Donuts sends nothing over the network: no internet connection, no cloud, no telemetry. Camera images are analysed in memory and discarded right away.")
            section("Other people",
                    "If someone else is in view, their face is analysed in memory only, to tell them apart from you. It is never stored.")
            section("It\u{2019}s your choice",
                    "Enrolling is voluntary. Without it, No Donuts can\u{2019}t tell faces apart: it keeps the Mac unlocked while any face is in view and locks when nobody is there. You can always lock your Mac yourself with Control-Command-Q or \u{201C}Lock now\u{201D} in the menu.")
            section("Delete it at any time",
                    "Choose \u{201C}Reset enrollment\u{201D} in the No Donuts menu, or \u{201C}Withdraw consent\u{201D} in Settings \u{203A} About \u{203A} Privacy notice. Uninstalling with scripts/uninstall.sh --purge deletes everything No Donuts stored. Do that before you give this Mac to someone else: Migration Assistant or a backup restore can copy your Keychain, and the template with it.")
            VStack(alignment: .leading, spacing: 4) {
                Text("Questions")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: String(localized: "For questions or requests about your data, contact \(PrivacyNoticeContact.text)."))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if isConsentVariant {
                Text("By clicking \u{201C}I agree\u{201D}, you consent to No Donuts creating and keeping a face template of you on this Mac and using it to check that you are the person at it, as described above. You can withdraw your consent at any time.")
                    .font(.callout).bold()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isConsentVariant: Bool {
        switch variant {
        case .beforeEnrollment, .existingEnrollment: return true
        case .review: return false
        }
    }

    /// One heading + paragraph. Keys are LocalizedStringKeys (ND-101).
    private func section(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch variant {
            case .beforeEnrollment:
                Spacer()
                Button("Not now", action: actions.onDismiss)
                    .accessibilityHint(Text("Closes this notice. Nothing is enrolled."))
                Button("I agree", action: actions.onAgree)
                    .accessibilityHint(Text("Records your consent and starts enrolling your face."))
            case .existingEnrollment:
                Button("Decline and delete my face data", role: .destructive,
                       action: actions.onDeleteFaceData)
                    .accessibilityHint(Text("Deletes your face template. No Donuts keeps running without recognizing you."))
                Spacer()
                Button("Ask me later", action: actions.onDismiss)
                    .accessibilityHint(Text("Closes this notice. You\u{2019}ll be asked again next time No Donuts starts."))
                Button("I agree", action: actions.onAgree)
                    .accessibilityHint(Text("Records your consent. Your enrollment is kept."))
            case .review(_, let canWithdraw):
                if canWithdraw {
                    Button("Withdraw consent and delete my face data", role: .destructive,
                           action: actions.onDeleteFaceData)
                        .accessibilityHint(Text("Deletes your face template and forgets your consent. You\u{2019}ll be asked again before any new enrollment."))
                }
                Spacer()
                Button("Close", action: actions.onDismiss)
                    .keyboardShortcut(.defaultAction)   // safe: records and deletes nothing
            }
        }
    }
}
