# ADR-0007 — Package layout: testable core library + framework-free checks

- Status: Accepted
- Date: 2026-06-30
- Owner: gordon / homer

## Context

We need automated verification of the presence/lock decision logic. Two constraints shaped the layout:

1. The logic lived entirely in a single `.executableTarget` (`NoDonuts`) whose `main.swift` runs the AppKit app — an executable target with top-level entry code is awkward to import from a test target.
2. The available toolchain is often **Command Line Tools only** (no full Xcode — see ADR-0001). In that toolchain **neither `XCTest` nor Swift Testing (`import Testing`) is available for the macOS host**, so `swift test` cannot run at all.

## Decision

Split the package into three targets:

- **`NoDonutsCore`** (`.target`, library) — the AppKit-free logic: presence engine, the camera/recognition/lock protocols + stubs, walking-skeleton fakes, and shared types. All public.
- **`NoDonuts`** (`.executableTarget`, depends on `NoDonutsCore`) — the menu-bar app shell (`App/` + `main.swift`, AppKit).
- **`EngineCheck`** (`.executableTarget`, depends on `NoDonutsCore`) — a **framework-free** verification harness (plain assertions + exit code) runnable via `swift run EngineCheck`.

`EngineCheck` is the primary automated test mechanism because it runs in **any** toolchain — including Command Line Tools and CLT-only CI — where `swift test` would fail for lack of a test framework.

## Consequences

- The decision logic is verifiable today (`swift run EngineCheck` exits non-zero on failure) without full Xcode.
- Clean separation: the core has no AppKit dependency, so it stays portable and fast to compile/test.
- `CapturedFrame` gained a `public init()` so cross-module test doubles can construct it.
- When a full-Xcode environment is available, an XCTest/Swift-Testing target can be added alongside `EngineCheck` for richer reporting/IDE integration (optional follow-up) — it would depend on `NoDonutsCore`, which the split now makes trivial.
- A future Xcode `.app` target (ND-018) links `NoDonutsCore` + `NoDonuts`.

## Alternatives considered

- **XCTest / Swift Testing test target** — the conventional choice, but unrunnable in this CLT-only toolchain (no `XCTest`/`Testing` module). Deferred to when full Xcode is the baseline.
- **`--self-test` flag on the app executable** — no restructure, but ships test code in the shipping binary and couples checks to the AppKit entry point. Rejected in favor of a clean core library.
