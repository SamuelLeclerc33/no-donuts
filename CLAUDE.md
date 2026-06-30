# CLAUDE.md — No Donuts

Guidance for Claude Code (and humans) working in this repo.

## What this is

A macOS **menu-bar app** that periodically verifies, **fully on-device**, that the enrolled user is in front of the camera. Present → stay unlocked. Gone → lock the Mac. Professional-friendly: never lock the user out during a video call. Name = office anti-"donut" insurance (don't leave your machine unlocked).

## Project status

Scaffolding stage. Docs + decisions + backlog + code stubs only. Not yet buildable end-to-end. **The backlog lives in [`docs/BACKLOG.md`](docs/BACKLOG.md)** — keep it current as work happens.

## Decisions already made (don't relitigate without an ADR)

- **Form factor:** native Swift menu-bar app + LaunchAgent at login. → [ADR-0001](docs/adr/0001-form-factor.md)
- **Face engine:** Apple **Vision** (detection) + **Core ML** face embeddings (identity), all local. No Python, no network. → [ADR-0002](docs/adr/0002-face-recognition-engine.md)
- **Camera-in-use:** try multi-client shared frames; if frames are unavailable, assume the user is present (don't lock during calls). → [ADR-0003](docs/adr/0003-camera-in-use-policy.md)

## Module ownership (expert sub-agents)

Each part of the app has a dedicated sub-agent (in `.claude/agents/`), named after a famous donut eater. Delegate domain work to its owner.

| Domain / module | Owner agent | Lives in |
|---|---|---|
| Presence state machine, grace timers, decision policy, orchestration | **homer** | `Sources/NoDonuts/Presence/` |
| Face detection, embeddings, matching, enrollment | **cooper** | `Sources/NoDonuts/Recognition/` |
| Camera capture (AVFoundation), camera-in-use monitoring, multi-client frames | **blart** | `Sources/NoDonuts/Camera/` |
| Screen locking, fail-safe enforcement, anti-spoofing | **wiggum** | `Sources/NoDonuts/Lock/` |
| Menu-bar UI, settings, enrollment UX, status | **krusty** | `Sources/NoDonuts/App/` |
| Build, packaging, LaunchAgent, codesign, entitlements, release/ops | **gordon** | `Package.swift`, `Resources/`, `scripts/` |

## Conventions

- Swift, targeting current macOS. Prefer Apple frameworks (AVFoundation, Vision, Core ML, AppKit/SwiftUI) over third-party deps.
- **Privacy is a hard requirement:** no camera frame, embedding, or image ever leaves the device or hits the network. No telemetry by default.
- When you change behavior that touches an edge case, update [`docs/EDGE_CASES.md`](docs/EDGE_CASES.md).
- New architectural decision → write an ADR (`adr` skill). Don't bury decisions in code comments.
- Update [`docs/BACKLOG.md`](docs/BACKLOG.md) when you start/finish work (`backlog` skill).

## Build

Requires **full Xcode** (not just Command Line Tools) for a signed menu-bar `.app` with camera entitlements. See the `build-run` skill: [`.claude/skills/build-run/SKILL.md`](.claude/skills/build-run/SKILL.md).

The package is split into `NoDonutsCore` (AppKit-free, testable logic), the `NoDonuts` app, and `EngineCheck` (see [ADR-0007](docs/adr/0007-package-layout-testable-core.md)).

## Tests

Run the engine checks with **`swift run EngineCheck`** — a framework-free harness that verifies the presence/lock decision logic and exits non-zero on failure. It works in **any** toolchain, including Command Line Tools only (where `XCTest` / Swift Testing are unavailable, so `swift test` can't run). Add new engine assertions in `Sources/EngineCheck/main.swift`.

## Documentation site

The `docs/` Markdown is published as a local, fully-offline **MkDocs** (Material) site → see [ADR-0005](docs/adr/0005-docs-site.md). The built `site/` is committed (source-versioned). A **pre-commit hook** regenerates it when `docs/` or `mkdocs.yml` are staged. Setup: `python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt`, then `scripts/install-hooks.sh`. Preview with `.venv/bin/mkdocs serve`. If you edit docs without the hook installed, run `.venv/bin/mkdocs build` and commit `site/` yourself.

## Skills

- `feature` — end-to-end feature workflow (backlog item → trunk commit on `main`), solo + trunk-based, no PRs. Delegates implementation to the owning sub-agent. Adapted from serkoai-core.
- `build-run` — build, sign, install the LaunchAgent, run, grant camera permission
- `backlog` — conventions for the in-repo backlog
- `adr` — write a new architecture decision record

## Sub-agents

Expert owners per domain, named after famous donut eaters (in `.claude/agents/`): **homer** (presence engine), **cooper** (face recognition), **blart** (camera), **wiggum** (lock/security), **krusty** (menu-bar UI), **gordon** (build/packaging/ops). Delegate domain work to its owner — the `feature` workflow does this automatically.
