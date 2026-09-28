# ADR-0019 — All presence tunables pass through one validated Config

- Status: Accepted
- Date: 2026-09-28
- Owner: homer

## Context

`matchThreshold` had a validated resolver (ND-076), but the other presence tunables did not. `tickIntervalSeconds` and `graceSeconds` come from Settings/UserDefaults; the rest are code defaults. Unvalidated values are dangerous: a 0 s tick spins the CPU, a huge grace or cap is a fail-open, and a 0-tick consensus locks instantly (ND-062).

## Decision

Every `Config` the engine or the App loop uses goes through `Config.validated()`, which clamps each value into `Config.Bounds`. NaN and ±∞ fall back to the shipped default.

| Tunable | Range |
|---|---|
| tick | 0.5–10 s |
| grace | 2–60 s |
| consensus | 2–20 ticks |
| errors-before-absent | 1–20 |
| busy-camera cap | 60–3600 s |
| camera-unavailable cap | 30–600 s |
| stranger ticks | 1–10 |
| stranger grace | 0–10 s |

`Config.resolved(from:base:)` reads the UserDefaults-settable keys. A missing, non-numeric, Bool or out-of-range value is **rejected** (default kept), not clamped, mirroring `resolvedMatchThreshold`. The result then goes through `validated()`. `PresenceEngine.init`, `updateConfig` and the App's `applyStoreToConfig` all validate. `SettingsStore` takes its slider ranges from `Config.Bounds`, so there is one source of truth.

## Consequences

No path, whether Settings, `defaults write` or future code, can put the engine into a spin, an instant lock, or an unbounded fail-open window. Changing a range is a code change reviewed against this ADR.
