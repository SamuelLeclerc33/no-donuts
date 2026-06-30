---
name: feature
description: End-to-end feature workflow for No Donuts — from a GitHub issue (or description) to a merged PR, with a scratchpad for working memory. Solo + GitHub adaptation. Use when implementing a backlog item or new feature beyond a trivial edit.
---

# Feature Workflow (solo + GitHub)

You MUST follow these phases in order. Do NOT skip steps. Do NOT proceed to the next phase without completing the current one.

> **If any quality gate fails**, append the failure and fix to the scratchpad under `## Quality Gates`, fix it, and re-run before proceeding.

> **Context recovery:** If the conversation was compacted or cleared, re-read `.claude/scratchpad/{slug}.md` before continuing — it is the source of truth for decisions, plan, and current phase. Also re-read this workflow file.

**Input:** $ARGUMENTS — a GitHub issue number (e.g. `#12`), a backlog ID (e.g. `ND-030`), and/or a short description. Optional: `--from-current` to branch from HEAD instead of `main`.

---

## Phase 1 — Context

**Entry:** User invokes `/feature`. **Exit:** Branch created, context captured, scratchpad initialized.

1. **Identify the work.** Parse `$ARGUMENTS` for a GitHub issue (`#NN`) and/or a backlog ID (`ND-NNN`). If neither is given and the request is vague, ask for a one-line description.
2. **Fetch context.**
   - GitHub issue: `gh issue view {NN}` → title, body, acceptance criteria.
   - Backlog item: read its line in [docs/BACKLOG.md](../../../docs/BACKLOG.md) and note the **owner agent**.
   - If no backlog item exists yet, add one (`backlog` skill) so the work is tracked.
3. **Create the branch** `feature/{slug}` (slug = issue/backlog id + short description):
   - **Default:** `git fetch origin main 2>/dev/null; git checkout -b feature/{slug} origin/main 2>/dev/null || git checkout -b feature/{slug}`
   - **`--from-current`:** `git checkout -b feature/{slug}`
   - If the branch exists, check it out and note it in the scratchpad.
4. **Initialize scratchpad** — create `.claude/scratchpad/{slug}.md`:

```markdown
# {slug}: {brief description}

## Workflow State
- **Workflow:** feature
- **Current phase:** Phase 1 — Context
- **Branch:** feature/{slug}
- **Base branch:** {main or HEAD via --from-current}

## Source
- **Issue:** {#NN or N/A}
- **Backlog:** {ND-NNN or N/A}
- **Owner agent:** {homer/cooper/blart/wiggum/krusty/gordon}
- **Title / goal:** {...}

## Decisions from Interview
(Phase 2)

## Plan
(Phase 3)

## Implementation Log
(Phase 4)

## Quality Gates
(Phase 5)

## Exchange Log
| # | Who | What |
|---|-----|------|
```

> Update `Current phase` every time you complete a phase.

---

## Phase 2 — Interview

**Entry:** scratchpad initialized. **Exit:** scope questions answered, decisions recorded.

Before planning, fully understand the feature. Conduct a brief interview to fill gaps the issue and codebase don't answer.

**Ask about (if unclear):** scope boundaries (what's OUT), edge cases / failure & empty states, UX expectations, dependencies on other modules, data/storage or migration needs.

**Rules:**
- **ALWAYS use `AskUserQuestion`.** Bundle questions (≤4 per call); multiple calls if needed. Max 5 questions total.
- Every question multiple-choice or yes/no, with a "Recommended" default based on existing patterns/ADRs.
- If everything is clear (or an ADR/edge-case entry already decides it), say so and move on.
- **Edge cases:** if the feature touches a row in [docs/EDGE_CASES.md](../../../docs/EDGE_CASES.md), confirm the decision; if it surfaces a new one, add it.

**Checkpoint** — append to scratchpad under `## Decisions from Interview` (one bullet per decision).

---

## Phase 3 — Planning

**Entry:** interview decisions recorded. **Exit:** plan approved by user.

5. **Load context.** Read the relevant docs for the owning module: [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md), any applicable [ADR](../../../docs/adr/), [docs/SECURITY_PRIVACY.md](../../../docs/SECURITY_PRIVACY.md) (privacy is a hard requirement), and the owning sub-agent's definition in `.claude/agents/`.
6. **Enter Plan Mode** (`EnterPlanMode`) with a plan covering:
   - Approach summary + rationale
   - Files to create/modify and why (which module → which owner agent)
   - Key design decisions from the interview
   - Implementation order / sub-phases
   - Risks & gotchas
   - **Privacy check:** confirm no new network path, no frame/embedding leaves the device.
   - **Context-recovery header** at the top of the plan:
     ```
     > Workflow: .claude/skills/feature/SKILL.md
     > Scratchpad: .claude/scratchpad/{slug}.md
     > On approval: re-read workflow + scratchpad, set phase to 4, execute Phase 4.
     ```
7. **Write plan to scratchpad** under `## Plan` BEFORE presenting. If the user requests changes, update the scratchpad before re-presenting.
8. **New architectural decision?** Write an ADR (`adr` skill) — don't bury it in code.
9. **Get user approval** via the plan-mode UI.

---

## Phase 4 — Implementation

**Entry:** plan approved. **Exit:** feature implemented, build + checks pass.

> **Delegate to the owning sub-agent.** Use the `Agent` tool, picking the domain owner (homer/cooper/blart/wiggum/krusty/gordon — see [CLAUDE.md](../../../CLAUDE.md)). Independent changes → parallel agents; sequential dependencies → ordered agents. Each agent reads the plan context and the files it owns, and reports a summary of changes.

10. **Implement.** Mark the backlog item `[~]` (in progress).
    - **Same-issue check:** if implementing surfaces the same bug/anti-pattern in adjacent code, grep for it; either fix mechanically in-scope or log a new backlog item as follow-up. Note it under `## Implementation Log`.
11. **Build (BLOCKING):** `swift build` (logic). For the full menu-bar app bundle, see the `build-run` skill (requires full Xcode).
12. **Migrations / stored data:** if the enrollment store schema or persisted `Config` changes, verify load/migrate of existing data (don't strand a user's enrollment).

> **Large features (4+ files):** split into sub-phases; after each, update the scratchpad and `/compact`, then re-read the scratchpad and continue.

**Checkpoint** — update `## Implementation Log`: files modified/created (1 line each), build result, anything non-obvious.

---

## Phase 5 — Quality Gates

**Entry:** implementation complete, build passes. **Exit:** gates pass, findings addressed.

13. **Plan vs implementation check** — compare `## Plan` vs `## Implementation Log`; flag deviations for a fix/accept decision.
14. **Run quality gates:**
    - **`/code-review`** on the diff (correctness + simplification).
    - **`/security-review`** — **always**, given the camera + privacy surface. Confirm: on-device only, no network, embeddings encrypted at rest, no fail-open.
    - **`/verify`** (or `/run`) — exercise the change in the real app where feasible (present → unlocked, absent → locks after grace, camera busy → stays unlocked).
15. **Address findings** — fix issues the gates raise; re-run until clean.

**Checkpoint** — update `## Quality Gates`: plan check, code review, security review, verification result.

---

## Phase 6 — Docs

**Entry:** quality gates pass. **Exit:** repo docs reflect reality.

16. **Update the living docs:**
    - [docs/BACKLOG.md](../../../docs/BACKLOG.md): set the item `[x]` (or `[!]` with a reason).
    - [docs/EDGE_CASES.md](../../../docs/EDGE_CASES.md): mark any addressed case `IMPLEMENTED`; add new ones.
    - [docs/adr/](../../../docs/adr/): ensure any decision made is recorded.
    - README / CLAUDE.md if user-facing behavior or build steps changed.

---

## Phase 7 — Ship

**Entry:** docs updated. **Exit:** PR created and CI green.

17. **Show summary:** goal, what was built, key decisions, files modified/created, tests added.
18. **Commit checkpoint** — `AskUserQuestion`: "Ready to commit and push?" → "Yes" | "Not yet, improve first". If improving, **loop back to Phase 2** (focused interview), update the SAME plan, re-run Phases 4–5, return here. Same work — no new scratchpad.
19. **Commit & push.** Branch first if somehow on `main`. End the commit message with the required `Co-Authored-By` trailer.
    - **Account guard (this repo must NOT use the Serko GitHub account).** Before any push or repo creation, confirm the active gh account is the user's intended personal/non-Serko one: `gh auth status`. If it shows a Serko account, STOP — tell the user to run `! gh auth login` (personal) and `! gh auth switch`. Never assume the active account.
    - Confirm the repo-local commit identity is the personal one (`git config --local user.email`), not the global Serko identity.
    - **First push (no remote yet):** once the correct personal account is active, create the repo under it — `gh repo create {owner}/no-donuts --private --source=. --remote=origin --push` (substitute the confirmed personal owner). Then continue.
    - Otherwise: `git push -u origin feature/{slug}`.
20. **Create the PR** — `gh pr create` with a body summarizing the change and linking the issue (`Closes #NN`). End the PR body with the required generated-with trailer.
21. **Monitor CI** — `gh pr checks --watch` (if CI is configured). Fix failures; re-push.
22. **Clean up** — once the PR is merged, delete `.claude/scratchpad/{slug}.md`.

---

## Persistence (MANDATORY)

| System | Purpose | Location |
|--------|---------|----------|
| **Scratchpad** | Working memory — survives compaction | `.claude/scratchpad/{slug}.md` (gitignored) |
| **Repo docs** | Committed history of intent + decisions | `docs/BACKLOG.md`, `docs/EDGE_CASES.md`, `docs/adr/` |

Skipping either is a workflow violation equivalent to skipping the build.

## What this omits (and why)

Adapted from serkoai-core's `/feature`. Removed as not applicable to a solo GitHub project: Linear (→ GitHub Issues), AB Smartly feature toggles, monorepo pnpm/poetry/mypy gates (→ `swift build`), `apps/docs` session logs (→ this repo's backlog/ADRs/edge-cases), `/update-domains`, `/qa-plan`, frontend-standards DAC loop, and the team of named review agents (→ the `/code-review` + `/security-review` skills).
