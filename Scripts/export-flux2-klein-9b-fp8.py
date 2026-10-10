#!/usr/bin/env python3
"""Export BFL's FLUX.2 Klein 9B FP8 transformer as Core AI components.

This is an offline, experimental denoiser export. It produces 34 .aimodel
components at a fixed image-token layout (1024 x 1024 by default).
Pixeltje Pipeline executes these components after the encoder and VAE have
been assembled into one model package directory.
The Qwen3-8B text encoder and FLUX.2 VAE are not included.

Use the Python environment from Apple's pinned coreai-models checkout. Each
component runs in a fresh process to bound peak conversion memory on 24 GB Macs.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import subprocess
import sys
from pathlib import Path


EXPECTED_SOURCE_SHA256 = "865ba09f5b4c3cbd3468a4bd3acb9fcb2f8740c54317482f0bcd4ed1d3655cee"
DOUBLE_BLOCKS = 8
SINGLE_BLOCKS = 24
TEXT_TOKENS = 512
HIDDEN_DIM = 4096
HEAD_DIM = 128


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path, help="BFL flux-2-klein-9b-fp8.safetensors")
    parser.add_argument("output", type=Path, help="new directory for the 34 Core AI packages")
    parser.add_argument("--image-size", type=int, choices=(512, 1024), default=1024,
                        help="fixed square output size (default: 1024)")
    parser.add_argument("--adapter", type=Path,
                        help="optional Diffusers-format DoRA .safetensors to fuse offline")
    parser.add_argument("--adapter-strength", type=float, default=1.0,
                        help="DoRA strength during fusion (default: 1.0)")
    parser.add_argument("--component", choices=("head", "double", "single", "tail"), help=argparse.SUPPRESS)
    parser.add_argument("--index", type=int, default=0, help=argparse.SUPPRESS)
    return parser.parse_args()


def source_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_adapter(adapter: Path) -> None:
    """Reject partial or unrelated adapters before creating an export directory."""
    from safetensors import safe_open

    with safe_open(adapter, framework="pt", device="cpu") as weights:
        keys = set(weights.keys())
    targets = {name.removesuffix(".lora_down.weight") for name in keys
               if name.endswith(".lora_down.weight")}
    expected: set[str] = set()
    for index in range(DOUBLE_BLOCKS):
        prefix = f"transformer.transformer_blocks.{index}."
        matched = {name for name in targets if name.startswith(prefix)}
        if len(matched) != 12:
            raise ValueError(f"expected 12 DoRA targets for double block {index}")
        expected.update(matched)
    for index in range(SINGLE_BLOCKS):
        prefix = f"transformer.single_transformer_blocks.{index}."
        matched = {name for name in targets if name.startswith(prefix)}
        if len(matched) != 2:
            raise ValueError(f"expected 2 DoRA targets for single block {index}")
        expected.update(matched)
    if targets != expected:
        raise ValueError("adapter contains targets outside the Klein 9B blocks")
    expected_keys = {target + suffix for target in targets for suffix in
                     (".alpha", ".dora_scale", ".lora_down.weight", ".lora_up.weight")}
    if keys != expected_keys:
        raise ValueError("adapter must have exactly the four DoRA tensors per target")


def component_filename(kind: str, index: int = 0) -> str:
    if kind == "head":
        return "Head.aimodel"
    if kind == "tail":
        return "Tail.aimodel"
    return f"{kind.title()}Block{index:02d}.aimodel"


def fuse_dora_block(state: dict, adapter: Path, target_prefix: str, strength: float) -> int:
    """Fuse the adapter's input-axis DoRA magnitudes into one Diffusers block."""
    import torch
    from safetensors import safe_open

    adapter_prefix = "transformer." + target_prefix
    fused = 0
    with safe_open(adapter, framework="pt", device="cpu") as weights:
        targets = sorted(
            name.removeprefix(adapter_prefix).removesuffix(".lora_down.weight")
            for name in weights.keys()
            if name.startswith(adapter_prefix) and name.endswith(".lora_down.weight")
        )
        expected = 12 if target_prefix.startswith("transformer_blocks.") else 2
        if len(targets) != expected:
            raise ValueError(
                f"adapter has {len(targets)} targets for {target_prefix}; expected {expected}"
            )
        for target in targets:
            name = adapter_prefix + target
            weight_name = target + ".weight"
            if weight_name not in state:
                raise ValueError(f"adapter target {name} has no transformer weight")
            down = weights.get_tensor(name + ".lora_down.weight").float()
            up = weights.get_tensor(name + ".lora_up.weight").float()
            magnitude = weights.get_tensor(name + ".dora_scale").float()
            alpha = float(weights.get_tensor(name + ".alpha"))
            original = state[weight_name].float()
            if down.ndim != 2 or up.ndim != 2 or up.shape[1] != down.shape[0]:
                raise ValueError(f"invalid LoRA rank for {name}")
            if (up.shape[0], down.shape[1]) != tuple(original.shape):
                raise ValueError(f"LoRA dimensions do not match {weight_name}")
            if tuple(magnitude.shape) != (1, original.shape[1]):
                raise ValueError(f"expected input-axis DoRA magnitude for {name}")
            updated = original + (up @ down) * (alpha / down.shape[0])
            updated *= magnitude / updated.norm(dim=0, keepdim=True).clamp_min(1e-12)
            merged = original + strength * (updated - original)
            if not torch.isfinite(merged).all():
                raise ValueError(f"non-finite DoRA result for {name}")
            state[weight_name] = merged.to(state[weight_name].dtype)
            fused += 1
    return fused


def export_component(checkpoint: Path, output: Path, kind: str, index: int, image_size: int,
                     adapter: Path | None, adapter_strength: float) -> None:
    import torch
    from coreai_models.diffusion.gpu import export_stateless
    from coreai_opt.coreai_utils import CompressionGranularity, DType, quantize_weights
    from diffusers.loaders.single_file_utils import convert_flux2_transformer_checkpoint_to_diffusers
    from diffusers.models.transformers.transformer_flux2 import (
        Flux2SingleTransformerBlock,
        Flux2Transformer2DModel,
        Flux2TransformerBlock,
    )
    from safetensors import safe_open

    image_tokens = (image_size // 16) ** 2

    class DoubleBlock(torch.nn.Module):
        def __init__(self, block: torch.nn.Module) -> None:
            super().__init__()
            self.block = block

        def forward(self, image, text, image_mod, text_mod, cos, sin):
            return self.block(image, text, image_mod, text_mod, image_rotary_emb=(cos, sin))

    class SingleBlock(torch.nn.Module):
        def __init__(self, block: torch.nn.Module) -> None:
            super().__init__()
            self.block = block

        def forward(self, image, text, image_mod, text_mod, cos, sin):
            # Keep the same six-port ABI as DoubleBlock; text_mod is unused here.
            return self.block(
                image, text, image_mod, image_rotary_emb=(cos, sin),
                split_hidden_states=True, text_seq_len=text.shape[1],
            )

    class Head(torch.nn.Module):
        def __init__(self, model: torch.nn.Module) -> None:
            super().__init__()
            self.model = model

        def forward(self, image, text, timestep, image_ids, text_ids):
            temb = self.model.time_guidance_embed(timestep.to(image.dtype) * 1000, None)
            image_mod = self.model.double_stream_modulation_img(temb).unsqueeze(1)
            text_mod = self.model.double_stream_modulation_txt(temb).unsqueeze(1)
            single_mod = self.model.single_stream_modulation(temb).unsqueeze(1)
            image = self.model.x_embedder(image)
            text = self.model.context_embedder(text)
            image_cos, image_sin = self.model.pos_embed(image_ids)
            text_cos, text_sin = self.model.pos_embed(text_ids)
            cos = torch.cat((text_cos, image_cos), dim=0).to(image.dtype)
            sin = torch.cat((text_sin, image_sin), dim=0).to(image.dtype)
            return image, text, image_mod, text_mod, single_mod, temb, cos, sin

    class Tail(torch.nn.Module):
        def __init__(self, model: torch.nn.Module) -> None:
            super().__init__()
            self.model = model

        def forward(self, image, temb):
            return self.model.proj_out(self.model.norm_out(image, temb))

    is_block = kind in ("double", "single")
    prefix = f"{kind}_blocks.{index}." if is_block else ""
    source_state: dict[str, torch.Tensor] = {}
    with safe_open(checkpoint, framework="pt", device="cpu") as weights:
        for name in weights.keys():
            if is_block != name.startswith(("double_blocks.", "single_blocks.")):
                continue
            if is_block and not name.startswith(prefix):
                continue
            if name.endswith((".weight_scale", ".input_scale")):
                continue
            value = weights.get_tensor(name)
            if value.dtype == torch.float8_e4m3fn:
                scale = weights.get_tensor(name.removesuffix(".weight") + ".weight_scale")
                value = value.to(torch.float32) * scale
            source_state[name] = value.to(torch.float16)

    converted = convert_flux2_transformer_checkpoint_to_diffusers(source_state)
    del source_state
    if is_block:
        target_prefix = f"{'transformer_blocks' if kind == 'double' else 'single_transformer_blocks'}.{index}."
        state = {name.removeprefix(target_prefix): value for name, value in converted.items()}
        if adapter is not None:
            fused = fuse_dora_block(state, adapter, target_prefix, adapter_strength)
            print(f"fused {fused} DoRA targets into {kind} block {index}", flush=True)
        block_class = Flux2TransformerBlock if kind == "double" else Flux2SingleTransformerBlock
        with torch.device("meta"):
            block = block_class(HIDDEN_DIM, 32, HEAD_DIM, mlp_ratio=3.0, eps=1e-6, bias=False)
        block.load_state_dict(state, strict=True, assign=True)
        wrapper = DoubleBlock(block) if kind == "double" else SingleBlock(block)
        inputs = (
            torch.zeros(1, image_tokens, HIDDEN_DIM, dtype=torch.float16),
            torch.zeros(1, TEXT_TOKENS, HIDDEN_DIM, dtype=torch.float16),
            torch.zeros(1, 1, 24576 if kind == "double" else 12288, dtype=torch.float16),
            torch.zeros(1, 1, 24576 if kind == "double" else 12288, dtype=torch.float16),
            torch.ones(image_tokens + TEXT_TOKENS, HEAD_DIM, dtype=torch.float16),
            torch.zeros(image_tokens + TEXT_TOKENS, HEAD_DIM, dtype=torch.float16),
        )
        input_names = ("image", "text", "image_mod", "text_mod", "cos", "sin")
        output_names = ("text_out", "image_out")
    else:
        with torch.device("meta"):
            model = Flux2Transformer2DModel(
                in_channels=128, out_channels=128, num_layers=0, num_single_layers=0,
                attention_head_dim=HEAD_DIM, num_attention_heads=32,
                joint_attention_dim=12288, guidance_embeds=False,
                axes_dims_rope=(32, 32, 32, 32),
            )
        model.load_state_dict(converted, strict=True, assign=True)
        if kind == "head":
            wrapper = Head(model)
            inputs = (
                torch.zeros(1, image_tokens, 128, dtype=torch.float16),
                torch.zeros(1, TEXT_TOKENS, 12288, dtype=torch.float16),
                torch.tensor([0.5], dtype=torch.float16),
                torch.zeros(image_tokens, 4, dtype=torch.float32),
                torch.zeros(TEXT_TOKENS, 4, dtype=torch.float32),
            )
            input_names = ("image", "text", "timestep", "image_ids", "text_ids")
            output_names = ("image_out", "text_out", "image_mod", "text_mod", "single_mod", "temb", "cos", "sin")
        else:
            wrapper = Tail(model)
            inputs = (
                torch.zeros(1, image_tokens, HIDDEN_DIM, dtype=torch.float16),
                torch.zeros(1, HIDDEN_DIM, dtype=torch.float16),
            )
            input_names = ("image", "temb")
            output_names = ("output",)
    del converted
    gc.collect()

    program = export_stateless(wrapper, inputs, input_names, output_names)
    if is_block:
        # Source FP8 weights have per-tensor scales. Restore those scales before
        # conversion, then let Core AI encode the weights as native FP8 storage.
        program = quantize_weights(
            program, dtype=DType.FP8_E4M3FN,
            granularity=CompressionGranularity.PER_TENSOR,
            weight_num_threshold=32768, in_place=True,
        )
    # The publisher stores all head/tail weights as BF16. FP16 here retains a
    # small footprint and avoids a second quantization of those sensitive layers.
    program.save_asset(output)
    print(f"exported {output.name}", flush=True)


def main() -> None:
    args = parse_args()
    checkpoint = args.checkpoint.expanduser().resolve()
    output = args.output.expanduser().resolve()
    adapter = args.adapter.expanduser().resolve() if args.adapter else None
    if not 0.0 <= args.adapter_strength <= 2.0:
        raise SystemExit("adapter strength must be between 0 and 2")
    if args.component is not None:
        export_component(checkpoint, output / component_filename(args.component, args.index),
                         args.component, args.index, args.image_size, adapter, args.adapter_strength)
        return

    if not checkpoint.is_file() or checkpoint.suffix != ".safetensors":
        raise SystemExit("checkpoint must be an existing .safetensors file")
    if output.exists():
        raise SystemExit(f"output already exists: {output}")
    if adapter is not None and (not adapter.is_file() or adapter.suffix != ".safetensors"):
        raise SystemExit("adapter must be an existing .safetensors file")
    digest = source_hash(checkpoint)
    if digest != EXPECTED_SOURCE_SHA256:
        raise SystemExit(f"checkpoint SHA-256 {digest} does not match the reviewed BFL FP8 file")
    adapter_digest = source_hash(adapter) if adapter is not None else None
    if adapter is not None:
        validate_adapter(adapter)
    output.mkdir(parents=True)
    components = [("head", 0)]
    components += [("double", i) for i in range(DOUBLE_BLOCKS)]
    components += [("single", i) for i in range(SINGLE_BLOCKS)]
    components += [("tail", 0)]
    for ordinal, (kind, index) in enumerate(components, 1):
        print(f"[{ordinal}/{len(components)}] {component_filename(kind, index)}", flush=True)
        command = [sys.executable, str(Path(__file__).resolve()), str(checkpoint), str(output),
                   "--component", kind, "--index", str(index), "--image-size", str(args.image_size)]
        if adapter is not None:
            command += ["--adapter", str(adapter), "--adapter-strength", str(args.adapter_strength)]
        subprocess.run(command, check=True)

    manifest = {
        "format_version": 1,
        "status": "experimental-denoiser-only",
        "source_model": "black-forest-labs/FLUX.2-klein-9b-fp8",
        "source_sha256": digest,
        "adapter": ({"source_file": adapter.name, "sha256": adapter_digest,
                     "strength": args.adapter_strength, "format": "input-axis DoRA"}
                    if adapter is not None else None),
        "license": "FLUX Non-Commercial License",
        "image_tokens": (args.image_size // 16) ** 2,
        "text_tokens": TEXT_TOKENS,
        "image_size": args.image_size,
        "architecture": "FLUX.2 Klein 9B Distilled",
        "preferred_compute": "gpu",
        "storage": "FP8 E4M3FN blocks; FP16 head and tail",
        "components": [component_filename(kind, index) for kind, index in components],
        "missing_for_image_generation": [
            "Core AI Qwen3-8B text encoder",
            ("512px Core AI FLUX.2 VAE decoder (the installed decoder is 1024px)"
             if args.image_size == 512 else "link to the installed 1024px FLUX.2 VAE decoder"),
            "Pixeltje split-transformer runtime",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"export complete: {output}", flush=True)


if __name__ == "__main__":
    main()
