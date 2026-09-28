# ADR-0021 — Updates for internal distribution: no in-app updater

- Status: Accepted
- Date: 2026-09-28
- Owner: gordon

## Context

No Donuts has no update mechanism. The usual macOS answer is an in-app updater such as Sparkle, which polls an appcast feed over the network, downloads the new build and installs it.

Two facts make that a poor fit here:

- **Privacy is a hard requirement.** The runtime makes no internet connections today: no telemetry, no model download, no feed. The only network-adjacent access is the trusted-Wi-Fi check, which reads the SSID and looks up the local router's MAC address on the LAN; nothing leaves the local network. An updater would be the only internet connection in a security-sensitive app that holds the camera and a face embedding. Even if it never touches camera data, it adds a network entitlement, a remote code-delivery path, and a server to trust and operate. It also weakens the "this app never talks to the internet" claim that users and IT can currently verify.
- **The distribution target is narrow.** No Donuts is distributed internally to colleagues at one company, on essentially the same Mac hardware (see the distribution target note in the backlog). It is not sold, not public, not on the App Store. The number of installs is small and the people who install it can be reached directly.

Users still need to be able to tell whether they are running the current version, both for themselves and when reporting a problem.

## Decision

1. **No in-app updater.** No Sparkle, no appcast, no background version check, and no "check for updates" network call, opt-in or otherwise. The shipped app makes no internet connections. (The app is not sandboxed, so an entitlement would not block a connection; the guarantee is that no such code ships. If the app is ever sandboxed, `com.apple.security.network.client` stays absent.)
2. **New versions ship as a signed, notarized DMG** (ND-050, ND-051), shared through the company's normal internal channel. The user replaces the app in `/Applications`. The bundle id, Keychain service and enrollment are unchanged, so enrollment survives the replacement (ND-065 guards any future rename). The bundled KeepAlive agent (ADR-0018) relaunches the new binary.
3. **Company MDM is the alternative channel** where colleagues' Macs are managed: IT pushes the same notarized package (ND-053). The choice between DMG and MDM, the signing identity and IT/privacy sign-off are decided in ND-111. This ADR only fixes that neither channel runs through the app itself.
4. **The app shows its version** so people can tell if they are current: `CFBundleShortVersionString` and `CFBundleVersion` appear in the diagnostics report (already done in `DiagnosticsReporter`), and should also appear in the menu and in Settings.
5. **Version numbers must be real.** Every distributed build needs a distinct, increasing `CFBundleShortVersionString`/`CFBundleVersion`. Today `Resources/Info.plist` hard-codes `0.0.1` / `1`. They should be stamped at build time from `git describe` in `scripts/make-app.sh` (ND-067(e)).

## Consequences

- The privacy claim stays simple and checkable: the app makes no internet connections (verifiable with a firewall such as Little Snitch, or `nettop`).
- Users are not told automatically that a new version exists. Announcing releases is a human job (email or chat to the small internal group, or an MDM push). Because the audience is small and reachable, this is acceptable. It would not be for a public release.
- Security fixes reach users only as fast as they install the new DMG, or as fast as MDM pushes it. For urgent fixes, the MDM channel is preferred where it exists.
- No updater means no update-signing keys, appcast hosting, or update-path code to secure and maintain.
- A user who replaces the app keeps their camera permission only if the signing identity and bundle id stay the same (TCC keys on the code signature). This is another reason ND-050 must fix one stable Developer ID identity before the first distributed build.

Follow-up work:

- **ND-067(e)** (gordon): stamp `CFBundleShortVersionString`/`CFBundleVersion` from `git describe` in `scripts/make-app.sh`.
- **krusty**: show the app version in the menu (for example a disabled "No Donuts 1.2.0 (build 42)" item) and in Settings. Diagnostics already includes it.
- **ND-051 / ND-053 / ND-111**: document the DMG replace-in-place steps and the MDM package, including that the KeepAlive agent picks up the new binary.

## Alternatives considered

- **Sparkle (or similar), on by default:** standard and convenient, but adds a network client, a remote code-delivery path and hosting to a privacy-first app. Rejected.
- **Sparkle, opt-in:** keeps the default offline, but the network entitlement and updater code still ship in every build, and the privacy story becomes "offline unless you turned on X". Not worth it for a small internal audience that can be told about updates directly. Rejected. Revisit with a new ADR only if the app is ever distributed publicly.
- **Local "is there a newer version?" check against a file share or internal URL:** still a network call, and still needs a server. Rejected for the same reasons.
- **Mac App Store updates:** out of scope. The app uses private screen-lock API (ADR-0010) and is not distributed publicly.
