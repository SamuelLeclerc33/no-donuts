import AppKit

// Owner: krusty (app shell) + homer (loop wiring). Entry point.
// Backlog: ND-010, ND-015. Runs as an accessory (menu-bar only, no Dock icon).
// NOTE: For the real camera prompt + LSUIElement behavior, this must run as a
// signed .app bundle built with Xcode (see ADR-0001, build-run skill).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var engine: PresenceEngine?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        let config = Config()
        let store = EnrollmentStore()
        engine = PresenceEngine(
            camera: CameraController(),
            recognizer: VisionCoreMLRecognizer(store: store, matchThreshold: config.matchThreshold),
            locker: ScreenLocker(),
            config: config
        )

        // TODO(homer): drive ticks; render status each tick.
        timer = Timer.scheduledTimer(withTimeInterval: config.tickIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            Task {
                await engine.tick(now: Date())
                await MainActor.run { self.menuBar?.render(state: engine.state) }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only; no Dock icon (LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
