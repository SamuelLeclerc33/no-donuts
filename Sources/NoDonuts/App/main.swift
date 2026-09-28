import AppKit
import NoDonutsCore
import os.log

// Owner: krusty (app shell) + homer (loop wiring). Entry point.
// Backlog: ND-010, ND-015, ND-035 (pause), ND-036 (trusted Wi-Fi). Runs as an
// accessory (menu-bar only, no Dock icon).
// NOTE: For the real camera prompt + LSUIElement behavior, this must run as a
// signed .app bundle built with Xcode (see ADR-0001, build-run skill).

// ND-052 / ADR-0018: `NoDonuts --unregister` (used by scripts/uninstall-launchagent.sh).
// Handled BEFORE the single-instance guard so it works while (or after) the app runs.
// No UI, no camera: drop both launcher registrations (bundled agent + legacy mainApp)
// and every pending/delivered nd.* notification, so no "isn't running" alert fires
// ~10 min after an uninstall. Scripts can't do this themselves (SMAppService).
if CommandLine.arguments.dropFirst().contains("--unregister") {
    let lines = MainActor.assumeIsolated { LoginItem.unregisterAllForUninstall() }
    let removed = LifecycleNotifier.removeAllForUninstall()
    for line in lines { print("NoDonuts --unregister: \(line)") }
    print("NoDonuts --unregister: removed \(removed) pending/delivered notification(s)")
    exit(0)
}

// ND-083: single-instance guard FIRST — before NSApplication, the status item or the
// camera exist. A second copy exits(0) here; any lock-file error fails open.
SingleInstance.acquireOrExit()
// ND-082: one-time migration from the legacy SMAppService.mainApp login item to the
// bundled KeepAlive agent (keeps the user's "Start at login" choice). Runs AFTER the
// single-instance guard so a duplicate copy exits before touching registration.
MainActor.assumeIsolated { LoginItem.migrateLegacyLoginItemIfNeeded() }
// ND-082: a copy NOT started by launchd (open, install-app.sh) has no KeepAlive. If
// the agent is enabled, hand over to it and exit 0 here; otherwise (not enabled, we
// ARE the agent copy, or the handover can't be confirmed) keep going.
MainActor.assumeIsolated { LauncherHandover.handOverIfNeeded(trigger: "launch") }

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
    /// ND-082 dead-man "isn't running" heartbeat + ND-080 indefinite-pause reminder.
    /// Independent of the enforcement loop (it's about the PROCESS being alive).
    private let lifecycleNotifier = LifecycleNotifier()
    /// ND-082: set once the user confirmed Quit, so a double click can't re-enter.
    private var isQuitting = false
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
    /// Active face embedder (ND-021 Phase 2). Prefer the bundled Core ML FaceNet model
    /// (`CoreMLFaceEmbedder`) for a true face-IDENTITY embedding (durable EC-03 fix); fall
    /// back to `VisionFeaturePrintEmbedder` when the compiled `.mlmodelc` isn't bundled
    /// (its failable init returns nil and logs). Shared by the recognizer AND enrollment,
    /// so both always use the SAME model — enrollment tags its stored vectors with this
    /// embedder's descriptor.version, and a mismatch forces re-enroll (never cross-compared).
    private let embedder: FaceEmbedding = AppDelegate.makeEmbedder()
    private var enrollmentCoordinator: EnrollmentCoordinator?
    private static let appLog = Logger(subsystem: Log.subsystem, category: Log.Category.app)
    /// ND-073: non-secret "user has enrolled under model X" marker (UserDefaults; model
    /// version string only). Shared by the recognizer (status computation) and the
    /// enroll/reset paths (the only writers).
    private let enrollmentMarker = UserDefaultsEnrollmentMarker()
    /// Held so the loop can read `lastIdentityStatus` after each tick (ND-073).
    private var recognizer: IdentityRecognizer?
    /// Last identity status pushed to the menu + notifier (never `.unknown`).
    private var lastPushedIdentity: IdentityStatus = .unknown
    /// Last value the RECOGNIZER published that the loop has already acted on. The loop
    /// only pushes when the recognizer's own publication changes — so a stale value
    /// (e.g. ticks that never reached recognize() right after an enroll/reset) can't
    /// overwrite the fresh store-derived status pushed by those actions.
    private var lastSeenRecognizerIdentity: IdentityStatus = .unknown
    /// Bumped on every store-derived identity refresh (launch, enroll, reset). A tick
    /// that STARTED before a refresh may carry a recognizer status read before it (e.g.
    /// Reset clicked while `recognize()` awaited the embedder) — the loop drops it.
    private var identityGeneration = 0
    /// ND-058/ND-074: last lock self-test result pushed to the menu + notifier (nil until
    /// the first run). Pushed and logged only on change, so the wake re-check is quiet.
    private var lastLockCapability: LockCapability?

    /// Select the launch embedder: Core ML FaceNet if its compiled model is bundled,
    /// otherwise the Vision feature-print fallback. Logs which one is active (honest —
    /// mirrors the existing launch logging), so `log stream` shows the real engine.
    private static func makeEmbedder() -> FaceEmbedding {
        let log = OSLog(subsystem: "com.nodonuts.app", category: "recognition")
        if let coreML = CoreMLFaceEmbedder(resourceName: "FaceNetVGGFace2") {
            os_log("active face embedder = CoreMLFaceEmbedder (%{public}@, %d-d, tuned=%{public}@)",
                   log: log, type: .default,
                   coreML.descriptor.version, coreML.descriptor.outputDimension,
                   coreML.descriptor.thresholdIsTuned ? "yes" : "no")
            return coreML
        }
        os_log("active face embedder = VisionFeaturePrintEmbedder (Core ML model not bundled — fallback)",
               log: log, type: .default)
        return VisionFeaturePrintEmbedder()
    }
    /// True during an enrollment capture: an enforcement-disabled reason (like pause)
    /// so nothing can lock the screen mid-capture. Priority in the gate sits just
    /// below a real session suspend and above pause / trusted Wi-Fi.
    private var isEnrolling = false
    /// ND-102: a Reset's off-main Keychain delete is in flight. Blocks a concurrent
    /// enroll/reset so the delete can't land on top of a fresh enrollment.
    private var isResettingEnrollment = false
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
                    menuBar.render(state: engine.state, lockFailureCount: engine.lockFailureCount)
                    // ND-054: a manual lock failure (.lockFailed, count 0) must alert
                    // now, not wait for the next loop tick (or never, if the loop is off).
                    self.notProtectingNotifier.update(state: engine.state,
                                                      lockFailureCount: engine.lockFailureCount)
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
        // ND-057: refresh dynamic labels (pause remaining, trust item, protection audit)
        // every time the menu opens, not only at the last gate pass.
        menuBar.onMenuWillOpen = { [weak self] in self?.refreshMenuItems() }
        // ND-082: menu Quit asks first (non-blocking window, loop keeps running).
        menuBar.onQuitRequested = { [weak self] in self?.confirmQuit() }
        // ND-082: arm the dead-man notification + heartbeat as early as possible.
        lifecycleNotifier.start()

        // Wiring: real camera (ND-012) + identity recognizer (M2/ND-021, ADR-0012).
        // The IdentityRecognizer falls back to presence-only while the store is empty,
        // so behavior is UNCHANGED until the user enrolls (non-breaking) — any face
        // keeps the Mac unlocked exactly as before; once enrolled, only the enrolled
        // user counts (EC-03). The store + embedder are shared with enrollment below.
        let camera = CameraController()
        self.camera = camera

        // ND-076: the old GLOBAL `matchThreshold` override was model-agnostic (a value
        // tuned for one model carried over to another). Drop it once, before the Settings
        // store / recognizer / threshold log read anything. Overrides are now per-model.
        if let dropped = dropLegacyMatchThresholdKey() {
            os_log("dropped legacy global matchThreshold %{public}@ (ND-076: overrides are now per-model)",
                   log: OSLog(subsystem: "com.nodonuts.app", category: "recognition"),
                   type: .default, String(dropped))
        }

        // Settings (ND-040): create the store (loads persisted values from UserDefaults,
        // falling back to Config defaults). Seed `config` from it so the engine starts
        // with the user's saved grace / tick tunables. The match threshold does NOT flow
        // through Config (ND-076): the store reads/writes the ACTIVE model's per-model key
        // and the recognizer resolves it live per tick from `embedder.descriptor`.
        let settingsStore = SettingsStore(descriptor: embedder.descriptor)
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
            self.refreshProtectionAudit()   // ND-077: a Settings change may weaken/restore protection
        }
        // Log the effective matchThreshold once at launch (pairs with cooper's per-tick
        // score logging for tuning via `log stream`).
        logEffectiveMatchThreshold()
        let recognizer = IdentityRecognizer(
            embedder: embedder,
            store: enrollmentStore,
            marker: enrollmentMarker
        )
        self.recognizer = recognizer
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

        // ND-073: reflect identity status (active / off / not enrolled) from launch,
        // backfilling the marker for users enrolled before it existed.
        refreshIdentityFromStore()

        // Render the initial state before the loop produces its first reading.
        menuBar.render(state: engine.state, lockFailureCount: engine.lockFailureCount)

        // ND-058/ND-074: resolve-only lock self-test (never locks). Warn loudly NOW if
        // this macOS has no usable lock mechanism, instead of at the first walk-away.
        runLockSelfTest()

        // ND-013: pause the loop + stop the camera while the Mac is
        // locked/asleep/not-on-console; resume cleanly on unlock/wake (ADR-0009).
        // All three inputs (session, pause, trusted Wi-Fi) funnel through the
        // single enforcement gate — applyEnforcement() — so there's one place
        // that decides whether the loop/camera run and what the honest state is.
        let monitor = SessionStateMonitor()
        self.sessionMonitor = monitor
        monitor.onChange = { [weak self] active in
            // ND-080 / EC-15: an INDEFINITE pause ends when the session suspends
            // (lock / system sleep / switched away; NOT display sleep, ND-090) so the user comes back protected.
            // Timed pauses keep their own expiry (PausePolicy). Resuming fires the
            // pause onChange → applyEnforcement(); the call below is idempotent.
            if !active { self?.pauseController?.sessionDidSuspend() }
            self?.applyEnforcement()
            // ND-058: re-check on every unlock/wake (e.g. an OS update applied while
            // asleep). Resolve-only, so cheap and safe.
            if active { self?.runLockSelfTest() }
        }
        monitor.start()

        pauseController.onChange = { [weak self] in self?.applyEnforcement() }
        wifiMonitor.onChange = { [weak self] in self?.applyEnforcement() }
        wifiMonitor.start()

        // Initial gate evaluation. Preserves launch-while-locked semantics: if the
        // session isn't active, applyEnforcement() suspends the loop/camera and
        // sets .suspended; priming defers to the first active transition.
        applyEnforcement()

        // ND-082: the previous copy handed over to us after "Start at login" was
        // switched on in Settings; put the Settings window back where the user was.
        if UserDefaults.standard.bool(forKey: LauncherHandover.reopenSettingsKey) {
            UserDefaults.standard.removeObject(forKey: LauncherHandover.reopenSettingsKey)
            openSettings()
        }
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
        menuBar.render(state: engine.state, lockFailureCount: engine.lockFailureCount)
        refreshMenuItems()

        // ND-045: feed the gate's display state to the notifier in BOTH paths. The
        // loop's per-tick update() only runs while enforcement is enabled, so when the
        // gate DISABLES the loop (pause / session-suspend / trusted-network / enrolling)
        // while state was .cameraUnavailable, the notifier would otherwise never see the
        // transition OUT — its 5-min repeat timer would fire forever and the delivered
        // alert would never clear. Because update() is transition-gated on lastState,
        // calling it here and from the loop is idempotent (safe on unchanged state).
        notProtectingNotifier.update(state: engine.state, lockFailureCount: engine.lockFailureCount)
        // ND-080: 30-min "still paused" reminder while an indefinite pause is active;
        // cleared on resume (incl. the suspend-ends-pause path above).
        lifecycleNotifier.updatePause(indefinitelyPaused: pauseController.isIndefinitelyPaused)
    }

    /// ND-082: confirm before a menu Quit stops protection. Hosted in a normal window
    /// (AppWindows) rather than NSAlert.runModal so the loop/heartbeat keep running
    /// while the user decides. Closing the window = Cancel.
    private func confirmQuit() {
        guard !isQuitting else { return }
        appWindows.show(.quitConfirm, title: "Quit No Donuts") {
            QuitConfirmView(
                onQuit: { [weak self] in self?.performUserQuit() },
                onCancel: { [weak self] in self?.appWindows.close(.quitConfirm) }
            )
        }
    }

    /// ND-082: confirmed Quit. Re-schedule the "was quit" reminder (+30 min) and only
    /// terminate once it's registered (bounded by a short timeout in the notifier).
    private func performUserQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        appWindows.close(.quitConfirm)
        lifecycleNotifier.prepareForUserQuit {
            NSApp.terminate(nil)
        }
    }

    /// ND-082: turning OFF "Start at login" while THIS process is the launchd-managed
    /// agent copy. Unregistering makes launchd stop the job, i.e. kill us with no
    /// relaunch, so it is a Quit: confirm it the same way, then go through the same
    /// clean path ("was quit" reminder at +30 min) and only then unregister.
    private func confirmDisableStartAtLogin() {
        guard !isQuitting else { return }
        appWindows.show(.disableLoginConfirm, title: "Turn Off Start at Login") {
            QuitConfirmView(
                title: "Turn off Start at login and quit?",
                message: "No Donuts will quit now and won\u{2019}t start at login. Protection stops until you open it again.",
                quitButtonTitle: "Turn Off and Quit",
                onQuit: { [weak self] in self?.performDisableStartAtLoginAndQuit() },
                onCancel: { [weak self] in self?.appWindows.close(.disableLoginConfirm) }
            )
        }
    }

    private func performDisableStartAtLoginAndQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        appWindows.close(.disableLoginConfirm)
        lifecycleNotifier.prepareForUserQuit { [weak self] in
            guard let self else { return }
            do {
                // launchd may terminate us inside this call; the "was quit" reminder is
                // already registered, and the job is gone, so nothing relaunches us.
                try LoginItem.setEnabled(false)
                NSApp.terminate(nil)
            } catch {
                // Still registered → still managed: stay up and protecting.
                Self.appLog.error("turning off start at login failed: \(error.localizedDescription, privacy: .public)")
                self.isQuitting = false
                self.lifecycleNotifier.cancelUserQuit()
                self.settingsStore?.refresh()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn\u{2019}t turn off Start at login"
                alert.informativeText = "No Donuts is still running and protecting this Mac. You can also remove it in System Settings \u{203A} General \u{203A} Login Items."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Push current pause + trusted-Wi-Fi state into the menu items so labels,
    /// remaining-time, checkmarks, and enablement stay honest after every gate pass.
    private func refreshMenuItems() {
        guard let menuBar, let pauseController, let wifiMonitor else { return }
        menuBar.refreshPauseItem(isPaused: pauseController.isPaused,
                                 remaining: pauseController.remainingDescription())
        let ssid = wifiMonitor.currentSSID()
        // ND-081: trust = SSID + a FRESH router MAC. routerCheck never blocks (reads run
        // off main; only SSIDs with a trusted entry are read), and "verified" only comes
        // from a fresh read, so the label's "trusted" matches what the gate sees.
        let router = wifiMonitor.routerCheck(for: ssid)
        var verifiedMAC: String?
        if case .verified(let mac) = router { verifiedMAC = mac }
        menuBar.refreshTrustItem(ssid: ssid,
                                 status: trustedNetworks.status(ssid: ssid, gatewayMAC: verifiedMAC),
                                 router: router,
                                 locationGranted: wifiMonitor.isLocationGranted,
                                 locationNotDetermined: wifiMonitor.authorizationStatus() == .notDetermined)
        refreshProtectionAudit()
    }

    /// ND-077: surface any security tunable weaker than its default in the menu. Reads
    /// the same live resolvers the recognizer uses (cheap UserDefaults reads).
    private func refreshProtectionAudit() {
        menuBar?.setProtectionReducedReasons(reducedProtectionReasons(descriptor: embedder.descriptor))
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
        guard !isEnrolling, !isResettingEnrollment, let coordinator = enrollmentCoordinator,
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
                self.refreshIdentityFromStore()
                // Re-run the gate so state is consistent whether we finished or were
                // cancelled: restores the loop/camera and re-renders the honest state.
                self.applyEnforcement()
            }
            let result = await coordinator.enroll()
            // ND-073: ONLY a successful enroll records the marker (under the model that
            // produced the vectors). Refresh now so the header clears before the alert.
            if case .success = result {
                self.enrollmentMarker.setMarker(self.embedder.descriptor.version)
                self.refreshIdentityFromStore()
            }
            // A cancelled capture already yielded to .suspended via applyEnforcement()
            // (Fix D); don't pop an alert over the lock screen for it.
            if case .cancelled = result { return }
            // ND-102: the Keychain write runs in a detached task that cancellation can't
            // interrupt; if the session suspended/locked meanwhile, keep the stored
            // enrollment but don't pop a modal over the lock screen.
            if Task.isCancelled { return }
            self.showEnrollmentResult(result)
        }
    }

    /// Reset enrollment (ND-022): clear the stored embeddings so the recognizer falls
    /// back to presence-only. Refresh the header (drops the "watching for you" wording)
    /// and re-run the gate. Ignored while a capture is in flight.
    func resetEnrollment() {
        guard !isEnrolling, !isResettingEnrollment else { return }
        isResettingEnrollment = true
        // ND-102: the Keychain delete can block on an ACL prompt too — run it off main.
        let store = enrollmentStore
        Task { @MainActor [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try store.reset() }
            }.value
            guard let self else { return }
            self.isResettingEnrollment = false
            switch result {
            case .success:
                // ND-073: an in-app Reset is a deliberate "never enrolled" — drop the
                // marker so it doesn't read as .off(.enrollmentMissing). Only on a
                // successful reset: if the delete failed, the enrollment (and its
                // marker) still stand.
                self.enrollmentMarker.clearMarker()
            case .failure(let error):
                Self.appLog.error("reset enrollment failed: \(error.localizedDescription, privacy: .public)")
            }
            self.refreshIdentityFromStore()
            self.applyEnforcement()
        }
    }

    /// ND-073: compute identity status from the store + marker (one Keychain read) and
    /// push it. If the user is enrolled under the active model but the marker is
    /// missing/stale (enrolled before ND-073), backfill it so they aren't later
    /// misreported. `.unknown` (Keychain unavailable) pushes nothing — keep last known.
    ///
    /// ND-102: the Keychain read runs OFF the main actor. On an ad-hoc-signed build the
    /// read can block on the SecurityAgent ACL prompt ("NoDonuts wants to use your
    /// confidential information"); on main that froze the menu and the loop until the
    /// user clicked. While the read is pending the identity display stays at whatever it
    /// was (initially unknown) — we never claim "watching for you" / "identity off" early.
    ///
    /// Generation semantics (ND-073) are kept: the generation is bumped when the refresh
    /// STARTS (so an in-flight tick's recognizer status is dropped), and this refresh's
    /// result is itself dropped if a newer refresh started while it was pending.
    private func refreshIdentityFromStore() {
        identityGeneration &+= 1
        let generation = identityGeneration
        let store = enrollmentStore
        Task { @MainActor [weak self] in
            let state = await Task.detached(priority: .userInitiated) {
                store.enrollmentState()
            }.value
            guard let self, generation == self.identityGeneration else { return }
            self.applyStoreIdentity(state)
        }
    }

    /// Main-actor half of `refreshIdentityFromStore()`: map a store read to an identity
    /// status, backfill the marker ONLY on a real `.active` result, and push it.
    private func applyStoreIdentity(_ state: EnrollmentState) {
        let active = embedder.descriptor.version
        let status = identityStatus(for: state,
                                    activeVersion: active,
                                    markerVersion: enrollmentMarker.markerVersion)
        if status == .active, enrollmentMarker.markerVersion != active {
            enrollmentMarker.setMarker(active)
        }
        pushIdentityStatus(status)
    }

    /// Push an identity status to the menu + notifier when it actually changed.
    /// `.unknown` is ignored (don't flap on a transient Keychain read failure).
    private func pushIdentityStatus(_ status: IdentityStatus) {
        guard status != .unknown, status != lastPushedIdentity else { return }
        lastPushedIdentity = status
        let description = DiagnosticsReporter.identityStatusDescription(status)
        Self.appLog.notice("identity status → \(description, privacy: .public)")
        menuBar?.setIdentityStatus(status)
        notProtectingNotifier.update(identity: status)
    }

    /// ND-058/ND-074: run the resolve-only lock self-test and, on change, log it and push
    /// it to the menu + notifier. `selfTest()` never invokes a lock, so it's safe anytime.
    private func runLockSelfTest() {
        let real = locker.selfTest()
        var display = real
        #if DEBUG
        // DEBUG-only: simulate "no lock mechanism" for the WARNING UI only
        // (`defaults write com.nodonuts.app debugSimulateNoLockMechanism -bool YES`).
        // Never touches the locker — the real lock() path is unaffected.
        if UserDefaults.standard.bool(forKey: "debugSimulateNoLockMechanism") {
            display = LockCapability(available: [])
        }
        #endif
        guard display != lastLockCapability else { return }
        lastLockCapability = display
        let description = DiagnosticsReporter.lockCapabilityDescription(real)
        let simulated = display != real ? " (DEBUG: simulating NONE for display)" : ""
        if real.canLock {
            Self.appLog.notice("lock self-test: available = \(description, privacy: .public)\(simulated, privacy: .public)")
        } else {
            Self.appLog.error("lock self-test: NONE — cannot lock on this macOS")
        }
        menuBar?.setLockCapability(display)
        notProtectingNotifier.update(lockCapability: display)
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
            alert.informativeText = "No Donuts didn't get enough clear looks at your face. Sit at your normal distance, face the camera in good light, hold still for about 6 seconds, and try “Enroll my face…” again. Your previous enrollment (if any) was left unchanged."
        case .inconsistent:
            // ND-063: enough faces, but they didn't agree with each other.
            alert.alertStyle = .warning
            alert.messageText = "Couldn't get a consistent capture"
            alert.informativeText = "The captured images didn't all look like the same face. Make sure only your face is in view, in good light, and hold still for about 6 seconds, then try “Enroll my face…” again. Your previous enrollment (if any) was left unchanged."
        case .cameraUnavailable:
            alert.alertStyle = .warning
            alert.messageText = "Camera unavailable"
            // ND-075: only the built-in camera is trusted (ADR-0015) — say so when that's why.
            alert.informativeText = camera?.lastUnavailableReason == CameraTrustPolicy.noTrustedCameraReason
                ? "No Donuts only uses the Mac\u{2019}s built-in camera (external and virtual cameras aren\u{2019}t trusted), and none is available. Open the lid, then try again."
                : "No Donuts couldn't get a frame from the camera. Check camera permission and that no other app is blocking it, then try again."
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

    /// Copy the Settings store's tunables into `config` (ND-040): `graceSeconds` +
    /// `tickIntervalSeconds`, consumed by the engine/loop. The match threshold is NOT in
    /// Config (ND-076) — the recognizer resolves it per tick from the active model's
    /// descriptor. The store has already clamped these; `Config.validated()` (ND-062) is
    /// the Core guard — applied here too because the LOOP reads `config.tickIntervalSeconds`
    /// directly (the engine validates its own copy in init / updateConfig).
    private func applyStoreToConfig(_ store: SettingsStore) {
        config.tickIntervalSeconds = store.tickIntervalSeconds
        config.graceSeconds = store.graceSeconds
        config = config.validated()
    }

    /// Log the effective identity matchThreshold once (pairs with cooper's per-tick score
    /// logging for tuning via `log stream`). Reads through the shared Core resolver so the
    /// logged value matches what the recognizer will actually use.
    private func logEffectiveMatchThreshold() {
        let log = OSLog(subsystem: "com.nodonuts.app", category: "recognition")
        let resolved = resolvedMatchThreshold(for: embedder.descriptor)
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
            removeTrustedNetwork: { [weak self] network in
                guard let self else { return [] }
                self.trustedNetworks.remove(network)
                // A removed trusted network may re-enable enforcement right now.
                self.applyEnforcement()
                return self.trustedNetworks.all()
            },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            // ND-082: disabling from the managed copy = quitting; everything else is a
            // plain unregister inside the view.
            isAgentManaged: { LauncherHandover.isAgentManaged() },
            confirmDisableStartAtLogin: { [weak self] in self?.confirmDisableStartAtLogin() },
            // ND-082: just enabled while running unmanaged → hand over to the agent
            // copy now (exits this process on success; reopens Settings there).
            didEnableStartAtLogin: { [weak self] in
                guard let self, !self.isQuitting, !self.isEnrolling else { return }
                LauncherHandover.handOverIfNeeded(trigger: "enable", reopenSettings: true)
            }
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
    /// pasteboard (ND-044), including the notification-permission status (ND-082).
    private func copyDiagnostics() {
        guard engine != nil, wifiMonitor != nil else { return }
        // ND-102: fetch the enrollment state off main (a Keychain read can block on an
        // ACL prompt), then gather the rest and copy on the main actor.
        let store = enrollmentStore
        Task { @MainActor [weak self] in
            let enrollment = await Task.detached(priority: .userInitiated) {
                store.enrollmentState()
            }.value
            // ND-082: when notifications are off, the dead-man / paused reminders can't
            // reach the user — surface that in diagnostics.
            let notificationStatus = await LifecycleNotifier.authorizationDescription()
            guard let self, let engine = self.engine, let wifiMonitor = self.wifiMonitor else { return }
            DiagnosticsReporter().copyToPasteboard(
                state: engine.state,
                config: self.config,
                descriptor: self.embedder.descriptor,
                enrollment: enrollment,
                identity: identityStatus(
                    for: enrollment,
                    activeVersion: self.embedder.descriptor.version,
                    markerVersion: self.enrollmentMarker.markerVersion),
                locationStatus: wifiMonitor.authorizationStatus(),
                trustedNetworkCount: self.trustedNetworks.count,
                trustedNetworksNeedingReTrust: self.trustedNetworks.needsReTrustCount,
                currentRouterReadable: {
                    switch wifiMonitor.routerCheck(for: wifiMonitor.currentSSID()) {
                    case .verified: return true
                    case .unreadable: return false
                    case .checking, .notChecked: return nil
                    }
                }(),
                notificationStatusDescription: notificationStatus,
                lockCapability: self.locker.selfTest(),   // resolve-only; reports the REAL result
                cameraUnavailableReason: self.camera?.lastUnavailableReason
            )
        }
    }

    /// Start the presence loop if it isn't already running. A single cancellable
    /// main-actor Task (ADR-0005); idempotent so resume events can't stack loops.
    private func startLoop() {
        guard loopTask == nil, let engine, let menuBar else { return }
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                let generationAtTickStart = self.identityGeneration
                await engine.tick(now: Date())
                // A tick cancelled mid-flight (e.g. session suspend) must not
                // render stale state on top of a freshly-resumed loop.
                if Task.isCancelled { break }
                menuBar.setCameraUnavailableReason(self.camera?.lastUnavailableReason)
                menuBar.render(state: engine.state, lockFailureCount: engine.lockFailureCount)
                // ND-045: honest "not protecting" notification. Only fires on the
                // active loop, so paused/suspended/enrolling states never trigger it.
                notProtectingNotifier.update(state: engine.state, lockFailureCount: engine.lockFailureCount)
                // ND-073: surface identity-status changes the recognizer observed this
                // tick. Note the store caches its first definitive read for the process
                // lifetime, so an EXTERNAL Keychain delete is not seen here — the running
                // recognizer keeps matching the cached vectors (identity stays enforced)
                // and the launch-time refresh flags it as .enrollmentMissing on relaunch.
                // Skip a status from a tick that began before a store-derived refresh.
                if let recognizer = self.recognizer,
                   generationAtTickStart == self.identityGeneration {
                    let seen = recognizer.lastIdentityStatus
                    if seen != .unknown, seen != self.lastSeenRecognizerIdentity {
                        self.lastSeenRecognizerIdentity = seen
                        self.pushIdentityStatus(seen)
                    }
                }
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
