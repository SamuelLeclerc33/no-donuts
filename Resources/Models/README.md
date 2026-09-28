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
privacy-focused app. Instead we commit what is needed to rebuild it and to check it
(ND-087):

- `convert_facenet.py`, the conversion script;
- `requirements.txt`, the **pinned** Python dependencies;
- `FaceNetVGGFace2.sha256`, the SHA-256 of the compiled `FaceNetVGGFace2.mlmodelc`
  that ships in the app.

## Integrity check (ND-087)

`scripts/model-hash.sh` hashes a compiled model directory deterministically: the
SHA-256 of each file, listed with its relative path in byte order, then hashed again.
The result ignores timestamps and permissions but changes if any file is added,
removed, renamed or edited.

The recorded value (last line of `FaceNetVGGFace2.sha256`) is:

```
ca7038a7bd072ebf56d1bb9d11e6a5a086953fedf7eb48db46a9dac4e4710d5d
```

`scripts/make-app.sh` checks it before bundling the model:

- **dev mode** (default): a mismatch or a missing model prints a loud warning; the build
  goes on (a missing model means the app falls back to the Vision embedder).
- **release mode** (`--release`, ND-104): a missing model, a missing hash file, a
  mismatch, or an `.mlpackage`-only checkout **fails the build**.

At load time `CoreMLFaceEmbedder` also checks that the model declares exactly one
multi-array output of `descriptor.outputDimension` elements (512). If not, it refuses the
model and the app falls back, which shows up as the identity-off state (ND-073).

**If you regenerate the model on purpose**, the hash will change. Treat that as a new
model: bump the descriptor `version` in `FaceEmbeddingModel.swift` (so stored
enrollments are re-enrolled instead of compared across models), then record the new
hash:

```sh
scripts/model-hash.sh > Resources/Models/FaceNetVGGFace2.sha256
```

(and restore the comment header). Recompiling the same `.mlpackage` on another macOS
release may also change the hash, because the compiled model records the `coremlc`
version (`3520.5.1` for the recorded one).

## Regenerating the model

Requires Python **3.12** (matching what produced the committed model) and network
access for the package install and the one-time weight download. From this directory:

```sh
python3.12 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
.venv/bin/python convert_facenet.py
```

`requirements.txt` pins `torch 2.2.2`, `torchvision 0.17.2`, `facenet-pytorch 2.6.0`,
`coremltools 9.0`, `numpy 1.26.4` and `pillow 10.2.0`. torch and coremltools are the
versions written into the model's own metadata; the rest match the wheels cached on the
day of the conversion. See the file header for details.

This writes `FaceNetVGGFace2.mlpackage` **into this directory**
(`Resources/Models/`), which is exactly where the build expects it.

> The very first run downloads the VGGFace2 weights (`InceptionResnetV1`) into the
> local torch cache (`~/.cache/torch/checkpoints/20180402-114759-vggface2.pt`). The
> file used for the recorded model has SHA-256
> `281cebca8662831adb987a874bdcb36e73f5b1c6dc5ee5878f305e985625d99b`; check yours with
> `shasum -a 256` before converting.
>
> The conversion is **expected** to be reproducible with the pinned versions, but that
> has not been proven by a clean-room rebuild. The recorded SHA-256 is the check: if a
> rebuild doesn't match, don't ship it under the same descriptor version.

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
   coremltools as above) → hash-checked against `FaceNetVGGFace2.sha256`, then
   `cp -R` into the bundle. This is the **primary, Xcode-free
   path** and the normal case on this repo.
2. Else **`Resources/Models/FaceNetVGGFace2.mlpackage`** *and* an available
   `xcrun coremlcompiler` (full Xcode only) → compile it on the fly (fallback for
   full-Xcode machines; dev mode only, since the result can't be hash-checked).
3. Else → a clear warning; the app falls back to the Vision feature-print embedder
   (`VisionFeaturePrintEmbedder`) and still runs. With `--release` this is an error.

Bundling the FaceNet model therefore needs **either** a pre-compiled `.mlmodelc`
(via coremltools — **no Xcode**) **or** full Xcode's `coremlcompiler`. The earlier
"needs full Xcode" wrinkle is resolved by the coremltools compile step above, which
keeps the whole flow on the CLT-only ADR-0008 local-dev path.
