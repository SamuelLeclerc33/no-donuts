# ADR-0014 — Core ML face-recognition embedding behind a model-agnostic descriptor

- Status: Accepted (amends [ADR-0012](0012-local-identity-featureprint.md)). **Phase 2 landed 2026-08-24** — the Core ML embedder is now the shipping default; ADR-0012's Vision embedder is the fallback. Threshold still un-tuned (see *Phase 2 outcome*).
- Date: 2026-07-06 (amended 2026-08-24)
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

## Phase 2 outcome (2026-08-24)

Phase 2 is **delivered except the tuned threshold**, which is deliberately left open.

- **Bundled + active.** The converted FaceNet `.mlmodelc` ships in the app bundle and `CoreMLFaceEmbedder` is the selected embedder at launch: `active face embedder = CoreMLFaceEmbedder (facenet-vggface2-v1, 512-d, tuned=no)`. The full-Xcode caveat recorded during Phase 2 is **gone** — `scripts/make-app.sh` prefers a pre-compiled `.mlmodelc` produced by coremltools, so bundling works on the Command Line Tools baseline (ADR-0008).
- **Forced re-enrollment observed working.** Enrollments from the Vision era do not carry `facenet-vggface2-v1`, so identity falls back to presence-only until the user re-enrolls. No cross-model comparison occurred.
- **Genuine distribution measured** (1008 live ticks, one enrolled user): mean 0.830, median 0.877, p5 0.662, p1 0.525, min 0.056, with 6 samples below 0.5. The bulk sits ~0.88–0.94, comfortably clear of the provisional 0.5.

**The threshold stays un-tuned (`thresholdIsTuned = false`), by decision.** Live per-tick logging can only ever produce GENUINE scores; it structurally cannot produce impostor scores, which require other people's faces on cue. Genuine-only data bounds the false-**reject** rate and carries no information about where false-**accept** begins, so it cannot justify a threshold — and `thresholdIsTuned = true` is a claim that the EC-03 look-alike margin was measured. Setting it on half the evidence would put a false assurance into a security-relevant descriptor.

To unblock that measurement, Phase 2 adds **`FaceScore`** (`swift run FaceScore`), an offline harness that scores still images through the *real* `CoreMLFaceEmbedder` — same detection, crop, resize, and `cosineSimilarity` — so an impostor set becomes a folder of photos rather than a scheduling problem. It reports genuine vs impostor distributions, an FRR/FAR sweep, and a recommendation that **refuses to endorse a threshold unless the two classes separate cleanly**. Its statistics and that refusal live in `NoDonutsCore/Recognition/ThresholdAnalysis.swift` and are EngineCheck-covered (70/70), because the arithmetic under a shipped threshold is itself security-relevant. Tuning proper is **ND-056**.

A second gap opened by this phase is tracked separately: the anti-spoof texture score is not computed on the Core ML path, so the ND-041 gate never trips there (**ND-072**, EC-12).

## Amendment (2026-09-24): identity-off is loud, never silent (ND-073)

The forced re-enrollment above falls back to **presence-only** (any face = present). Until now that fallback was silent: a `log.notice` while the menu still said "enrolled / watching for you". It triggers whenever the stored version differs from the active embedder, including when the Core ML model is missing and the app runs on the Vision fallback (fresh clone, CLT build without the model, a deleted `.mlmodelc` in an ad-hoc bundle).

**Decision:** keep presence-only on a mismatch, with no lockout loop and no way to get stuck locked out, but surface it loudly:

- `IdentityRecognizer.lastIdentityStatus` publishes `IdentityStatus` (`.notEnrolled` / `.active` / `.off(.modelMismatch | .enrollmentMissing)` / `.unknown`), derived from the existing per-tick store read. Recognition results are unchanged.
- A **non-secret marker** in UserDefaults (`enrollmentMarkerModelVersion`, a model version string only) records "enrolled under model X". It is set on a successful enroll, cleared on an in-app Reset, and backfilled at launch for enrollments that predate it. If the store says not-enrolled while the marker is set, the status is `.off(.enrollmentMissing)`, so a Keychain item deleted outside the app is no longer indistinguishable from "never enrolled". The marker is tamperable by design; it raises the bar, and ND-077 covers tamper visibility.
- The app shows it everywhere: the header reads "⚠️ identity off: re-enroll needed", the present glyph becomes an orange `person.fill.questionmark`, the menu item reads "Re-enroll my face (required)…", a local notification (`nd.identityOff`) repeats every 5 min, and diagnostics carry an Identity line.
- `EnrollmentStore` caches its first definitive read for the process lifetime. An external deletion mid-session therefore does not weaken the running app (it keeps matching the cached vectors) and is flagged at the next launch.

## Alternatives considered

- **Keep tuning the Vision feature print (ADR-0012 only):** cannot fix EC-03 — it encodes image, not identity, similarity. Rejected as the durable fix (kept only as the fallback embedder).
- **Bundle the model without a descriptor/versioning:** would silently cross-compare old Vision vectors against a new model's space on the first run after a swap → garbage matches. Rejected; versioning is mandatory.
- **Download/convert the model at build or first run:** violates the no-network requirement and isn't possible in the build environment. Rejected — conversion is a manual, local, developer step.
- **Proper MTCNN 5-point alignment before embedding:** more accurate, but adds another model + pipeline stage. Deferred; Vision-rectangle crops are the accepted v1 input, re-tuned accordingly.
