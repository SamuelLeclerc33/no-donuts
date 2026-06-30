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
- [ADR-0006](0006-screen-lock-mechanism.md) — Screen-lock mechanism: synthetic Ctrl-Cmd-Q via osascript — **Accepted**
- [ADR-0007](0007-package-layout-testable-core.md) — Package layout: testable core library + framework-free checks — **Accepted**
- [ADR-0008](0008-app-packaging.md) — Local app packaging: SPM build + bundling script (ad-hoc signed) — **Accepted**
- [ADR-0009](0009-session-suspend.md) — Suspend the presence loop + camera while locked/asleep/inactive — **Accepted**

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
