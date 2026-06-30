# ADR-0005 — Documentation website: MkDocs + Material, offline, committed

- Status: Accepted
- Date: 2026-06-30
- Owner: gordon

## Context

The project's documentation (PRD, Architecture, Security/Privacy, ADRs, Backlog, Edge Cases) lives as Markdown under `docs/`. Reading it raw on disk or only on GitHub is fine but not great: no unified navigation, no search, no consistent presentation. We want a browsable site.

Two hard constraints shape the choice. First, **privacy/no-network is a project-level requirement** — the tooling and the rendered output must not fetch remote assets (fonts, analytics, CDNs). Second, the site must be **consumable locally and offline** without anyone needing to run a build first — i.e. the generated output should be present in the repo.

## Decision

- **Generator:** [MkDocs](https://www.mkdocs.org/) with the [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) theme. Python-based, single `mkdocs.yml`, renders the existing Markdown as-is.
- **Fully offline:** `theme.font: false` (no Google Fonts fetch), no analytics, no social-card/instant-loading plugins that pull remote assets. Material ships its CSS/JS/icons as local static files, so the built site is self-contained.
- **Source-version the output:** the generated `site/` folder is **committed** to the repo so the docs can be opened offline (`site/index.html`) with no build step. `site/` is deliberately **not** in `.gitignore`.
- **Regenerate via pre-commit hook:** `.githooks/pre-commit` runs `mkdocs build` (non-strict) and `git add site/` so the committed output never drifts from the source Markdown. The hook is a no-op (with a clear install hint) when `mkdocs` isn't on PATH, so it never blocks a commit. Installed via `scripts/install-hooks.sh` (`git config core.hooksPath .githooks`).
- **Local-only for now:** no GitHub Pages / CI publishing. Deferred until there's a reason to expose docs publicly.

## Consequences

- Anyone can read the full docs as a navigable site by opening `site/index.html` — no Python, no network, no build. Matches the offline/privacy requirement end to end.
- Build is non-strict on purpose: `docs/BACKLOG.md` links to `../CLAUDE.md`, which lives outside `docs_dir` and would fail `--strict`. We accept that one known warning rather than mangling the source link.
- Committing `site/` means generated files show up in diffs. The pre-commit hook keeps them in sync automatically; the trade-off is larger commits in exchange for zero-setup offline docs.
- Editing docs requires regenerating: contributors should install the hook (`scripts/install-hooks.sh`) or run `mkdocs build` before committing. The hook makes this automatic when the toolchain is present.

## Alternatives considered

- **GitHub Pages / hosted site:** convenient, but introduces a network dependency for reading docs and a publishing pipeline we don't need yet. Deferred, not rejected.
- **Docusaurus / other JS generators:** heavier toolchain (Node), and the default themes lean on remote fonts/assets. More work to make fully offline than Material with `font: false`.
- **Leave docs as raw Markdown:** zero tooling, but no navigation/search and a poorer reading experience. The site is cheap enough to be worth it.
- **Generate but `.gitignore` the output:** smaller repo, but then the docs aren't browsable offline without a build — defeats the main goal.
