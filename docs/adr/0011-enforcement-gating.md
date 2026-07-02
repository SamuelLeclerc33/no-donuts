# ADR-0011 — Enforcement gating: pause + trusted Wi-Fi

- Status: Accepted
- Date: 2026-07-01
- Owner: homer + krusty (with gordon for the Location usage string)

## Context

No Donuts continuously enforces presence (lock when the enrolled user is away). Two user needs require *not* enforcing at certain times:

- **Pause** (ND-035): a deliberate, temporary "don't lock me right now" — a coffee break, a whiteboard session, a demo.
- **Trusted networks** (ND-036): don't enforce in places the user considers safe (e.g. home Wi-Fi), identified by the current Wi-Fi SSID.

Separately, ND-013 (ADR-0009) already suspends the loop + camera when the session is locked/asleep/off-console. That is a *third* reason enforcement should be off. Without a unifying model, three independent code paths would each start/stop the loop and set state, and could fight each other (e.g. a pause timer firing while the screen is locked).

Reading the current SSID on modern macOS (CoreWLAN `CWWiFiClient.interface().ssid()`) returns `nil` unless the app has **Location** authorization — so ND-036 forces a new permission decision.

## Decision

**A single enforcement gate in the App layer.** Enforcement is enabled iff:

```
enabled = sessionActive && !paused && !onTrustedNetwork
```

- `sessionActive` — from the existing `SessionStateMonitor` (ND-013).
- `paused` — from a new `PauseController` (in-memory; 15 min / 1 hr auto-resume timers, or indefinite).
- `onTrustedNetwork` — from a new `WiFiMonitor`: `TrustedNetworksStore.isTrusted(currentSSID)`.

All three inputs funnel through one `applyEnforcement()` in the app delegate. **Disabling enforcement reuses the ND-013 suspend path** — stop the loop and turn the camera off — so "not watching" is always signalled by the camera indicator light going dark. When disabled, the engine's *display* state is set by reason **priority**: session-suspended > paused > trusted-network (each via a dedicated engine method — `sessionSuspended()`, `pause()`, `disabledOnTrustedNetwork()` — that also resets absence accounting so re-enabling rebuilds the full consensus + grace, never a grace-less false lock).

**Fail-safe: unknown SSID is never trusted.** `TrustedNetworksStore.isTrusted(nil / "")` returns `false`, so if the SSID can't be read (Location denied/unavailable, no Wi-Fi) the app treats the network as untrusted and **keeps enforcing**. Declining Location never weakens protection.

**Location is optional and lazy.** `NSLocationWhenInUseUsageDescription` is declared; `requestWhenInUseAuthorization()` is called only when the user first marks a network as trusted — never at launch. Location is used *solely* to read the SSID; no coordinates are read, stored, or transmitted, and the SSID itself never leaves the device (it is compared against a local `UserDefaults` list).

**Trusted-list management via the menu, not a settings window.** A checkable "Trust this Wi-Fi network" item toggles the *current* SSID only (add/remove). A full settings pane (ND-040) stays deferred.

## Consequences

- One code path decides whether to run; the three reasons compose cleanly and can't race. New "don't enforce" reasons later (e.g. a calendar hook) drop into the same gate.
- Pause and trusted-network both get honest, distinct menu-bar states; the camera light is an out-of-band trust signal that enforcement is off.
- New permission surface: Location (when-in-use). Mitigated by being optional, lazy, SSID-only, on-device, and fail-safe. Documented in SECURITY_PRIVACY.md.
- Pause is in-memory: it does **not** survive an app relaunch/reboot (a rebooted machine comes back protecting — a safe default). The trusted list *is* persisted (UserDefaults).
- A timed-pause `Timer` may fire late across sleep; acceptable because `applyEnforcement()` re-evaluates on every session/pause/network change (including wake).
- New edge case EC-20 (trusted network); EC-15 (pause) now IMPLEMENTED.
- **Pause is App-gate-only (no engine latch).** The engine deliberately keeps *no* `isPaused` flag: pausing is enforced solely by the App stopping the loop and suspending the camera. This is a fail-*safe* choice — there is no latch that could get stuck "paused" and silently stop locking forever; a stray tick while paused sees the camera suspended and cannot lock. `PresenceEngine.pause()` only sets honest display state + resets absence accounting.
- **Accepted residual (in-flight lock at the instant of disable):** if a lock was *already dispatched* by an in-flight tick at the exact moment the user pauses / joins a trusted network, it still completes and the screen locks. Reaching a lock dispatch requires ~10s of continuous absence, so this is practically unreachable while a user is actively toggling — accepted, not guarded. (Manual "Lock now" is unaffected and always works.)

## Alternatives considered

- **Gating inside the PresenceEngine (Core).** Rejected: both new inputs (pause timers, CoreWLAN/CoreLocation) live in the App/AppKit layer, like `SessionStateMonitor`. Keeping the engine a pure ticking machine preserves the AppKit-free, testable Core split (ADR-0007). The engine only exposes intent methods that set display state + reset accounting.
- **Keep the camera running while paused/trusted (just skip locking).** Rejected: leaving the camera light on while "paused" is dishonest and wastes power. Reusing the suspend path makes "off" unambiguous.
- **Persist pause across relaunch.** Rejected for MVP: a machine that reboots should come back protecting; a forgotten indefinite pause surviving a reboot is a silent fail-open.
- **IP/subnet or geofence instead of SSID.** Rejected: SSID is the user's mental model of "a network"; geofencing needs stronger Location use. SSID via CoreWLAN is the least-privilege fit.
- **A full settings window now (ND-040).** Deferred: the current-SSID menu toggle covers the MVP need with far less surface.
