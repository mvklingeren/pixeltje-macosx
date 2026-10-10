"""Export the Z-Image Turbo VAE encoder to an Apple Core AI package.

This offline developer tool loads original weights directly from the publisher.
It is not an application dependency. Exports are fixed-resolution by default;
``--dynamic`` is an empirical Core AI compatibility spike covering rectangular
inputs from 512 through 2048 pixels in multiples of eight.
"""

import argparse
import hashlib
import json
from pathlib import Path

import torch
import torch.nn as nn
from coreai_models.export.macos import export_to_coreai


DTYPE = torch.float32
LATENT_SCALING = 0.3611
LATENT_SHIFT = 0.1159
SOURCE_MODEL = "Tongyi-MAI/Z-Image-Turbo"
SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"


class VAEEncoderWrapper(nn.Module):
    """Select the posterior mode and apply Z-Image's latent convention."""

    def __init__(self, vae):
        super().__init__()
        self.encoder = vae.encoder
        self.quant_conv = vae.quant_conv

    def forward(self, image):
        moments = self.encoder(image)
        if self.quant_conv is not None:
            moments = self.quant_conv(moments)
        mean, _log_variance = torch.chunk(moments, 2, dim=1)
        return (mean - LATENT_SHIFT) * LATENT_SCALING


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", type=int, help="square shorthand for --width/--height")
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=1024)
    parser.add_argument(
        "--dynamic",
        action="store_true",
        help="export independent dynamic height/width axes from 512 through 2048",
    )
    parser.add_argument(
        "--source",
        default=SOURCE_MODEL,
        help="publisher model id or a local snapshot directory",
    )
    parser.add_argument("--revision", default=SOURCE_REVISION)
    parser.add_argument("--local-files-only", action="store_true")
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    if args.size is not None:
        args.width = args.size
        args.height = args.size
    for name, value in (("width", args.width), ("height", args.height)):
        if not 512 <= value <= 2048 or value % 16:
            parser.error(f"--{name} must be a multiple of 16 from 512 through 2048")

    from diffusers import AutoencoderKL
    import coreai.runtime as runtime

    vae = AutoencoderKL.from_pretrained(
        args.source,
        subfolder="vae",
        revision=args.revision if args.source == SOURCE_MODEL else None,
        local_files_only=args.local_files_only,
        torch_dtype=DTYPE,
    ).eval()
    wrapper = VAEEncoderWrapper(vae).eval()
    reference_image = torch.zeros(1, 3, args.height, args.width, dtype=DTYPE)
    reference = {"image": reference_image}
    dynamic_shapes = {"image": None}
    if args.dynamic:
        from torch.export import Dim

        latent_height = Dim("latent_height", min=64, max=256)
        latent_width = Dim("latent_width", min=64, max=256)
        dynamic_shapes = {
            "image": {2: 8 * latent_height, 3: 8 * latent_width}
        }

    with torch.no_grad():
        output = wrapper(reference_image)
    expected_shape = (1, 16, args.height // 8, args.width // 8)
    if tuple(output.shape) != expected_shape or not torch.isfinite(output).all():
        raise RuntimeError(
            f"unexpected reference output {tuple(output.shape)}; expected {expected_shape}"
        )

    program = export_to_coreai(
        wrapper,
        reference,
        dynamic_shapes=dynamic_shapes,
        input_names=("image",),
        output_names=("z",),
    )
    program.optimize()

    if args.dynamic:
        resolution = "dynamic_512-2048"
    elif args.width == args.height:
        resolution = str(args.width)
    else:
        resolution = f"{args.width}x{args.height}"
    name = f"zimage_vae_encoder_{resolution}_fp32"
    output = Path(args.out_dir) / f"{name}.aimodel"
    if output.exists():
        raise FileExistsError(f"Refusing to replace existing output: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    program.save_asset(output, runtime.AIModelAssetMetadata())
    mlir = output / "main.mlirb"
    provenance = {
        "schemaVersion": 1,
        "component": "vaeEncoder",
        "source": args.source,
        "sourceRevision": args.revision if args.source == SOURCE_MODEL else None,
        "sourceVAEWeightSHA256": (
            "f5b59a26851551b67ae1fe58d32e76486e1e812def4696a4bea97f16604d40a3"
            if args.source == SOURCE_MODEL
            else None
        ),
        "precision": "fp32",
        "latentScaling": LATENT_SCALING,
        "latentShift": LATENT_SHIFT,
        "dynamic": args.dynamic,
        "referenceWidth": args.width,
        "referenceHeight": args.height,
        "mainMLIRBSHA256": hashlib.sha256(mlir.read_bytes()).hexdigest(),
    }
    output.with_suffix(".provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    )
    print(f"Saved {output}")


if __name__ == "__main__":
    main()
