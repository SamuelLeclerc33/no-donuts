# ADR-0001 — Form factor: menu-bar app + LaunchAgent

- Status: Accepted
- Date: 2026-06-30
- Owner: gordon / krusty

## Context

The app must run continuously in the background, be controllable by the user (pause, enroll, settings), surface its current state, and start automatically at login. Options ranged from a fully headless daemon to a full windowed app.

## Decision

Build a native Swift **menu-bar app** (`NSStatusItem`, `LSUIElement` — no Dock icon) that runs in the background and exposes status + controls from the menu bar. Auto-start at login via a **LaunchAgent** (`RunAtLoad`).

## Consequences

- Users get a visible status indicator and easy control (pause, enroll, quit) — important for trust in a camera app.
- A bundled `.app` gives us a proper `Info.plist` for `NSCameraUsageDescription` and a clean permission prompt.
- Requires **full Xcode** to build/sign the app bundle (Command Line Tools alone are insufficient). Captured in the backlog and build-run skill.
- LaunchAgent install/uninstall scripting needed (ND-016, ND-052).

## Alternatives considered

- **Headless daemon (no UI):** lighter, but no easy enrollment/settings/status, and a silent camera process erodes trust. Rejected for v1.
- **Full windowed app:** unnecessary footprint for a background presence tool.
