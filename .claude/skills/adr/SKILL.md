---
name: adr
description: Write a new Architecture Decision Record for No Donuts under docs/adr/. Use when making or recording a significant technical or product decision, or when changing a previous decision.
---

# Writing an ADR — No Donuts

ADRs live in [`docs/adr/`](../../../docs/adr/). They are short, immutable records of significant decisions.

## When to write one

- A choice that shapes architecture, dependencies, security/privacy posture, or product behavior.
- Changing a prior decision → write a **new** ADR that supersedes the old one (don't rewrite history).

## Steps

1. Find the next number: highest existing `NNNN` in `docs/adr/` + 1.
2. Create `docs/adr/NNNN-short-kebab-title.md` using the template below.
3. Set Status to `Accepted` (or `Proposed` if still under discussion).
4. Add it to the index in [`docs/adr/README.md`](../../../docs/adr/README.md).
5. If it changes a previous ADR, set the old one's status to `Superseded by ADR-NNNN`.
6. Link the ADR from the relevant backlog item / edge case.

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
Trade-offs, what becomes easier/harder, follow-up work (link backlog items).

## Alternatives considered
What else we looked at and why we didn't pick it.
```

Keep it tight. An ADR is a paragraph or three per section, not an essay.
