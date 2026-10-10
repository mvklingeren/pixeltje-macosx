#!/usr/bin/env python3
"""Export the publisher's SDXS-512-DreamShaper text-to-image components to Core AI.

Run with ~/coreai-models/.venv/bin/python. The source snapshot is pinned to a
reviewed Hugging Face commit and the output is a linkable package, not an app
runtime dependency on PyTorch or safetensors. Each component is converted in a
separate process to keep peak memory bounded on a 24 GB Mac.

This exports only the one-step, guidance-free text-to-image route. It does not
claim that Apple's StableDiffusionPipeline can execute SDXS: that runtime uses
a different scheduler and a two-image classifier-free-guidance UNet signature.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path


MODEL_ID = "IDKiro/sdxs-512-dreamshaper"
REVISION = "76f720262bb051da75666b22c902a78c8e16c763"
ASSETS = {
    "text_encoder": "TextEncoder.aimodel",
    "unet": "Unet.aimodel",
    "vae_decoder": "VAEDecoder.aimodel",
}
SOURCE_FILES = (
    "model_index.json",
    "scheduler/scheduler_config.json",
    "text_encoder/config.json",
    "text_encoder/model.safetensors",
    "tokenizer/*",
    "unet/config.json",
    "unet/diffusion_pytorch_model.safetensors",
    "vae/config.json",
    "vae/diffusion_pytorch_model.safetensors",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path.home() / "coreai-models"
    parser.add_argument(
        "--source", type=Path, default=root / "checkpoints/SDXS-512-DreamShaper",
        help="pinned publisher snapshot directory",
    )
    parser.add_argument(
        "--output", type=Path, default=root / "exports/SDXS-512-DreamShaper",
        help="new Core AI package directory",
    )
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--repair-tokenizer", action="store_true")
    parser.add_argument("--component", choices=tuple(ASSETS), help=argparse.SUPPRESS)
    return parser.parse_args()


def check_source(source: Path) -> tuple[dict, dict]:
    for name in SOURCE_FILES:
        if "*" not in name and not (source / name).is_file():
            raise ValueError(f"publisher snapshot is missing {name}")
    model = json.loads((source / "model_index.json").read_text())
    scheduler = json.loads((source / "scheduler/scheduler_config.json").read_text())
    unet = json.loads((source / "unet/config.json").read_text())
    vae = json.loads((source / "vae/config.json").read_text())
    if model.get("_class_name") != "StableDiffusionPipeline":
        raise ValueError("unexpected publisher pipeline")
    if model.get("vae", [None, None])[1] != "AutoencoderTiny":
        raise ValueError("expected the publisher's small VAE")
    if unet.get("sample_size") != 64 or unet.get("in_channels") != 4:
        raise ValueError("expected a 512-pixel, four-channel UNet")
    if unet.get("cross_attention_dim") != 768:
        raise ValueError("expected 768-wide CLIP conditioning")
    if vae.get("latent_channels") != 4 or vae.get("scaling_factor") != 1.0:
        raise ValueError("unexpected small-VAE latent scale")
    if scheduler.get("_class_name") != "EulerDiscreteScheduler":
        raise ValueError("expected the publisher's Euler scheduler")
    if scheduler.get("timestep_spacing") != "trailing":
        raise ValueError("expected trailing timestep spacing")
    if scheduler.get("prediction_type") != "epsilon":
        raise ValueError("expected epsilon prediction")
    return model, scheduler


def download(source: Path) -> None:
    from huggingface_hub import snapshot_download

    source.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id=MODEL_ID,
        revision=REVISION,
        allow_patterns=SOURCE_FILES,
        local_dir=source,
    )
    check_source(source)


def export_component(source: Path, staging: Path, name: str) -> None:
    import torch
    from coreai.runtime import AIModelAssetMetadata
    from coreai_models.diffusion.components import (
        TextEncoderWrapper,
        UNetWrapper,
        VAEDecoderWrapper,
    )
    from coreai_models.diffusion.gpu import export_stateless
    from diffusers import StableDiffusionPipeline

    pipe = StableDiffusionPipeline.from_pretrained(
        source, torch_dtype=torch.float16, safety_checker=None,
        feature_extractor=None, requires_safety_checker=False,
        local_files_only=True,
    )
    if name == "text_encoder":
        wrapper = TextEncoderWrapper(pipe.text_encoder)
        inputs = (torch.zeros((1, 77), dtype=torch.long),)
        input_names, output_names = ("input_ids",), ("last_hidden_state",)
    elif name == "unet":
        wrapper = UNetWrapper(pipe.unet)
        inputs = (
            torch.zeros((1, 4, 64, 64), dtype=torch.float16),
            torch.full((1,), 999.0, dtype=torch.float16),
            torch.zeros((1, 77, 768), dtype=torch.float16),
        )
        input_names = ("sample", "timestep", "encoder_hidden_states")
        output_names = ("noise_pred",)
    else:
        wrapper = VAEDecoderWrapper(pipe.vae)
        inputs = (torch.zeros((1, 4, 64, 64), dtype=torch.float16),)
        input_names, output_names = ("z",), ("image",)

    program = export_stateless(wrapper, inputs, input_names, output_names)
    metadata = AIModelAssetMetadata()
    metadata.author = "IDKiro / SDXS authors"
    metadata.license = "OpenRAIL++"
    metadata.model_description = f"{MODEL_ID} at {REVISION}; {name} component"
    destination = staging / ASSETS[name]
    program.save_asset(destination, metadata)
    if not (destination / "main.mlirb").is_file():
        raise RuntimeError(f"Core AI export did not create {destination / 'main.mlirb'}")
    print(f"Exported {destination}", flush=True)


def write_manifest(staging: Path, scheduler: dict) -> None:
    manifest = {
        "metadata_version": "0.2",
        "kind": "diffusion",
        "name": staging.name.removesuffix(".partial"),
        "assets": ASSETS,
        "diffusion": {
            "type": "stable-diffusion",
            "prediction_type": "epsilon",
            "encoder_scale_factor": 1.0,
            "decoder_scale_factor": 1.0,
            "decoder_shift_factor": 0.0,
            "image_size": 512,
            "default_guidance_scale": 0.0,
            "default_steps": 1,
            "scheduler": {
                "type": "euler-discrete",
                "timestep_spacing": "trailing",
                "training_steps": scheduler["num_train_timesteps"],
                "beta_start": scheduler["beta_start"],
                "beta_end": scheduler["beta_end"],
                "beta_schedule": scheduler["beta_schedule"],
            },
        },
        "source": {
            "model_definition": "torch",
            "hf_model_id": MODEL_ID,
            "revision": REVISION,
            "license": "OpenRAIL++",
        },
        "compression": None,
        "compilation": {
            "date": datetime.now().astimezone().isoformat(),
            "targets": [],
        },
    }
    (staging / "metadata.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    args = arguments()
    source = args.source.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if args.component:
        check_source(source)
        export_component(source, output, args.component)
        return

    if args.repair_tokenizer:
        check_source(source)
        manifest = json.loads((output / "metadata.json").read_text())
        if manifest.get("source", {}).get("hf_model_id") != MODEL_ID or manifest.get(
            "source", {}
        ).get("revision") != REVISION:
            raise ValueError("refusing to repair an unrelated model package")
        shutil.copytree(source / "tokenizer", output / "tokenizer", dirs_exist_ok=True)
        print(f"Repaired tokenizer files in {output}")
        return

    if output.exists():
        raise SystemExit(f"completed output already exists: {output}")
    download(source)
    if args.download_only:
        print(f"Downloaded pinned source to {source}")
        return

    _, scheduler = check_source(source)
    staging = output.with_name(output.name + ".partial")
    staging.mkdir(parents=True, exist_ok=True)
    for name, asset in ASSETS.items():
        if (staging / asset / "main.mlirb").is_file():
            print(f"Reusing completed {asset}", flush=True)
            continue
        subprocess.run(
            [sys.executable, str(Path(__file__).resolve()),
             "--source", str(source), "--output", str(staging),
             "--component", name],
            check=True,
        )
    shutil.copytree(source / "tokenizer", staging / "tokenizer", dirs_exist_ok=True)
    write_manifest(staging, scheduler)
    for asset in ASSETS.values():
        if not (staging / asset / "main.mlirb").is_file():
            raise RuntimeError(f"incomplete Core AI asset: {asset}")
    staging.rename(output)
    print(f"Ready: {output}")


if __name__ == "__main__":
    main()
