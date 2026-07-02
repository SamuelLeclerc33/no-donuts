import SwiftUI
import AVFoundation

// Owner: krusty — guided first-run onboarding (ND-043). A native SwiftUI stepper hosted
// in an NSWindow (via AppWindows, the same host as Settings), shown at most once on the
// first active launch. It replaces the old bare one-time camera explainer NSAlert with a
// friendlier walkthrough while keeping the exact same first-run priming semantics.
//
// No policy lives here: the view owns no app singletons. Everything it needs to *do*
// (request camera + notification access, start enrollment, close the window) is injected
// as closures via `OnboardingActions`, mirroring SettingsView's `SettingsActions`.
//
// Privacy: no network, no external assets. Copy reuses the explainer + SECURITY_PRIVACY
// tone — on-device, camera-only, nothing recorded or sent.

/// The things the onboarding view needs to *do*, injected by the AppDelegate so the
/// SwiftUI view reaches into no singletons (matches `SettingsActions`).
@MainActor
struct OnboardingActions {
    /// Request camera access (+ notification authorization at first run). Idempotent:
    /// the OS only prompts once. Wired to `camera.requestAccessIfNeeded()` and the
    /// notifier's `requestAuthorizationIfNeeded()` per the M4-045 decision.
    var onRequestCamera: () -> Void
    /// Kick off the existing enrollment capture flow (`AppDelegate.startEnrollment()`).
    /// Reuses the real capture path — no duplicated capture logic here.
    var onEnroll: () -> Void
    /// Close the onboarding window ("Finish"). The AppDelegate closes the retained
    /// NSWindow; first-run gating was already recorded when onboarding was shown.
    var onFinish: () -> Void
}

@MainActor
struct OnboardingView: View {
    let actions: OnboardingActions

    /// The steps of the walkthrough, in order.
    private enum Step: Int, CaseIterable {
        case welcome, camera, enroll, done
    }

    @State private var step: Step = .welcome
    /// Reflected camera state after the user taps "Enable camera" (best-effort nicety).
    @State private var cameraRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .camera:  cameraStep
        case .enroll:  enrollStep
        case .done:    doneStep
        }
    }

    private var welcomeStep: some View {
        stepScaffold(
            symbol: "hand.wave",
            title: "Welcome to No Donuts"
        ) {
            Text("No Donuts uses your camera to check you\u{2019}re at your Mac and locks the screen when you step away — so you never leave it unlocked by accident.")
            Text("Everything happens on-device. No Donuts only looks at the camera to tell whether someone is there. Nothing is ever recorded, saved as a photo, or sent anywhere.")
                .foregroundStyle(.secondary)
        }
    }

    private var cameraStep: some View {
        stepScaffold(
            symbol: "camera",
            title: "Enable the camera"
        ) {
            Text("No Donuts needs camera access to see that you\u{2019}re at your Mac. Frames are checked on-device and immediately discarded — never recorded or uploaded.")
            HStack(spacing: 10) {
                Button("Enable camera\u{2026}") {
                    actions.onRequestCamera()
                    cameraRequested = true
                }
                .buttonStyle(.borderedProminent)
                cameraStatusLabel
            }
            .padding(.top, 2)
        }
    }

    /// Best-effort reflection of the current camera authorization (optional nicety).
    /// Only shown once the user has tapped "Enable camera" so we never pre-empt the
    /// prompt with a scary "denied" the first time the step appears.
    @ViewBuilder
    private var cameraStatusLabel: some View {
        if cameraRequested {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                Label("Camera enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            case .denied, .restricted:
                Label("Camera off — enable it in System Settings \u{203A} Privacy & Security \u{203A} Camera",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            case .notDetermined:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }

    private var enrollStep: some View {
        stepScaffold(
            symbol: "person.crop.circle.badge.checkmark",
            title: "Enroll your face (optional)"
        ) {
            Text("Enrolling teaches No Donuts to recognize *you* specifically, so it stays unlocked only for you and locks for anyone else.")
            Text("You can skip this for now — No Donuts will keep the Mac unlocked whenever *any* face is present until you enroll. You can enroll anytime from the menu-bar icon.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Enroll my face\u{2026}") {
                    actions.onEnroll()
                    step = .done
                }
                .buttonStyle(.borderedProminent)
                Button("Skip for now") { step = .done }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
    }

    private var doneStep: some View {
        stepScaffold(
            symbol: "checkmark.seal",
            title: "You\u{2019}re all set"
        ) {
            Text("No Donuts is now watching for you and will lock your Mac when you step away.")
            Text("Look for the No Donuts icon in your menu bar — that\u{2019}s where you\u{2019}ll find Pause, Enroll my face, Settings, and Lock now.")
                .foregroundStyle(.secondary)
        }
    }

    /// Shared per-step layout: an SF Symbol, a title, and step-specific body content.
    private func stepScaffold<Body: View>(
        symbol: String,
        title: String,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                Text(title).font(.title2).bold()
            }
            VStack(alignment: .leading, spacing: 10, content: body)
        }
    }

    // MARK: - Footer (stepper controls + progress)

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            stepDots
            Spacer()
            if step == .done {
                Button("Finish") { actions.onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { goForward() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Simple progress affordance: one dot per step, current one filled.
    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private func goForward() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }
}
