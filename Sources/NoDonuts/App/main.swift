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
    private var camera: CameraController?
    private var loopTask: Task<Void, Never>?
    private let locker = ScreenLocker()
    private let config = Config()
    // Held in a stored property so it isn't deallocated while observing (ND-013).
    private var sessionMonitor: SessionStateMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController(onLockNow: { [weak self] in
            guard let self, let engine = self.engine, let menuBar = self.menuBar else { return }
            engine.lockNow()
            menuBar.render(state: engine.state)
        })
        self.menuBar = menuBar

        // Wiring: real camera (ND-012) + presence-only Vision detector (ND-020).
        let camera = CameraController()
        self.camera = camera
        let engine = PresenceEngine(
            camera: camera,
            recognizer: FaceDetectionRecognizer(),
            locker: locker,
            config: config
        )
        self.engine = engine

        // Render the initial state before the loop produces its first reading.
        menuBar.render(state: engine.state)

        // ND-013: pause the loop + stop the camera while the Mac is
        // locked/asleep/not-on-console; resume cleanly on unlock/wake (ADR-0009).
        let monitor = SessionStateMonitor()
        self.sessionMonitor = monitor
        monitor.onChange = { [weak self] active in
            guard let self else { return }
            if active {
                self.camera?.resume()
                self.startLoop()
            } else {
                self.stopLoop()
                self.camera?.suspend()
                self.engine?.sessionSuspended()   // reset absence accounting in production (EC-02/EC-13)
                self.menuBar?.render(state: self.engine?.state ?? .suspended)
            }
        }
        monitor.start()

        // Trigger the camera permission prompt once at launch so it never blocks a
        // presence tick — unconditionally, so a launch-while-locked start still
        // prompts (rather than only when the session happens to be active).
        Task { await camera.requestAccessIfNeeded() }

        if monitor.isActive {
            startLoop()
        } else {
            // Launched while locked/asleep: stay suspended until we wake.
            camera.suspend()
            engine.sessionSuspended()   // reset absence accounting in production (EC-02/EC-13)
            menuBar.render(state: engine.state)
        }
    }

    /// Start the presence loop if it isn't already running. A single cancellable
    /// main-actor Task (ADR-0005); idempotent so resume events can't stack loops.
    private func startLoop() {
        guard loopTask == nil, let engine, let menuBar else { return }
        let config = self.config
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                await engine.tick(now: Date())
                // A tick cancelled mid-flight (e.g. session suspend) must not
                // render stale state on top of a freshly-resumed loop.
                if Task.isCancelled { break }
                menuBar.render(state: engine.state)
                try? await Task.sleep(for: .seconds(config.tickIntervalSeconds))
            }
        }
    }

    /// Cancel and clear the loop task so it can be cleanly restarted on resume.
    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopLoop()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only; no Dock icon (LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
