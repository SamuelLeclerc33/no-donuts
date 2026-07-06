# Face-recognition Core ML model (ND-021 / ADR-0014)

This directory holds the **face-identity embedding model** used by
`CoreMLFaceEmbedder` (`Sources/NoDonutsCore/Recognition/CoreMLFaceEmbedder.swift`).

## The model

- **Architecture:** FaceNet — `InceptionResnetV1` from
  [`facenet-pytorch`](https://github.com/timesler/facenet-pytorch), pretrained on
  **VGGFace2**.
- **Input:** an image, `160×160` RGB. FaceNet's preprocessing (`(x - 127.5) / 128`)
  is **folded into the Core ML model** at conversion time
  (`ct.ImageType(scale: 1/128, bias: -127.5/128)`), so the embedder feeds raw 0–255
  RGB pixels and the model normalizes internally.
- **Output:** a **512-dimensional** float multi-array (an L2-normalized face
  embedding). The output feature is named `var_2167` by the converter, but
  `CoreMLFaceEmbedder` auto-discovers the first multi-array output, so the name is
  irrelevant.
- **File:** `FaceNetVGGFace2.mlpackage` (~45 MB, Core ML `mlprogram`).

### Alignment caveat

At runtime the embedder feeds Apple **Vision** face-*rectangle* crops, not MTCNN
5-point aligned faces (which FaceNet normally expects). This is an accepted v1
approximation — it costs some accuracy and is part of why the match threshold must
still be **re-tuned on device** before the model is trusted for distribution
(`FaceEmbeddingModelDescriptor.thresholdIsTuned == false`).

## License note

- `facenet-pytorch` is **MIT-licensed** (the conversion code + architecture).
- The **VGGFace2 pretrained weights** are provided for **research use**. This is fine
  for **internal** use per **ADR-0014**. A permissively-licensed model for public
  distribution is a deferred follow-up (see ND-021 / the backlog).

## Why the binary is NOT in git

The 45 MB `.mlpackage` (and any compiled `.mlmodelc`) is **git-ignored**
(`.gitignore`) to avoid permanent history bloat and for distribution hygiene on a
privacy-focused app. Instead we commit the **conversion script** so a fresh clone can
**reproduce the model deterministically** without a blob in history.

## Regenerating the model

Requires Python **3.12** (matching what produced the committed model) and network
access for the one-time weight download. From this directory:

```sh
python3.12 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install torch facenet-pytorch coremltools
.venv/bin/python convert_facenet.py
```

This writes `FaceNetVGGFace2.mlpackage` **into this directory**
(`Resources/Models/`), which is exactly where the build expects it.

> The very first run downloads the VGGFace2 weights (`InceptionResnetV1`) into a
> local torch cache. The conversion itself is deterministic.

## How the build finds it

`scripts/make-app.sh` looks for `Resources/Models/FaceNetVGGFace2.mlpackage`. If
present, it compiles it to `FaceNetVGGFace2.mlmodelc` with
`xcrun coremlcompiler compile <pkg> <dest>` and copies the compiled `.mlmodelc` into
the built app bundle's `Contents/Resources/`, so
`Bundle.main.url(forResource: "FaceNetVGGFace2", withExtension: "mlmodelc")` resolves
at runtime and `CoreMLFaceEmbedder` loads it.

If the package is **absent** — or `coremlcompiler` is unavailable (it ships with
**full Xcode**, not Command Line Tools) — the script logs a clear warning and
continues; the app then falls back to the Vision feature-print embedder
(`VisionFeaturePrintEmbedder`) and still runs. Compiling the model into a shippable
bundle therefore currently needs full Xcode installed (a wrinkle vs the CLT-only
ADR-0008 local-dev path).
