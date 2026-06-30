---
name: backlog
description: Conventions for the No Donuts backlog kept in docs/BACKLOG.md. Use when adding, updating, starting, or completing backlog items, or when planning work.
---

# Backlog conventions — No Donuts

The backlog lives in [`docs/BACKLOG.md`](../../../docs/BACKLOG.md). It is the single source of truth for planned work — keep it current as you work.

## Format

- Items are grouped under milestones (`M0`…`M5`) plus an Icebox.
- Each item: `- [status] ND-NNN <description> — <owner agent>`
- IDs are stable and monotonically increasing (`ND-001`, `ND-010`, …). Never reuse an ID.
- Owner = the responsible sub-agent (homer, cooper, blart, wiggum, krusty, gordon — see [CLAUDE.md](../../../CLAUDE.md)).

## Status legend

- `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked

## Workflow

1. **Starting work:** set the item to `[~]` and assign yourself as owner if unassigned.
2. **Finishing:** set to `[x]`. If it changed behavior touching an edge case, update [`docs/EDGE_CASES.md`](../../../docs/EDGE_CASES.md).
3. **Blocked:** set to `[!]` and add a one-line reason inline.
4. **New work:** add a new `ND-NNN` under the right milestone. Keep descriptions one line; link an ADR if it's a decision.
5. Don't delete completed items — they're the changelog. Move dropped ideas to the Icebox instead.

## Adding an item (example)

```
- [ ] ND-036 Auto-resume after a timed pause expires — homer
```

## When in doubt

- A bug fix or chore that isn't planned work? Still add an ND item so it's tracked.
- A decision, not a task? Write an ADR (`adr` skill) and reference it from the backlog item.
