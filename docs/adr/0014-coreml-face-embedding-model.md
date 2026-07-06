# ADR-0014 — Core ML face-recognition embedding behind a model-agnostic descriptor

- Status: Accepted (amends [ADR-0012](0012-local-identity-featureprint.md); ADR-0012 stays the shipping default until the model is bundled)
- Date: 2026-07-06
- Owner: cooper

## Context

[ADR-0012](0012-local-identity-featureprint.md) shipped identity v1.1 using Apple's `VNGenerateImageFeaturePrint` behind the `FaceEmbedding` protocol. That is a **general image feature print, not a face-identity embedding** — it encodes *image* similarity, so a look-alike colleague ("Marco") in similar framing/lighting can score close enough to the enrolled user to pass (EC-03 false-accept). No threshold tuning fully fixes this: the signal itself isn't identity.

The durable fix is a real face-recognition model. Constraints:

- **100% on-device, no network** (hard requirement) — the model must be bundled and run via Core ML.
- The build environment **cannot download or convert** a model, and no `.mlmodel`/`.mlpackage` is in the repo. So all code must compile, build, and pass EngineCheck **without any model file present**.
- License flexibility: we want to start with a known-good model for **internal use** now, and swap to a **permissively-licensed** model for distribution later with minimal code change.

## Decision

Adopt a **Core ML face-recognition embedding**, selected behind a **model-agnostic descriptor** so the model, its threshold, and its preprocessing travel together and a later swap is low-friction. This is delivered in two phases; **Phase 1 (this ADR) is the Swift seam + versioning + tests, model-file-independent.**

- **Model descriptor abstraction.** `FaceEmbeddingModelDescriptor` (pure `Sendable` value type) carries a stable `version` id/tag, `inputSize`, `outputDimension`, `defaultMatchThreshold`, and `thresholdIsTuned`. Every `FaceEmbedding` now exposes a `descriptor`. Matching, threshold, and preprocessing are **model-driven, not hardcoded**.
- **Internal-use model = FaceNet.** `facenet-pytorch` InceptionResnetV1 pretrained on **VGGFace2**: 160×160 RGB input, 512-dim L2-normalized output. Normalization `(x-127.5)/128` is **folded into the Core ML model** at conversion time (`ct.ImageType(scale=1/128, bias=-127.5/128)`), so the model takes an image input and emits a 512-float embedding. License is acceptable for internal use; a permissive/other model (e.g. ArcFace, also 512-dim) can be swapped in for distribution behind the same descriptor.
- **`CoreMLFaceEmbedder`** conforms to `FaceEmbedding`: Vision detects + crops the largest face, resizes to the descriptor's input size, feeds it as an image input, reads the float output, and **L2-normalizes defensively**. Its initializer is **failable**: if the compiled model resource is absent (the current repo state) it returns `nil` and logs — the app keeps running with `VisionFeaturePrintEmbedder` as the wired default. We do **not** switch the default embedder yet.
- **Preprocessing/alignment reality.** We feed Vision face-**rectangle** crops, not MTCNN 5-point aligned faces (what `facenet-pytorch` normally expects). Accepted for v1 as an accuracy compromise; part of why the threshold must be re-tuned on device.
- **Each model carries its own threshold + preprocessing.** Cosine scores are **not comparable across models**, so the threshold is a descriptor field. Vision keeps `0.6` (unchanged); FaceNet gets a **provisional, un-tuned `0.5`** (`thresholdIsTuned = false`), a starting guess to be tuned on device.
- **Embedding versioning + forced re-enrollment.** Stored enrollments record the model `version` that produced them (`EnrollmentStore` schema extended compatibly; legacy bare-array records decode to `version = nil`). On load, if the stored version ≠ the active embedder's `descriptor.version`, the recognizer treats the enrollment as **NOT for this model** → presence-only fallback → **forces re-enrollment**. We **never** cross-compare vectors from different embedding spaces (a stale compare could false-accept or false-reject). This is the correctness-critical part and is EngineCheck-covered.

## Consequences

- The seam and versioning are in place and tested **without** the model file: `swift build` + `swift run EngineCheck` pass (61/61, incl. 4 new ADR-0014 checks). The app is unchanged today (Vision embedder still wired).
- **The EC-03 guarantee is only STRUCTURALLY restored once the real model is bundled and its threshold re-tuned.** Until then, identity still uses the general feature print and a determined look-alike may pass. `thresholdIsTuned = false` keeps this honest in code and diagnostics.
- Swapping to a distribution model later is low-friction: add a descriptor + point `CoreMLFaceEmbedder` at the new resource; the version bump auto-forces a clean one-time re-enroll, so no cross-model vectors are ever compared.
- Storage stays Keychain, device-only, embeddings-only (ADR-0012 unchanged) — only the blob schema gained a version tag, with legacy fallback.
- **Phase-2 follow-ups (ND-021):** convert + bundle the FaceNet `.mlmodelc` (with gordon; sizing, codesign, ad-hoc build); switch the default embedder to Core ML with the graceful Vision fallback; capture FaceNet's real threshold vs the Marco false-accept and set a tuned `defaultMatchThreshold` (`thresholdIsTuned = true`); users re-enroll once (forced by the version bump). Distribution-model swap (permissive license) remains deferred (license TBD).

## Alternatives considered

- **Keep tuning the Vision feature print (ADR-0012 only):** cannot fix EC-03 — it encodes image, not identity, similarity. Rejected as the durable fix (kept only as the fallback embedder).
- **Bundle the model without a descriptor/versioning:** would silently cross-compare old Vision vectors against a new model's space on the first run after a swap → garbage matches. Rejected; versioning is mandatory.
- **Download/convert the model at build or first run:** violates the no-network requirement and isn't possible in the build environment. Rejected — conversion is a manual, local, developer step.
- **Proper MTCNN 5-point alignment before embedding:** more accurate, but adds another model + pipeline stage. Deferred; Vision-rectangle crops are the accepted v1 input, re-tuned accordingly.
