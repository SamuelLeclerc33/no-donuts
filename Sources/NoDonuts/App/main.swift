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
            Task { @MainActor in
                guard let self, let engine = self.engine, let menuBar = self.menuBar else { return }
                await engine.lockNow()
                menuBar.render(state: engine.state)
            }
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
                // Defer priming to the first active transition when launched
                // while locked, so the explainer precedes the camera prompt.
                self.primeIfActive()
            } else {
                self.stopLoop()
                self.camera?.suspend()
                self.engine?.sessionSuspended()   // reset absence accounting in production (EC-02/EC-13)
                self.menuBar?.render(state: self.engine?.state ?? .suspended)
            }
        }
        monitor.start()

        if monitor.isActive {
            startLoop()
        } else {
            // Launched while locked/asleep: stay suspended until we wake.
            camera.suspend()
            engine.sessionSuspended()   // reset absence accounting in production (EC-02/EC-13)
            menuBar.render(state: engine.state)
        }

        // Prime permissions once we're active. Self-guards on isActive, so a
        // launch-while-locked start defers priming to the first unlock/active
        // transition — guaranteeing the explainer always precedes the OS camera
        // prompt (never a bare dialog). See monitor.onChange active branch.
        primeIfActive()
    }

    /// Show the one-time camera explainer (if not yet shown) and then trigger the
    /// OS camera-permission prompt — explainer first, always. Self-guards on
    /// `isActive` so nothing prompts while locked/asleep. Idempotent: safe to call
    /// on every active transition — the explainer shows at most once (gated by
    /// `hasPrimedPermissions`) and `requestAccessIfNeeded()` only prompts when the
    /// camera authorization is still not-determined.
    private func primeIfActive() {
        guard let monitor = sessionMonitor, monitor.isActive, let camera = self.camera else { return }
        if !Permissions.hasPrimedPermissions {
            Permissions.hasPrimedPermissions = true
            // One-time camera-only explainer, shown *before* the OS camera prompt.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Enable No Donuts"
            alert.informativeText = "No Donuts uses your camera to check you're at your Mac and locks the screen when you step away — all on-device, nothing is recorded."
            alert.addButton(withTitle: "Continue")
            alert.runModal()
        }
        Task { await camera.requestAccessIfNeeded() }   // idempotent; only prompts if not-yet-determined
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
