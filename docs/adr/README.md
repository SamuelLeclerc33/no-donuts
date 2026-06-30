# Architecture Decision Records

Short, immutable records of significant decisions. Use the `adr` skill to add one.

When a decision changes, don't edit the old ADR's decision — write a new ADR that **supersedes** it and update the status line of the old one.

## Index

- [ADR-0001](0001-form-factor.md) — Form factor: menu-bar app + LaunchAgent — **Accepted**
- [ADR-0002](0002-face-recognition-engine.md) — Face engine: Apple Vision + Core ML embeddings — **Accepted**
- [ADR-0003](0003-camera-in-use-policy.md) — Camera-in-use: try shared frames, fall back to assume-present — **Accepted**

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
