import AppKit
import NoDonutsCore
import os.log

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
    private var config = Config()
    /// ND-045 (EC-07/08/09): posts a local notification when we stop protecting
    /// (camera unavailable) and clears it on recovery. Held so its repeat timer
    /// survives between ticks.
    private let notProtectingNotifier = NotProtectingNotifier()
    // All held in stored properties so they aren't deallocated while observing.
    private var sessionMonitor: SessionStateMonitor?
    private let trustedNetworks = TrustedNetworksStore()
    private var pauseController: PauseController?
    private var wifiMonitor: WiFiMonitor?
    /// Settings (ND-040): the UserDefaults-backed model the SwiftUI form binds to, and
    /// the window host. Both held so the store keeps observing and the window is reused.
    private var settingsStore: SettingsStore?
    private let appWindows = AppWindows()
    // Identity (M2, ND-022): the enrollment store + embedder are shared between the
    // recognizer (reads the enrolled vectors every tick) and the enrollment
    // coordinator (writes them). Held so they aren't deallocated and so enrollment
    // can reuse them.
    private let enrollmentStore = EnrollmentStore()
    private let embedder = VisionFeaturePrintEmbedder()
    private var enrollmentCoordinator: EnrollmentCoordinator?
    /// True during an enrollment capture: an enforcement-disabled reason (like pause)
    /// so nothing can lock the screen mid-capture. Priority in the gate sits just
    /// below a real session suspend and above pause / trusted Wi-Fi.
    private var isEnrolling = false
    /// The in-flight enrollment capture task (code-review #6). Held so it can be
    /// cancelled when the session suspends or the app terminates mid-capture, and so
    /// `isEnrolling` can never get stuck true (enforcement disabled, camera up).
    private var enrollmentTask: Task<Void, Never>?

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
            },
            onEnroll: { [weak self] in self?.startEnrollment() },
            onResetEnrollment: { [weak self] in self?.resetEnrollment() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        self.menuBar = menuBar

        // Wiring: real camera (ND-012) + identity recognizer (M2/ND-021, ADR-0012).
        // The IdentityRecognizer falls back to presence-only while the store is empty,
        // so behavior is UNCHANGED until the user enrolls (non-breaking) — any face
        // keeps the Mac unlocked exactly as before; once enrolled, only the enrolled
        // user counts (EC-03). The store + embedder are shared with enrollment below.
        let camera = CameraController()
        self.camera = camera

        // Settings (ND-040): create the store (loads persisted values from UserDefaults,
        // falling back to Config defaults). Seed `config` from it so the engine and the
        // recognizer start with the user's saved tunables. matchThreshold flows through
        // here (still validated by the store's clamp AND the recognizer's live resolver);
        // this replaces the old ND-024 applyMatchThresholdOverride() launch read.
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        applyStoreToConfig(settingsStore)
        // onChange: rebuild Config from the store + live-apply to the engine. Threshold /
        // anti-spoof are already persisted to their UserDefaults keys by the store and are
        // consumed live by the recognizer on the next tick — no engine round-trip needed
        // for those. The tick interval is picked up by the loop each iteration.
        settingsStore.onChange = { [weak self] in
            guard let self, let engine = self.engine, let store = self.settingsStore else { return }
            self.applyStoreToConfig(store)
            engine.updateConfig(self.config)
        }
        // Log the effective matchThreshold once at launch (pairs with cooper's per-tick
        // score logging for tuning via `log stream`).
        logEffectiveMatchThreshold()
        let recognizer = IdentityRecognizer(
            embedder: embedder,
            store: enrollmentStore,
            matchThreshold: config.matchThreshold
        )
        let engine = PresenceEngine(
            camera: camera,
            recognizer: recognizer,
            locker: locker,
            config: config
        )
        self.engine = engine

        // Enrollment coordinator (ND-022): reuses the same camera + embedder + store.
        // It only captures+embeds+stores; the AppDelegate gates enforcement around it.
        self.enrollmentCoordinator = EnrollmentCoordinator(
            camera: camera,
            embedder: embedder,
            store: enrollmentStore
        )

        // Reflect enrolled vs presence-only in the header from launch.
        menuBar.setEnrolled(enrollmentStore.isEnrolled)

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

        // SESSION-SUSPEND WINS OVER ENROLLING (code-review #5, EC-08): if the Mac
        // locks/sleeps/switches away mid-enrollment, the camera must NOT stay on behind
        // the lock screen. Cancel the in-flight capture and drop the enrolling flag so
        // the special-case below (which keeps the camera up for enrollment) can't fire
        // while suspended. The cancelled task's own defer will also clear isEnrolling,
        // but we clear it here too so this pass computes the honest state immediately.
        if !sessionActive && isEnrolling {
            enrollmentTask?.cancel()
            isEnrolling = false
            menuBar.setEnrolling(false)
        }

        // Enrolling is an enforcement-disabled reason too: nothing may lock while we
        // capture the user's face. It sits high in priority (a deliberate active
        // operation) but strictly BELOW a real session suspend (handled above).
        let enabled = sessionActive && !isEnrolling && !paused && !onTrustedNetwork
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
            // Keep the camera RESUMED for the enrollment special-case ONLY when the
            // session is ACTIVE (code-review #5). When inactive, isEnrolling was
            // already forced false above, so this reduces to a plain camera.suspend().
            let keepCameraForEnrollment = sessionActive && isEnrolling
            if loopRunning {
                stopLoop()
                // The coordinator has exclusive use of capture() (loop stopped) and
                // needs frames flowing while actively enrolling. Every other disabled
                // reason — including a session suspend during enrollment — turns the
                // camera off (light honestly off).
                if !keepCameraForEnrollment { camera.suspend() }
            } else if keepCameraForEnrollment {
                // Enrollment started while the loop was already stopped (e.g. a
                // race after another disabled reason) — make sure the camera is live.
                camera.resume()
            } else if !sessionActive {
                // No loop running and we're suspended (e.g. suspend arrived mid-
                // enrollment): make sure the camera is off, don't leave it up.
                camera.suspend()
            }
            // Set the honest DISPLAY state by PRIORITY:
            //   session-suspended > enrolling > paused > trusted-network.
            // Reset absence accounting so the next episode rebuilds full consensus.
            if !sessionActive {
                engine.sessionSuspended()          // .suspended
            } else if isEnrolling {
                // No Core state for "enrolling": reuse .paused (honest — enforcement
                // IS paused) and let the MenuBarController overlay the header text
                // "enrolling your face…" via setEnrolling(true). No Core change.
                engine.pause()                     // .paused glyph; header overridden
            } else if paused {
                engine.pause()                     // .paused
            } else {
                engine.disabledOnTrustedNetwork()  // .trustedNetwork
            }
        }

        // Always re-render + refresh menu item state so the UI stays in sync.
        menuBar.render(state: engine.state)
        refreshMenuItems()

        // ND-045: feed the gate's display state to the notifier in BOTH paths. The
        // loop's per-tick update() only runs while enforcement is enabled, so when the
        // gate DISABLES the loop (pause / session-suspend / trusted-network / enrolling)
        // while state was .cameraUnavailable, the notifier would otherwise never see the
        // transition OUT — its 5-min repeat timer would fire forever and the delivered
        // alert would never clear. Because update() is transition-gated on lastState,
        // calling it here and from the loop is idempotent (safe on unchanged state).
        notProtectingNotifier.update(state: engine.state)
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

    /// Begin an enrollment capture (ND-022). Treats "enrolling" as an
    /// enforcement-disabled reason so nothing can lock the screen mid-capture:
    /// applyEnforcement() stops the presence loop (giving the coordinator exclusive
    /// use of camera.capture()) while KEEPING the camera resumed. When capture
    /// finishes, we drop the flag, show the result, refresh the header/menu, and let
    /// the gate restore normal enforcement.
    ///
    /// Guards against concurrent enrollment: a second click while capturing is a no-op.
    func startEnrollment() {
        guard !isEnrolling, let coordinator = enrollmentCoordinator,
              let camera, let menuBar else { return }

        // One-time Keychain explainer (macOS's Keychain-access prompt has no custom-text
        // hook like camera/Location, so we set expectations ourselves before the first
        // enrollment write). Shown before capture so it precedes any system prompt.
        if !Permissions.hasExplainedKeychain {
            Permissions.hasExplainedKeychain = true
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "No Donuts stores your face signature in your Keychain"
            alert.informativeText = "So only you can keep this Mac unlocked, No Donuts saves an encrypted face signature (never a photo) in your login Keychain — on this device only, never uploaded. macOS may ask you to allow access to it; choose “Always Allow” so No Donuts can check it without prompting you again."
            alert.addButton(withTitle: "Continue")
            alert.runModal()
        }

        isEnrolling = true
        menuBar.setEnrolling(true)     // freeze header on "enrolling your face…"
        applyEnforcement()             // stops the loop; enrolling display state
        camera.resume()               // ensure frames flow for the coordinator

        // Hold the task so a session suspend / app termination can cancel it
        // (code-review #6). The `defer` guarantees isEnrolling is cleared and the task
        // handle is dropped even if the task is CANCELLED mid-capture — so enforcement
        // can never get stuck off with the camera up. It runs before the awaits, so the
        // cleanup fires no matter where cancellation lands.
        enrollmentTask = Task { @MainActor in
            defer {
                self.isEnrolling = false
                self.enrollmentTask = nil
                self.menuBar?.setEnrolling(false)
                self.menuBar?.setEnrolled(self.enrollmentStore.isEnrolled)
                // Re-run the gate so state is consistent whether we finished or were
                // cancelled: restores the loop/camera and re-renders the honest state.
                self.applyEnforcement()
            }
            let result = await coordinator.enroll()
            // A cancelled capture already yielded to .suspended via applyEnforcement()
            // (Fix D); don't pop an alert over the lock screen for it.
            if case .cancelled = result { return }
            self.showEnrollmentResult(result)
        }
    }

    /// Reset enrollment (ND-022): clear the stored embeddings so the recognizer falls
    /// back to presence-only. Refresh the header (drops the "watching for you" wording)
    /// and re-run the gate. Ignored while a capture is in flight.
    func resetEnrollment() {
        guard !isEnrolling, let menuBar else { return }
        try? enrollmentStore.reset()
        menuBar.setEnrolled(enrollmentStore.isEnrolled)
        applyEnforcement()
    }

    /// Lightweight, honest NSAlert for the enrollment outcome.
    private func showEnrollmentResult(_ result: EnrollmentCoordinator.Result) {
        let alert = NSAlert()
        switch result {
        case .success(let count):
            alert.alertStyle = .informational
            alert.messageText = "You're enrolled"
            alert.informativeText = "No Donuts captured \(count) reference \(count == 1 ? "image" : "images") of your face. It will now stay unlocked only for you — a different face triggers a lock after the grace period. Everything is stored encrypted on this Mac; no images are kept."
        case .notEnoughFaces:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't see your face"
            alert.informativeText = "No Donuts didn't get enough clear looks at your face. Face the camera in good light and try “Enroll my face…” again. Your previous enrollment (if any) was left unchanged."
        case .cameraUnavailable:
            alert.alertStyle = .warning
            alert.messageText = "Camera unavailable"
            alert.informativeText = "No Donuts couldn't get a frame from the camera. Check camera permission and that no other app is blocking it, then try again."
        case .saveFailed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save your enrollment"
            alert.informativeText = "No Donuts saw your face but couldn't save your enrollment. Please try again. Your previous enrollment (if any) was left unchanged."
        case .cancelled:
            // Cancelled captures are handled silently by the caller (no alert over the
            // lock screen); this case keeps the switch exhaustive.
            alert.alertStyle = .informational
            alert.messageText = "Enrollment cancelled"
            alert.informativeText = "Enrollment was interrupted. Your previous enrollment (if any) was left unchanged."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// First-run priming. On the very first active launch this shows the guided
    /// onboarding window (ND-043) — which now OWNS the camera + notification prompts
    /// (the user taps "Enable camera" inside it) — replacing the old bare explainer
    /// NSAlert. On every subsequent active transition it just re-fires
    /// `requestAccessIfNeeded()` (idempotent; only prompts when camera auth is still
    /// not-determined) so a first launch that dismissed onboarding without granting
    /// still lands the prompt. Self-guards on `isActive` so nothing prompts while
    /// locked/asleep, preserving the launch-while-locked deferral (priming waits for
    /// the first active transition via applyEnforcement's primeIfActive() call).
    private func primeIfActive() {
        guard let monitor = sessionMonitor, monitor.isActive, let camera = self.camera else { return }
        if !Permissions.hasPrimedPermissions {
            // Record first-run *now* (before the window is presented) so onboarding
            // shows at most once — matching the old explainer's gating semantics.
            // The window drives the actual camera/notification prompts on demand.
            Permissions.hasPrimedPermissions = true
            openOnboarding()
            return
        }
        // Subsequent launches: keep the prompts idempotently wired (unchanged).
        Task { await camera.requestAccessIfNeeded() }   // idempotent; only prompts if not-yet-determined
        // ND-045: request notification authorization at first launch, alongside the
        // camera prompt (the decision). requestAuthorization is idempotent, so it's
        // safe to call on every active transition; the OS only prompts once.
        notProtectingNotifier.requestAuthorizationIfNeeded()
    }

    /// Present the first-run onboarding window (ND-043) in the accessory app. Injects
    /// the actions the SwiftUI view can't own: camera + notification authorization
    /// (the same calls the old explainer path made — camera prompt + ND-045
    /// notification auth), the existing enrollment flow, and closing the window.
    private func openOnboarding() {
        let actions = OnboardingActions(
            onRequestCamera: { [weak self] in
                // Camera + notification prompts (both idempotent). Same call the exit
                // paths use, so the request happens exactly once regardless (code-review #1).
                self?.requestOnboardingPermissionsIfNeeded()
            },
            onEnroll: { [weak self] in self?.startEnrollment() },
            onFinish: { [weak self] in self?.closeOnboarding() }
        )
        // onClose: if the user dismisses onboarding via the window's red close button
        // (bypassing "Finish"), still guarantee the camera/notification prompt this
        // session (code-review #1). Idempotent, so double-firing with closeOnboarding()
        // — which also runs on Finish — never double-prompts.
        appWindows.show(.onboarding, title: "Welcome to No Donuts",
                        onClose: { [weak self] in self?.requestOnboardingPermissionsIfNeeded() }) {
            OnboardingView(actions: actions)
        }
    }

    /// Close the onboarding window ("Finish") — or handle its dismissal via the window's
    /// close button (routed here by AppWindows' onboarding-close hook). AppWindows retains
    /// the window, so this just orders it out; first-run was already recorded when shown.
    ///
    /// CRITICAL (code-review #1, silent-unprotected): however the user LEAVES onboarding —
    /// tapping Finish OR clicking the window's close button, WITHOUT ever tapping "Enable
    /// camera" — we must still trigger the camera prompt this session. Otherwise camera
    /// auth stays `.notDetermined` and the app silently doesn't protect until some later
    /// active transition re-primes. That guarantee lives in the window's `onClose` hook
    /// (see `openOnboarding`), which fires on EVERY dismissal — Finish OR the red close
    /// button. So this only needs to order the window out; `close(_:)` triggers
    /// `windowWillClose` → the hook → the (idempotent) camera/notification request.
    private func closeOnboarding() {
        appWindows.close(.onboarding)
    }

    /// Trigger the camera + notification prompts if they haven't happened yet. Both calls
    /// are idempotent (the OS prompts at most once), so this is safe to call from the
    /// "Enable camera" button AND every onboarding-exit path (code-review #1).
    private func requestOnboardingPermissionsIfNeeded() {
        guard let camera = self.camera else { return }
        Task { await camera.requestAccessIfNeeded() }   // idempotent; only prompts if not-determined
        notProtectingNotifier.requestAuthorizationIfNeeded()
    }

    /// Copy the Settings store's tunables into `config` (ND-040). These three fields are
    /// consumed via Config: `graceSeconds` + `tickIntervalSeconds` by the engine/loop,
    /// and `matchThreshold` as the recognizer's BASE default (the recognizer still
    /// resolves the live `matchThreshold` UserDefaults key per tick, so a Settings change
    /// applies immediately even before the next engine.updateConfig). The store has
    /// already clamped these to sane ranges; the Core resolvers remain the final guard.
    private func applyStoreToConfig(_ store: SettingsStore) {
        config.tickIntervalSeconds = store.tickIntervalSeconds
        config.graceSeconds = store.graceSeconds
        config.matchThreshold = store.matchThreshold
    }

    /// Log the effective identity matchThreshold once (pairs with cooper's per-tick score
    /// logging for tuning via `log stream`). Reads through the shared Core resolver so the
    /// logged value matches what the recognizer will actually use.
    private func logEffectiveMatchThreshold() {
        let log = OSLog(subsystem: "com.nodonuts.app", category: "recognition")
        let resolved = resolvedMatchThreshold(default: config.matchThreshold)
        os_log("identity matchThreshold = %.2f", log: log, type: .default, resolved)
    }

    /// Open (or re-front) the SwiftUI Settings window (ND-040). Injects the SettingsStore
    /// and the actions the view can't own: trusted-network removal (→ store.remove +
    /// applyEnforcement so the gate re-evaluates immediately), and diagnostics copy (→
    /// DiagnosticsReporter with the live engine state / config / enrollment / location /
    /// trusted count). Autostart is handled inside the view via LoginItem directly.
    private func openSettings() {
        guard let settingsStore else { return }
        let actions = SettingsActions(
            removeTrustedNetwork: { [weak self] ssid in
                guard let self else { return [] }
                self.trustedNetworks.remove(ssid)
                // A removed trusted network may re-enable enforcement right now.
                self.applyEnforcement()
                return self.trustedNetworks.all()
            },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() }
        )
        // Refresh externally-sourced state (login-item registration + trusted list) BEFORE
        // presenting, EVERY time — a re-fronted retained window won't re-fire SwiftUI's
        // `.onAppear`, so without this the reused Settings window shows stale "Start at
        // login" / trusted-network values after they changed elsewhere (code-review #2).
        settingsStore.trustedNetworksProvider = { [weak self] in self?.trustedNetworks.all() ?? [] }
        settingsStore.refresh()
        appWindows.show(.settings, title: "No Donuts Settings") {
            SettingsView(store: settingsStore, actions: actions)
        }
    }

    /// Gather the live inputs and copy a privacy-safe diagnostics summary to the
    /// pasteboard (ND-044). Notification status isn't exposed by the notifier, so it's
    /// omitted (the reporter treats a nil description as absent).
    private func copyDiagnostics() {
        guard let engine, let wifiMonitor else { return }
        DiagnosticsReporter().copyToPasteboard(
            state: engine.state,
            config: config,
            store: enrollmentStore,
            locationStatus: wifiMonitor.authorizationStatus(),
            trustedNetworkCount: trustedNetworks.all().count,
            notificationStatusDescription: nil
        )
    }

    /// Start the presence loop if it isn't already running. A single cancellable
    /// main-actor Task (ADR-0005); idempotent so resume events can't stack loops.
    private func startLoop() {
        guard loopTask == nil, let engine, let menuBar else { return }
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                await engine.tick(now: Date())
                // A tick cancelled mid-flight (e.g. session suspend) must not
                // render stale state on top of a freshly-resumed loop.
                if Task.isCancelled { break }
                menuBar.render(state: engine.state)
                // ND-045: honest "not protecting" notification. Only fires on the
                // active loop, so paused/suspended/enrolling states never trigger it.
                notProtectingNotifier.update(state: engine.state)
                // Read the interval fresh each iteration so a Settings change to the
                // check interval (ND-040) live-applies without restarting the loop.
                try? await Task.sleep(for: .seconds(self.config.tickIntervalSeconds))
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
        // Cancel any in-flight enrollment so the camera doesn't stay up during a
        // ~2s capture that outlives the app's teardown (code-review #6/#5). The task's
        // defer clears isEnrolling; the process is going away regardless.
        enrollmentTask?.cancel()
        enrollmentTask = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only; no Dock icon (LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
