# Architecture Decision Records

Short, immutable records of significant decisions. Use the `adr` skill to add one.

When a decision changes, don't edit the old ADR's decision — write a new ADR that **supersedes** it and update the status line of the old one.

## Index

- [ADR-0001](0001-form-factor.md) — Form factor: menu-bar app + LaunchAgent — **Accepted**
- [ADR-0002](0002-face-recognition-engine.md) — Face engine: Apple Vision + Core ML embeddings — **Accepted**
- [ADR-0003](0003-camera-in-use-policy.md) — Camera-in-use: try shared frames, fall back to assume-present — **Accepted**
- [ADR-0004](0004-app-identity.md) — App identity: bundle id, name, minimum macOS — **Accepted**
- [ADR-0005](0005-presence-loop-concurrency.md) — Presence loop concurrency: main-actor-driven loop — **Accepted**
- [ADR-0005](0005-docs-site.md) — Documentation website: MkDocs + Material, offline, committed — **Accepted** ⚠️ duplicate number (see ND-019)
- [ADR-0006](0006-screen-lock-mechanism.md) — Screen-lock mechanism: synthetic Ctrl-Cmd-Q via osascript — **Superseded by ADR-0010**
- [ADR-0007](0007-package-layout-testable-core.md) — Package layout: testable core library + framework-free checks — **Accepted**
- [ADR-0008](0008-app-packaging.md) — Local app packaging: SPM build + bundling script (ad-hoc signed) — **Accepted**
- [ADR-0009](0009-session-suspend.md) — Suspend the presence loop + camera while locked/asleep/inactive — **Accepted**
- [ADR-0010](0010-screen-lock-no-accessibility.md) — Screen-lock mechanism: layered no-Accessibility lock (SACLockScreenImmediate → CGSession -suspend), CGSession-verified, async — **Accepted**
- [ADR-0011](0011-enforcement-gating.md) — Enforcement gating: single gate combining session + pause + trusted Wi-Fi; disable reuses the suspend path; SSID fail-safe; lazy Location — **Accepted**
- [ADR-0012](0012-local-identity-featureprint.md) — Local identity: Vision feature-print embedder (behind a protocol, future Core ML swap) + Keychain enrollment store — **Accepted** (amends ADR-0002; amended by ADR-0014)
- [ADR-0013](0013-settings-ui-and-login-item.md) — Settings/onboarding in SwiftUI (hosted in AppKit), live-apply; "Start at login" via SMAppService (complements the ND-016 LaunchAgent) — **Accepted**
- [ADR-0014](0014-coreml-face-embedding-model.md) — Core ML face-recognition embedding behind a model-agnostic descriptor; FaceNet/VGGFace2 internal model; embedding versioning + forced re-enrollment (model-file-independent Phase 1) — **Accepted** (amends ADR-0012)
- [ADR-0015](0015-camera-trust-built-in-only.md) — Camera trust: built-in camera only; external, Continuity and virtual cameras are never used — **Accepted**

## Template

```markdown
# ADR-NNNN — <title>

- Status: Proposed | Accepted | Superseded by ADR-XXXX
- Date: YYYY-MM-DD
- Owner: <agent/person>

## Context
What forces are at play? What problem are we deciding on?

## Decision
The choice we made, stated plainly.

## Consequences
Trade-offs, what becomes easier/harder, follow-up work.

## Alternatives considered
What else we looked at and why we didn't pick it.
```
