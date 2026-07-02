# ADR-0013 — Settings/onboarding in SwiftUI + login-item via SMAppService

- Status: Accepted
- Date: 2026-07-02
- Owner: krusty (+ gordon for the login item)

## Context

Through M3 the app was AppKit-only (a menu-bar `NSStatusItem`, no windows), and all tuning was via `defaults write` or menu items. M4 needs real windowed UI — a **Settings** form and a first-run **onboarding** flow — plus a user-facing **"Start at login"** toggle. Two decisions fall out: which UI toolkit to use for the windows, and how the settings toggle should register the app as a login item given ND-016 already ships a LaunchAgent.

## Decision

- **Windowed UI is SwiftUI, hosted in AppKit.** `SettingsView` / `OnboardingView` are SwiftUI, presented in a plain `NSWindow` via `NSHostingController` (`AppWindows`). The app stays an `LSUIElement` accessory (no Dock icon); windows are shown by `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` — we do **not** switch to `.regular` activation. One window is retained per kind and reused. SwiftUI is confined to these windows; the menu bar, presence loop, camera, lock, and gate remain AppKit/Core.
- **Live-apply settings.** A `SettingsStore` (`ObservableObject`, UserDefaults-backed) is the single source of truth for the tunables. Changes apply immediately: engine tunables via `PresenceEngine.updateConfig(_:)` + the loop reading `tickIntervalSeconds` each iteration; `matchThreshold` / `antiSpoofEnabled` / `spoofTextureFloor` are read **live** by the recognizer from UserDefaults (the `resolved*` helpers), so the same keys the UI writes are the keys the recognizer reads. No relaunch.
- **"Start at login" uses `SMAppService.mainApp`** (ServiceManagement) — register/unregister the app itself as a login item, live, no sudo, no plist juggling. This is the **user-facing** autostart control.

## Consequences

- Native, maintainable forms with far less boilerplate than hand-built AppKit; SwiftUI stays isolated so the testable AppKit-free Core (ADR-0007) is unaffected.
- **Two autostart mechanisms coexist:** the ND-016 **LaunchAgent** (installed by `scripts/install-launchagent.sh`, the CLI/scripted path) and the Settings **SMAppService** login item (the in-app toggle). Both achieve "start at login"; the app is a singleton menu-bar accessory so there is no real double-launch concern, but installers/users should prefer one. Documented here and in `LoginItem.swift`. (Future cleanup: converge on one — likely SMAppService for the app + retire the LaunchAgent, or vice-versa.)
- On **ad-hoc-signed local builds**, `SMAppService.register()` may throw or land in `.requiresApproval` (System Settings › General › Login Items) — the toggle surfaces the error and reflects the real status; it works cleanly on a Developer-ID-signed, notarized build (ND-050).
- Showing Settings/onboarding does **not** pause enforcement — the presence loop keeps running while a window is open.

## Alternatives considered

- **Pure AppKit windows:** consistent with the existing code but much more boilerplate for a settings form; rejected.
- **A `defaults`-only "settings" story (no window):** already what we had — insufficient for a shippable app; rejected.
- **Reuse the ND-016 LaunchAgent for the toggle** (shell `launchctl` from the app / bundle-embedded agent plist): more moving parts and path juggling than `SMAppService.mainApp`; rejected for the in-app toggle (the LaunchAgent remains the scripted install path).
