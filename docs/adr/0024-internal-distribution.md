# ADR-0024 — Internal distribution: channel, signing, approvals, privacy

- Status: Proposed (owner decisions pending; see "Decisions needed")
- Date: 2026-09-29
- Owner: gordon (with wiggum)

## Context

No Donuts is distributed only to colleagues at the owner's company. They all use essentially the same Mac hardware, and the app is not sold and not public (ND-111). Updates ship with no in-app updater, as a notarized DMG or through company MDM (ADR-0021).

Distribution (ND-050 signing and notarization, ND-051 DMG) is blocked until four things are decided:

1. **Channel:** a DMG, or company MDM.
2. **Signing identity:** today builds are ad-hoc or signed with the self-signed "No Donuts Dev" identity. Gatekeeper rejects those on other Macs. Notarization needs an Apple Developer ID. The repo rule is that it stays separate from work accounts and identities, and the Serko account must never be used.
3. **Approvals:** the app watches the camera continuously and locks the screen through a private API (ADR-0010).
4. **Privacy law:** the app stores face biometrics (embeddings) of each colleague who enrolls. In Québec, Law 25 requires express consent for biometric identity verification, and the IT framework act requires declaring a biometric identification system to the CAI in advance (see `docs/DEPLOYMENT.md`).

## Proposed decision

Each point is the recommended option. The owner confirms or changes it.

- **(a) Channel:** a notarized DMG shared through the company's internal channel. Use MDM instead only if IT already manages the colleagues' Macs; the same notarized package works for both (ND-053).
- **(b) Signing identity:** a Developer ID from the **company's** Apple Developer account (not the Serko account). Colleagues and IT then see the company as the publisher, which makes approval easier. The source repo and the commit identity stay personal; only the release signature belongs to the company. If the company won't provide one, fall back to a personal account ($99/year), with the owner's name as the publisher.
- **(c) Approvals:** get written sign-off from company IT/security before the first install, before anyone outside the owner runs it. Hand them `docs/SECURITY_PRIVACY.md` (threat model, the no-network guarantee, embeddings kept in the Keychain) and a note on the private lock API (ADR-0010).
- **(d) Privacy:**
  - The company privacy officer confirms the Law 25 obligations and whether a CAI declaration is needed before deployment, then files it.
  - The app gets a plain-language privacy notice and an explicit consent step before enrollment: everything stays on the device, embeddings are kept in the Keychain only, how to delete them, and that it is voluntary. This is new backlog work (krusty).
  - No colleague is enrolled before consent.
- **(e) Supported hardware:** pin one fleet profile (Mac model and macOS version) and validate the camera and multi-client behaviour (ND-066, ND-096) and ND-121 on it.
- **(f) Support:** uninstall (ND-052), the diagnostics copy (ND-044), and the owner as the named contact.

## Decisions needed from the owner

1. DMG, or does IT manage the Macs (MDM)?
2. Company Developer ID, or personal? If company, who owns the account?
3. Who in IT/security signs off?
4. Who is the privacy officer, and does the CAI declaration apply?
5. Which Mac model and macOS version make up the fleet profile?

## Consequences

- Once (b) is decided, ND-050 (Developer ID signing, hardened runtime, `notarytool`) and ND-051 (DMG) can start. A Team ID also ends the Keychain re-prompt after each rebuild.
- (d) adds an onboarding consent screen and a privacy notice before any colleague installs.
- Nothing ships to colleagues until (c) and (d) are done.

## Alternatives considered

- **Unsigned or self-signed builds, colleagues bypass Gatekeeper.** Rejected: it trains people to bypass Gatekeeper for a security app, TCC grants are fragile, and IT will reject it.
- **Mac App Store.** Rejected: it's internal only, and the sandbox and review rules conflict with the private lock API and the LaunchAgent.
- **Public distribution.** Out of scope, and it would reopen ND-089 (the model license).
