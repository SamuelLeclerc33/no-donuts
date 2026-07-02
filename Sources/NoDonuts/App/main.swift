import AppKit
import NoDonutsCore

// Owner: krusty (app shell) + homer (loop wiring). Entry point.
// Backlog: ND-010, ND-015, ND-035 (pause), ND-036 (trusted Wi-Fi). Runs as an
// accessory (menu-bar only, no Dock icon).
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
    // All held in stored properties so they aren't deallocated while observing.
    private var sessionMonitor: SessionStateMonitor?
    private let trustedNetworks = TrustedNetworksStore()
    private var pauseController: PauseController?
    private var wifiMonitor: WiFiMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pause (ND-035) + trusted Wi-Fi (ND-036) inputs to the enforcement gate.
        let pauseController = PauseController()
        self.pauseController = pauseController
        let wifiMonitor = WiFiMonitor(store: trustedNetworks)
        self.wifiMonitor = wifiMonitor

        let menuBar = MenuBarController(
            onLockNow: { [weak self] in
                Task { @MainActor in
                    guard let self, let engine = self.engine, let menuBar = self.menuBar else { return }
                    await engine.lockNow()
                    menuBar.render(state: engine.state)
                }
            },
            onPause: { [weak self] seconds in
                self?.pauseController?.pause(for: seconds)
            },
            onResume: { [weak self] in
                self?.pauseController?.resume()
            },
            onToggleTrustCurrentNetwork: { [weak self] in
                guard let self, let wifiMonitor = self.wifiMonitor else { return }
                // Toggle the current SSID. WiFiMonitor owns the lazy Location
                // request AND the first-run pending-trust flow (so the very first
                // click isn't a no-op while Location is still not-determined).
                // Its onChange fires applyEnforcement() when the trust actually
                // lands — synchronously now, or after auth is granted.
                wifiMonitor.requestTrustCurrentNetwork(using: self.trustedNetworks)
                self.applyEnforcement()
            }
        )
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
        // All three inputs (session, pause, trusted Wi-Fi) funnel through the
        // single enforcement gate — applyEnforcement() — so there's one place
        // that decides whether the loop/camera run and what the honest state is.
        let monitor = SessionStateMonitor()
        self.sessionMonitor = monitor
        monitor.onChange = { [weak self] _ in self?.applyEnforcement() }
        monitor.start()

        pauseController.onChange = { [weak self] in self?.applyEnforcement() }
        wifiMonitor.onChange = { [weak self] in self?.applyEnforcement() }
        wifiMonitor.start()

        // Initial gate evaluation. Preserves launch-while-locked semantics: if the
        // session isn't active, applyEnforcement() suspends the loop/camera and
        // sets .suspended; priming defers to the first active transition.
        applyEnforcement()
    }

    /// THE single enforcement gate. Enforcement is ON only when the session is
    /// active AND the user hasn't paused AND we're not on a trusted Wi-Fi network.
    /// Idempotent via loopTask==nil. Every input's change callback funnels here so
    /// there's exactly one place that starts/stops the loop + camera and sets the
    /// engine's honest display state (by priority when disabled). Always re-renders
    /// and refreshes the menu items so the UI never lies about what's happening.
    private func applyEnforcement() {
        guard let engine, let menuBar,
              let monitor = sessionMonitor,
              let pauseController, let wifiMonitor, let camera else { return }

        let sessionActive = monitor.isActive
        let paused = pauseController.isPaused
        let onTrustedNetwork = wifiMonitor.isOnTrustedNetwork
        let enabled = sessionActive && !paused && !onTrustedNetwork
        let loopRunning = loopTask != nil

        if enabled {
            if !loopRunning {
                camera.resume()
                startLoop()
                // Defer priming to the first active transition when launched while
                // locked, so the explainer precedes the camera prompt. Self-guards.
                primeIfActive()
            }
        } else {
            if loopRunning {
                stopLoop()
                camera.suspend()
            }
            // Set the honest DISPLAY state by PRIORITY (session > pause > wifi).
            // Reset absence accounting so the next episode rebuilds full consensus.
            if !sessionActive {
                engine.sessionSuspended()          // .suspended
            } else if paused {
                engine.pause()                     // .paused
            } else {
                engine.disabledOnTrustedNetwork()  // .trustedNetwork
            }
        }

        // Always re-render + refresh menu item state so the UI stays in sync.
        menuBar.render(state: engine.state)
        refreshMenuItems()
    }

    /// Push current pause + trusted-Wi-Fi state into the menu items so labels,
    /// remaining-time, checkmarks, and enablement stay honest after every gate pass.
    private func refreshMenuItems() {
        guard let menuBar, let pauseController, let wifiMonitor else { return }
        menuBar.refreshPauseItem(isPaused: pauseController.isPaused,
                                 remaining: pauseController.remainingDescription())
        let ssid = wifiMonitor.currentSSID()
        menuBar.refreshTrustItem(ssid: ssid,
                                 isTrusted: trustedNetworks.isTrusted(ssid),
                                 locationGranted: wifiMonitor.isLocationGranted)
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
