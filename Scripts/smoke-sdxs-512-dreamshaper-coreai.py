#!/usr/bin/env python3
"""Run one SDXS-512-DreamShaper image through the exported Core AI components.

Use ~/coreai-models/.venv/bin/python. This is an opt-in model smoke check, not
a repository unit test or a substitute for the maintainer's visual inspection.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path

import numpy as np
import torch
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions
from diffusers import EulerDiscreteScheduler
from PIL import Image
from transformers import CLIPTokenizer


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path.home() / "coreai-models"
    parser.add_argument("--package", type=Path, default=root / "exports/SDXS-512-DreamShaper")
    parser.add_argument("--source", type=Path, default=root / "checkpoints/SDXS-512-DreamShaper")
    parser.add_argument("--output", type=Path, default=root / "outputs/SDXS-512-DreamShaper.png")
    parser.add_argument("--prompt", default="A small red sailboat on a quiet lake")
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


async def generate(args: argparse.Namespace) -> None:
    package = args.package.expanduser().resolve(strict=True)
    source = args.source.expanduser().resolve(strict=True)
    manifest = json.loads((package / "metadata.json").read_text())
    if manifest["source"]["revision"] != "76f720262bb051da75666b22c902a78c8e16c763":
        raise ValueError("unexpected SDXS source revision")
    assets = manifest["assets"]
    options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())

    async def invoke(asset: str, inputs: dict[str, NDArray]) -> dict[str, NDArray]:
        start = time.monotonic()
        model = await AIModel.load(package / assets[asset], options)
        function = model.load_function("main")
        result = await function(inputs)
        print(f"{asset}: {time.monotonic() - start:.3f} s", flush=True)
        return result

    tokenizer = CLIPTokenizer.from_pretrained(package / "tokenizer", local_files_only=True)
    tokens = tokenizer(
        args.prompt, max_length=77, padding="max_length", truncation=True,
        return_tensors="np",
    ).input_ids.astype(np.int32)
    text = (await invoke("text_encoder", {"input_ids": NDArray(tokens)}))[
        "last_hidden_state"
    ].numpy()
    if text.shape != (1, 77, 768) or not np.isfinite(text).all():
        raise RuntimeError(f"invalid text embedding: {text.shape}")

    scheduler = EulerDiscreteScheduler.from_pretrained(
        source, subfolder="scheduler", local_files_only=True
    )
    scheduler.set_timesteps(1)
    noise = torch.randn((1, 4, 64, 64), generator=torch.Generator().manual_seed(args.seed))
    latents = noise * scheduler.init_noise_sigma
    timestep = scheduler.timesteps[0]
    scaled = scheduler.scale_model_input(latents, timestep)
    prediction = (await invoke("unet", {
        "sample": NDArray(scaled.numpy().astype(np.float16)),
        "timestep": NDArray(np.array([float(timestep)], dtype=np.float16)),
        "encoder_hidden_states": NDArray(text.astype(np.float16)),
    }))["noise_pred"].numpy()
    if prediction.shape != (1, 4, 64, 64) or not np.isfinite(prediction).all():
        raise RuntimeError(f"invalid UNet output: {prediction.shape}")
    latents = scheduler.step(torch.from_numpy(prediction.astype(np.float32)), timestep, latents).prev_sample

    image = (await invoke("vae_decoder", {
        "z": NDArray(latents.numpy().astype(np.float16))
    }))["image"].numpy()
    if image.shape != (1, 3, 512, 512) or not np.isfinite(image).all():
        raise RuntimeError(f"invalid VAE output: {image.shape}")
    rgb = np.clip((image[0].transpose(1, 2, 0).astype(np.float32) + 1.0) / 2.0, 0, 1)
    output = args.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.uint8(np.round(rgb * 255)), mode="RGB").save(output)
    print(f"Ready: {output} ({rgb.shape[1]}x{rgb.shape[0]})", flush=True)


if __name__ == "__main__":
    asyncio.run(generate(arguments()))
