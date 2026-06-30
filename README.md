# No Donuts 🍩🚫

> Leave your Mac unattended and someone "donuts" you — fires off a cheeky message to the team, or you owe the office a box of donuts. **No Donuts** makes sure that never happens: it watches the camera, and the moment *you* are no longer in front of it, the Mac locks itself.

A macOS menu-bar app that periodically verifies — **fully on-device** — that the enrolled user is present in front of the camera. If you are present, the Mac stays unlocked. If you walk away, it locks. It is built to be professional-friendly: when you are on a video call, it stays out of the way instead of locking you out mid-meeting.

## Status

🚧 **Scaffolding.** This repo currently contains documentation, decisions, a backlog, and code stubs. Nothing is shippable yet. See [`docs/BACKLOG.md`](docs/BACKLOG.md) for what's planned and what's next.

## Core principles

- **Local-only face recognition.** All detection and matching runs on-device via Apple's Vision framework + a Core ML embedding model. No images leave the machine. No API calls, no per-frame token cost.
- **Professional-friendly.** A video call should never get interrupted by an unexpected lock. See [ADR-0003](docs/adr/0003-camera-in-use-policy.md).
- **Fail safe, not fail open — but configurable.** When uncertain, the default leans toward locking (security), with explicit grace periods and overrides to avoid annoyance.
- **User in control.** Menu-bar status, pause, enroll/re-enroll, and tunable sensitivity.

## How it works (target design)

```
every N seconds:
  ├─ is the screen already locked / asleep?      → do nothing
  ├─ is another app using the camera (a call)?   → try shared frames; if none, assume PRESENT
  ├─ grab a frame → Vision face detection
  │     ├─ no face        → ABSENT  (start grace timer)
  │     └─ face found     → Core ML embedding → cosine match vs enrolled
  │           ├─ match    → PRESENT (reset timers)
  │           └─ stranger → ABSENT  (start grace timer)
  └─ if ABSENT longer than grace period          → LOCK
```

Full design in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Decisions made so far

| Decision | Choice | ADR |
|---|---|---|
| Form factor | Menu-bar app + LaunchAgent (auto-start at login) | [ADR-0001](docs/adr/0001-form-factor.md) |
| Face engine | Apple Vision + Core ML embeddings (all local) | [ADR-0002](docs/adr/0002-face-recognition-engine.md) |
| Camera-in-use | Try shared frames; fall back to "assume present" | [ADR-0003](docs/adr/0003-camera-in-use-policy.md) |

## Documentation map

- [`docs/PRD.md`](docs/PRD.md) — what we're building and why
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, data flow, state machine
- [`docs/SECURITY_PRIVACY.md`](docs/SECURITY_PRIVACY.md) — threat model, data handling, anti-spoofing
- [`docs/BACKLOG.md`](docs/BACKLOG.md) — the living backlog (we track work here)
- [`docs/EDGE_CASES.md`](docs/EDGE_CASES.md) — running list of edge cases to validate together
- [`docs/adr/`](docs/adr/) — architecture decision records

## Build / run

A runnable local `.app` is built with `scripts/make-app.sh` — it `swift build`s, assembles the bundle, and **ad-hoc-signs** it with the camera entitlement, using only **Command Line Tools** (no full Xcode needed for local dev — [ADR-0008](docs/adr/0008-app-packaging.md)):

```sh
scripts/make-app.sh        # add --debug for a faster compile
open build/NoDonuts.app
```

Distribution (Developer-ID signing + notarization) needs more — see ND-050. Details in the `build-run` skill: [`.claude/skills/build-run/SKILL.md`](.claude/skills/build-run/SKILL.md).

## Documentation website

The docs in [`docs/`](docs/) are also published as a **local, fully offline** [MkDocs](https://www.mkdocs.org/) site (Material theme). It's self-contained — no remote fonts, no analytics, no network calls — and the generated `site/` is committed, so you can read it without building anything: just open `site/index.html`.

To work on the docs:

```sh
# 1. Install the toolchain (once)
python3 -m venv .venv
.venv/bin/pip install -r docs/requirements.txt

# 2. Live preview while editing → http://localhost:8000
.venv/bin/mkdocs serve

# 3. Build the static site (writes the committed site/ folder)
.venv/bin/mkdocs build

# 4. (Recommended) install the git hook that auto-regenerates site/ on commit
scripts/install-hooks.sh
```

The pre-commit hook runs `mkdocs build` and stages `site/` so the committed output never drifts from the source. If `mkdocs` isn't installed it just warns and lets the commit through. See [ADR-0005](docs/adr/0005-docs-site.md).

## Name

It's an office thing. Don't get donut'd. 🍩
