import torch
import coremltools as ct
from facenet_pytorch import InceptionResnetV1

print("loading InceptionResnetV1 (vggface2) — downloads weights on first run…")
model = InceptionResnetV1(pretrained='vggface2').eval()

print("tracing…")
example = torch.rand(1, 3, 160, 160)
with torch.no_grad():
    traced = torch.jit.trace(model, example)

print("converting to Core ML (mlprogram)…")
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="image",
        shape=(1, 3, 160, 160),
        scale=1.0 / 128.0,
        bias=[-127.5 / 128.0, -127.5 / 128.0, -127.5 / 128.0],
        color_layout=ct.colorlayout.RGB,
    )],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS12,
)

mlmodel.short_description = "FaceNet InceptionResnetV1 (VGGFace2) — 512-d face embedding. ND-021 / ADR-0014."
out = "FaceNetVGGFace2.mlpackage"
mlmodel.save(out)
print("saved", out)

# Report the resolved input/output feature names + shapes.
spec = mlmodel.get_spec()
print("=== inputs ===")
for i in spec.description.input:
    print(" ", i.name, i.type.WhichOneof("Type"))
print("=== outputs ===")
for o in spec.description.output:
    print(" ", o.name, o.type.WhichOneof("Type"))
