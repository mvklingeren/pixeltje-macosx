#!/usr/bin/env python3
"""Generate one experimental 1024px Klein 9B image outside Pixeltje.

This uses the split FP8 Core AI denoiser and text encoder with the installed
FLUX.2 VAE. It validates the full model chain before Pixeltje integration.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import runpy
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions
from PIL import Image


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--denoiser", type=Path, required=True)
    parser.add_argument("--vae", type=Path, required=True)
    parser.add_argument("--batch-norm", type=Path, required=True,
                        help="directory containing vae_bn_mean.npy and vae_bn_var.npy")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prompt", default="A red fox in a snowy forest, detailed photograph")
    parser.add_argument("--seed", type=int, default=47)
    parser.add_argument("--stage", choices=("encode", "denoise", "decode"), help=argparse.SUPPRESS)
    parser.add_argument("--state-dir", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--step-index", type=int, help=argparse.SUPPRESS)
    return parser.parse_args()


def schedule(steps: int = 4) -> np.ndarray:
    seq = 4096.0
    m200 = 0.00016927 * seq + 0.45666666
    m10 = 8.73809524e-05 * seq + 1.89833333
    a = (m200 - m10) / 190.0
    mu = a * steps + (m200 - 200.0 * a)
    raw = np.linspace(1.0, 1.0 / steps, steps, dtype=np.float32)
    exp_mu = np.exp(np.float32(mu))
    shifted = exp_mu / (exp_mu + (1.0 / raw - 1.0))
    return np.concatenate((shifted, np.zeros(1, dtype=np.float32)))


def run_driver(args: argparse.Namespace) -> None:
    denoiser = args.denoiser.expanduser().resolve()
    manifest = json.loads((denoiser / "manifest.json").read_text())
    if manifest.get("image_size") != 1024 or manifest.get("image_tokens") != 4096:
        raise ValueError("denoiser must use the fixed 1024px layout")

    grid = 64
    noise = np.random.default_rng(args.seed).standard_normal((1, 128, grid, grid),
                                                             dtype=np.float32)
    latent = noise.transpose(0, 2, 3, 1).reshape(1, 4096, 128)
    print("sigmas:", schedule(), flush=True)
    with tempfile.TemporaryDirectory(prefix="pixeltje-klein9b-") as temporary:
        state_dir = Path(temporary)
        np.save(state_dir / "latent.npy", latent)
        base = [sys.executable, str(Path(__file__).resolve()),
                "--encoder", str(args.encoder), "--denoiser", str(args.denoiser),
                "--vae", str(args.vae), "--batch-norm", str(args.batch_norm),
                "--output", str(args.output), "--prompt", args.prompt,
                "--seed", str(args.seed), "--state-dir", str(state_dir)]
        subprocess.run(base + ["--stage", "encode"], check=True)
        for step in range(4):
            subprocess.run(base + ["--stage", "denoise", "--step-index", str(step)],
                           check=True)
        subprocess.run(base + ["--stage", "decode"], check=True)


async def run_stage(args: argparse.Namespace) -> None:
    encoder = args.encoder.expanduser().resolve()
    denoiser = args.denoiser.expanduser().resolve()
    vae = args.vae.expanduser().resolve()
    batch_norm = args.batch_norm.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if args.state_dir is None:
        raise ValueError("stage requires --state-dir")
    state_dir = args.state_dir.expanduser().resolve()

    if args.stage == "encode":
        encoder_run = runpy.run_path(str(Path(__file__).with_name(
            "smoke-flux2-klein-9b-qwen3-fp8.py")))["run"]
        text = (await encoder_run(encoder, args.prompt)).astype(np.float16)
        np.save(state_dir / "text.npy", text)
        return

    options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())

    async def invoke(package: Path, name: str, inputs: dict[str, NDArray]) -> dict[str, NDArray]:
        start = time.monotonic()
        model = await AIModel.load(package / name, options)
        function = model.load_function("main")
        result = await function(inputs)
        print(f"{name}: {time.monotonic() - start:.2f}s", flush=True)
        del function, model
        gc.collect()
        return result

    grid = 64
    latent = np.load(state_dir / "latent.npy")
    if latent.shape != (1, 4096, 128) or not np.isfinite(latent).all():
        raise RuntimeError("invalid saved latent")

    if args.stage == "denoise":
        if args.step_index is None or not 0 <= args.step_index < 4:
            raise ValueError("denoise stage needs --step-index 0..3")
        step = args.step_index
        text = np.load(state_dir / "text.npy")
        if text.shape != (1, 512, 12288) or not np.isfinite(text).all():
            raise RuntimeError("invalid saved text embedding")
        image_ids = np.zeros((4096, 4), dtype=np.float32)
        image_ids[:, 1] = np.repeat(np.arange(grid), grid)
        image_ids[:, 2] = np.tile(np.arange(grid), grid)
        text_ids = np.zeros((512, 4), dtype=np.float32)
        text_ids[:, 3] = np.arange(512)
        sigmas = schedule()
        timestep = np.array([int(float(sigmas[step]) * 1000) / 1000], dtype=np.float16)
        head = await invoke(denoiser, "Head.aimodel", {
            "image": NDArray(latent.astype(np.float16)),
            "text": NDArray(text),
            "timestep": NDArray(timestep),
            "image_ids": NDArray(image_ids),
            "text_ids": NDArray(text_ids),
        })
        image_state = head["image_out"]
        text_state = head["text_out"]
        image_mod = head["image_mod"]
        text_mod = head["text_mod"]
        single_mod = head["single_mod"]
        temb = head["temb"]
        cos = head["cos"]
        sin = head["sin"]
        del head
        for kind, count in (("Double", 8), ("Single", 24)):
            for index in range(count):
                result = await invoke(denoiser, f"{kind}Block{index:02d}.aimodel", {
                    "image": image_state,
                    "text": text_state,
                    "image_mod": image_mod if kind == "Double" else single_mod,
                    "text_mod": text_mod if kind == "Double" else single_mod,
                    "cos": cos,
                    "sin": sin,
                })
                image_state = result["image_out"]
                text_state = result["text_out"]
                del result
        result = await invoke(denoiser, "Tail.aimodel", {
            "image": image_state,
            "temb": temb,
        })
        velocity = result["output"].numpy().astype(np.float32)
        if velocity.shape != latent.shape or not np.isfinite(velocity).all():
            raise RuntimeError(f"invalid denoiser output at step {step + 1}")
        latent = latent + (sigmas[step + 1] - sigmas[step]) * velocity
        if not np.isfinite(latent).all():
            raise RuntimeError(f"non-finite latent at step {step + 1}")
        np.save(state_dir / "latent.npy", latent)
        print(f"step {step + 1}/4: latent mean={latent.mean():.4f}, "
              f"std={latent.std():.4f}", flush=True)
        return

    if args.stage != "decode":
        raise ValueError(f"unknown stage: {args.stage}")
    spatial = latent.reshape(1, grid, grid, 128).transpose(0, 3, 1, 2)
    mean = np.load(batch_norm / "vae_bn_mean.npy").reshape(1, 128, 1, 1)
    variance = np.load(batch_norm / "vae_bn_var.npy").reshape(1, 128, 1, 1)
    spatial = spatial * np.sqrt(variance + 0.0001) + mean
    vae_latent = spatial.reshape(1, 32, 2, 2, grid, grid).transpose(
        0, 1, 4, 2, 5, 3).reshape(1, 32, 128, 128)
    result = await invoke(vae.parent, vae.name, {"z": NDArray(vae_latent.astype(np.float16))})
    pixels = result["image"].numpy()
    if pixels.shape != (1, 3, 1024, 1024) or not np.isfinite(pixels).all():
        raise RuntimeError("VAE returned invalid pixels")
    rgb = pixels[0].transpose(1, 2, 0).astype(np.float32)
    rgb = np.clip((rgb + 1.0) * 127.5, 0, 255).astype(np.uint8)
    output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb, mode="RGB").save(output)
    print(f"saved {output}", flush=True)


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.stage is None:
        run_driver(arguments)
    else:
        asyncio.run(run_stage(arguments))
