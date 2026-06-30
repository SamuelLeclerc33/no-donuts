# ADR-0004 — App identity: bundle id, name, minimum macOS

- Status: Accepted
- Date: 2026-06-30
- Owner: gordon

## Context

The scaffold shipped with placeholder identity values (`com.nodonuts.app`, "No Donuts", min macOS 14.0) that were never formally ratified. Before any of the recognition/Vision work lands we need these settled so `Package.swift`, `Info.plist`, and downstream signing/notarization (ND-050) all agree. This ADR records the three identity decisions; it does not relitigate the app concept.

## Decision

- **Bundle ID:** `com.nodonuts.app` (keep the current scaffold value). Apple does not verify domain ownership for bundle identifiers; uniqueness only matters at App ID registration time for notarization.
- **App name:** "No Donuts" (`CFBundleName`), already established in CLAUDE.md.
- **Minimum macOS:** **15.0 Sequoia**, raised from the scaffold's 14.0.

## Consequences

- `Package.swift` (`platforms: [.macOS(.v15)]`) and `Info.plist` (`LSMinimumSystemVersion = 15.0`, `CFBundleName = No Donuts`, `CFBundleIdentifier = com.nodonuts.app`) are now in sync with these decisions.
- Newest-only minimum macOS lets us target the latest Vision / Core ML face APIs and write zero back-compatibility fallbacks for older OS releases. The trade-off — excluding macOS 13/14 users — is acceptable for a v1 on-device tool where staying on current APIs is worth more than reach.
- The bundle ID will be **renamed under a real personal/Chrono signing account at distribution time** as part of ND-050 (codesign + notarization). Until then `com.nodonuts.app` is fine for local/dev builds; nothing about uniqueness or domain ownership blocks development.
- Anyone bumping the minimum macOS again should write a new ADR rather than silently editing two manifests.

## Alternatives considered

- **Min macOS 13/14:** broader install base, but forces conditional code paths and back-compat shims around evolving Vision/Core ML face APIs. Rejected — not worth the maintenance cost for v1.
- **Reverse-DNS bundle ID under a real owned domain now:** premature. The signing identity isn't chosen yet; locking an ID before ND-050 would just be churn.
