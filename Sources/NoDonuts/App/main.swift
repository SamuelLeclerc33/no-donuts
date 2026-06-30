import AppKit
import NoDonutsCore

// Owner: krusty (app shell) + homer (loop wiring). Entry point.
// Backlog: ND-010, ND-015. Runs as an accessory (menu-bar only, no Dock icon).
// NOTE: For the real camera prompt + LSUIElement behavior, this must run as a
// signed .app bundle built with Xcode (see ADR-0001, build-run skill).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var engine: PresenceEngine?
    private var loopTask: Task<Void, Never>?
    private let locker = ScreenLocker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(onLockNow: { [weak self] in
            guard let self, let engine = self.engine, let menuBar = self.menuBar else { return }
            engine.lockNow()
            menuBar.render(state: engine.state)
        })
        self.menuBar = menuBar

        let config = Config()
        // Wiring: real camera (ND-012) + fake recognizer (ND-020/025 pending).
        let camera = CameraController()
        let engine = PresenceEngine(
            camera: camera,
            recognizer: AlwaysPresentRecognizer(),
            locker: locker,
            config: config
        )
        self.engine = engine

        // Trigger the camera permission prompt once at launch so it never
        // blocks a presence tick inside the loop.
        Task { await camera.requestAccessIfNeeded() }

        // Render the initial state before the loop produces its first reading.
        menuBar.render(state: engine.state)

        // Presence loop: a single cancellable main-actor Task (ADR-0005).
        // Replaces a repeating Timer that broke under Swift 6 strict concurrency.
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                await engine.tick(now: Date())
                menuBar.render(state: engine.state)
                try? await Task.sleep(for: .seconds(config.tickIntervalSeconds))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        loopTask?.cancel()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only; no Dock icon (LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
