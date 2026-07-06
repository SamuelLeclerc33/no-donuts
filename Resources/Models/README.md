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

## Compiling to `.mlmodelc` (Xcode-free — the normal path)

The app bundles a **compiled** model directory (`.mlmodelc`), not the `.mlpackage`.
Compile it with **coremltools** (pure Python — **no Xcode required**), from this
directory in the same venv used above:

```sh
.venv/bin/python -c 'from coremltools.models.utils import compile_model; compile_model("FaceNetVGGFace2.mlpackage", "FaceNetVGGFace2.mlmodelc")'
```

This produces `FaceNetVGGFace2.mlmodelc` **into this directory** (`Resources/Models/`),
which is exactly where the build looks for it first. Both the `.mlpackage` and the
`.mlmodelc` are git-ignored blobs.

## How the build finds it

`scripts/make-app.sh` resolves the model in this order, and copies/compiles the
result into the built app bundle's `Contents/Resources/`, so
`Bundle.main.url(forResource: "FaceNetVGGFace2", withExtension: "mlmodelc")` resolves
at runtime and `CoreMLFaceEmbedder` loads it:

1. **Pre-compiled `Resources/Models/FaceNetVGGFace2.mlmodelc`** (produced by
   coremltools as above) → `cp -R` into the bundle. This is the **primary, Xcode-free
   path** and the normal case on this repo.
2. Else **`Resources/Models/FaceNetVGGFace2.mlpackage`** *and* an available
   `xcrun coremlcompiler` (full Xcode only) → compile it on the fly (fallback for
   full-Xcode machines).
3. Else → a clear warning; the app falls back to the Vision feature-print embedder
   (`VisionFeaturePrintEmbedder`) and still runs.

Bundling the FaceNet model therefore needs **either** a pre-compiled `.mlmodelc`
(via coremltools — **no Xcode**) **or** full Xcode's `coremlcompiler`. The earlier
"needs full Xcode" wrinkle is resolved by the coremltools compile step above, which
keeps the whole flow on the CLT-only ADR-0008 local-dev path.
