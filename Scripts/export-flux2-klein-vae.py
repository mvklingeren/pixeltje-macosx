#!/usr/bin/env python3
"""Export only the publisher's FLUX.2 Klein VAE decoder for 1024-pixel Core AI use.

Run with the Python environment from the pinned Apple coreai-models checkout.
The source directory contains vae/config.json and vae/diffusion_pytorch_model.safetensors
from black-forest-labs/FLUX.2-klein-4B. The result is a new directory with
VAEDecoder.aimodel and the two batch-normalization sidecars.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_VAE_SHA256 = "ca70d2202afe6415bdbcb8793ba8cd99fd159cfe6192381504d6c4d3036e0f04"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="FLUX.2-klein-4B snapshot directory")
    parser.add_argument("output", type=Path, help="new VAE export directory")
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    weights = source / "vae" / "diffusion_pytorch_model.safetensors"
    if not (source / "vae" / "config.json").is_file() or not weights.is_file():
        raise SystemExit("source must contain the 4B vae config and safetensors")
    if sha256(weights) != EXPECTED_VAE_SHA256:
        raise SystemExit("VAE weights differ from the reviewed publisher file")
    if output.exists():
        raise SystemExit(f"output already exists: {output}")

    import numpy as np
    import torch
    from coreai_models.diffusion.flux2 import Flux2VAEDecoderWrapper
    from coreai_models.diffusion.gpu import export_stateless
    from diffusers import AutoencoderKLFlux2

    vae = AutoencoderKLFlux2.from_pretrained(source / "vae", torch_dtype=torch.float16)
    if vae.config.latent_channels != 32:
        raise SystemExit("source VAE does not have the reviewed 32 latent channels")
    vae.eval()
    output.mkdir(parents=True)
    np.save(output / "vae_bn_mean.npy", vae.bn.running_mean.float().cpu().numpy())
    np.save(output / "vae_bn_var.npy", vae.bn.running_var.float().cpu().numpy())
    wrapper = Flux2VAEDecoderWrapper(vae)
    inputs = (torch.zeros((1, 32, 128, 128), dtype=torch.float16),)
    program = export_stateless(wrapper, inputs, ("z",), ("image",))
    program.save_asset(output / "VAEDecoder.aimodel")
    print(f"Exported {output}")


if __name__ == "__main__":
    main()
