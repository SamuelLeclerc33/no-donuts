# ADR-0012 — Local identity: Vision feature-print embedder + Keychain enrollment

- Status: Accepted (amends ADR-0002; amended by [ADR-0014](0014-coreml-face-embedding-model.md) — Core ML face model behind a model-agnostic descriptor, with the Vision feature print kept as the fallback default)
- Date: 2026-07-02
- Owner: cooper (+ krusty enrollment UX)

## Context

[ADR-0002](0002-face-recognition-engine.md) chose Apple Vision for detection and a **local Core ML face-embedding model** for identity. Detection shipped (ND-020, presence-only). Identity (ND-021–024, ND-034) needs an embedding to tell the enrolled user from a stranger (EC-03). But a Core ML face model (FaceNet/ArcFace-class) must be **sourced and bundled** — licensing, tens of MB in the bundle, conversion, and it can't be downloaded or tested in our build environment. That was blocking identity from shipping at all, while the product gap (a colleague sitting down keeps the Mac unlocked) is real.

## Decision

Ship identity now using an **Apple-native, no-model embedder**, behind a protocol so a Core ML model can replace it later without touching the rest of the pipeline.

- **Embedder:** `FaceEmbedding` protocol → `VisionFeaturePrintEmbedder`, which runs `VNDetectFaceRectanglesRequest`, crops to the largest face, and runs `VNGenerateImageFeaturePrintRequest`, extracting the `VNFeaturePrintObservation` into a `[Float]` vector. All on-device, no bundled model, no network.
- **Matching:** cosine similarity against the enrolled reference vectors; `max >= Config.matchThreshold` → enrolled user present, else `strangerOnly` (EC-03). Threshold defaults **lenient** (bias toward not locking the real user) and is tunable (ND-024/ND-040).
- **Not enrolled → presence-only fallback:** until the user enrolls, any detected face counts as present (today's behavior, non-breaking). Identity engages automatically once enrolled.
- **Enrollment store (ND-023):** the enrolled `[[Float]]` vectors are stored in the **macOS Keychain** (generic-password item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, never iCloud-synced). Embeddings only; **no raw images**; never transmitted.
- **Enrollment capture (ND-022):** quick auto-capture of ~10 frames over ~2–3s via the existing `CameraController`, keeping the reference embeddings with a face; enforcement is gated off during capture so it can't lock mid-enroll.

This **amends** ADR-0002: identity is a Vision feature print for v1.1, not (yet) a Core ML face model. The `FaceEmbedding` seam means adopting a Core ML model later is a drop-in — that swap is the real remaining scope of ND-021.

## Consequences

- Identity ships with zero external dependencies and stays 100% on-device — satisfies the privacy requirement directly.
- **Accuracy is lower than a dedicated face model.** `VNGenerateImageFeaturePrint` is a *general* image feature print, not face-optimized, so separation between people is weaker and sensitive to lighting/angle/crop. Mitigated by: multiple reference embeddings, a lenient threshold, and the existing 5-tick consensus + grace debounce (a blip won't lock you). Threshold **must be tuned on-device** (can't tune headless).
- A future Core ML model can raise accuracy behind the same protocol without touching enrollment, matching, storage, or policy.
- Keychain gives encrypted-at-rest storage for free; behavior under ad-hoc-signed local builds needs on-device verification.
- Orientation/crop of the front-camera buffer affects match quality — tracked with the existing recognition-orientation follow-up.

## Alternatives considered

- **Bundle a Core ML face model now (FaceNet/ArcFace):** best accuracy, but blocked on sourcing/licensing/size and untestable here. Deferred to the ND-021 swap behind the `FaceEmbedding` seam.
- **Landmark-geometry matching (Vision landmarks → distances/ratios):** no model, but brittle and easy to spoof; weaker than a learned feature print. Rejected.
- **Encrypted file + separate key** instead of the Keychain: more moving parts than a Keychain item that is already encrypted and access-controlled. Rejected for the MVP.
