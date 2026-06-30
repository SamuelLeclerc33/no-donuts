# ADR-0002 — Face engine: Apple Vision + Core ML embeddings

- Status: Accepted
- Date: 2026-06-30
- Owner: cooper

## Context

Recognition must be **fully local** (privacy + no per-frame API cost), low-power (runs every few seconds), and easy to ship/sign on macOS. We need both *detection* (is there a face?) and *identity* (is it the enrolled user?).

## Decision

- **Detection:** Apple **Vision** framework (`VNDetectFaceRectanglesRequest` / landmarks).
- **Identity:** a local **Core ML** face-embedding model producing fixed-length embeddings; match via cosine similarity against enrolled embeddings with a tunable threshold.
- Everything runs on-device, leveraging the Neural Engine where available. No Python, no third-party native deps, no network.

## Consequences

- No recurring inference cost; nothing leaves the device → satisfies the privacy requirement directly.
- First-party frameworks are well-supported, signable, and power-efficient.
- We must **select and bundle a Core ML embedding model** and tune the match threshold on real data (ND-021, ND-024).
- Accuracy under hard conditions (lighting, glasses, angles) needs validation (EC-04, EC-05).

## Alternatives considered

- **Python (dlib / face_recognition):** proven, but a Python sidecar is heavier to bundle, codesign, and notarize on macOS, and adds a runtime dependency. Rejected.
- **Cloud face APIs:** violate the local-only / no-token requirement outright. Rejected.
