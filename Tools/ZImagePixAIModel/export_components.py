#!/usr/bin/env python3
"""Export independently verified Z-Image components to Core AI assets.

This is an offline developer tool. It imports PyTorch, Diffusers and Apple's
coreai-models package only in the external conversion environment. The Pixeltje
application never imports this module or any of those dependencies.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import platform
import resource
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Sequence

import torch
import torch.nn as nn

from pixaimodel import (
    ContractError,
    HERE,
    audit_git_checkout,
    guarded_resolve,
    lexical_path,
    load_json,
    outside_checkout,
    sha256_file,
    sha256_tree,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json


LATENT_SCALING = 0.3611
LATENT_SHIFT = 0.1159
SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"
DEBUG_METADATA_KEY = "pixeltjeProfiler"
DEBUG_METADATA_VERSION = "1.0.0"


def dtype_for_precision(precision: str) -> torch.dtype:
    try:
        return {
            "float16": torch.float16,
            "bfloat16": torch.bfloat16,
            "float32": torch.float32,
        }[precision]
    except KeyError as error:
        raise ContractError(f"unsupported precision: {precision}") from error


def default_precision(component: str) -> str:
    return {
        "prompt-encoder": "float16",
        "denoiser": "bfloat16",
        "vae-encoder": "float32",
        "vae-decoder": "float32",
    }[component]


def profiler_probe_metadata(precision: str) -> dict[str, Any]:
    dtype_for_precision(precision)
    return {
        "schemaVersion": DEBUG_METADATA_VERSION,
        "component": "denoiser",
        "variant": "tiny-probe",
        "probe": True,
        "converterMode": "debug",
        "precision": precision,
        "imageResolution": {"width": 512, "height": 512},
        "imageTokens": 1024,
        "promptBucket": 64,
        "promptWidth": 64,
    }


def system_record() -> dict[str, Any]:
    try:
        macos = subprocess.run(
            ["sw_vers", "-productVersion"], check=True, capture_output=True, text=True
        ).stdout.strip()
        build = subprocess.run(
            ["sw_vers", "-buildVersion"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        macos, build = platform.mac_ver()[0] or "unknown", "unknown"
    packages = {}
    for name in (
        "coreai-core",
        "coreai-torch",
        "diffusers",
        "numpy",
        "safetensors",
        "torch",
        "torchao",
        "transformers",
    ):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    return {
        "macOS": macos,
        "build": build,
        "machine": platform.machine(),
        "python": platform.python_version(),
        "packages": packages,
    }


class PromptEncoderWrapper(nn.Module):
    """Return the publisher pipeline's penultimate Qwen hidden state."""

    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        output = self.model(
            input_ids=input_ids.to(torch.int64),
            attention_mask=attention_mask,
            output_hidden_states=True,
            use_cache=False,
            return_dict=True,
        )
        return output.hidden_states[-2]


class VAEEncoderWrapper(nn.Module):
    """Return the deterministic posterior mode; latent affine is a host node."""

    def __init__(self, vae: nn.Module) -> None:
        super().__init__()
        self.encoder = vae.encoder
        self.quant_conv = vae.quant_conv

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        moments = self.encoder(image)
        if self.quant_conv is not None:
            moments = self.quant_conv(moments)
        mean, _log_variance = torch.chunk(moments, 2, dim=1)
        return mean


class VAEDecoderWrapper(nn.Module):
    """Decode already affine-adjusted latents; normalization is a host node."""

    def __init__(self, vae: nn.Module) -> None:
        super().__init__()
        self.vae = vae
        # This BSD-3-Clause helper is pinned by source-lock.json. It replaces
        # nearest-neighbor interpolation with an exactly equivalent repeat so
        # the graph remains on MPSGraph. Numerical parity is still mandatory.
        from coreai_models.diffusion.components import _patch_nearest_upsample

        _patch_nearest_upsample(self.vae.decoder)

    def forward(self, latent: torch.Tensor) -> torch.Tensor:
        return self.vae.decode(latent, return_dict=False)[0]


class DenoiserWrapper(nn.Module):
    """Core learned Z-Image denoiser over host-authored padded tokens and RoPE.

    The publisher model's public forward accepts Python lists, builds complex
    RoPE tensors, and specializes prompt length while exporting. The package
    contract instead keeps patchification, coordinate construction and prompt
    bucket planning as declarative host operations. This wrapper reuses the
    publisher modules and weights but presents a tensor-only, batch-one ABI.
    """

    def __init__(
        self,
        transformer: nn.Module,
        attention_accumulation: str = "model",
    ) -> None:
        super().__init__()
        if attention_accumulation not in {"model", "float32"}:
            raise ValueError("attention accumulation must be 'model' or 'float32'")
        self.transformer = transformer
        self.attention_accumulation = attention_accumulation

    def forward(
        self,
        image_tokens: torch.Tensor,
        image_padding_mask: torch.Tensor,
        prompt_embeddings: torch.Tensor,
        prompt_padding_mask: torch.Tensor,
        prompt_attention_mask: torch.Tensor,
        timestep: torch.Tensor,
        image_rope_cos: torch.Tensor,
        image_rope_sin: torch.Tensor,
        prompt_rope_cos: torch.Tensor,
        prompt_rope_sin: torch.Tensor,
    ) -> torch.Tensor:
        transformer = self.transformer
        image_length = image_tokens.shape[1]
        image_cos, image_sin = image_rope_cos, image_rope_sin
        prompt_cos, prompt_sin = prompt_rope_cos, prompt_rope_sin

        adaln = transformer.t_embedder(timestep * transformer.t_scale).type_as(image_tokens)

        image = transformer.all_x_embedder["2-1"](image_tokens)
        image = torch.where(
            image_padding_mask.unsqueeze(-1),
            transformer.x_pad_token.reshape(1, 1, -1),
            image,
        )
        image_attention = torch.ones_like(image_padding_mask, dtype=torch.bool)
        for layer in transformer.noise_refiner:
            image = self._block(layer, image, image_attention, image_cos, image_sin, adaln)

        # Diffusers' generic RMSNorm upcasts the variance calculation. The
        # pinned publisher implementation intentionally performs RMSNorm in
        # model precision, so spell out that observable denoiser contract.
        prompt = self._rms_norm(transformer.cap_embedder[0], prompt_embeddings)
        prompt = transformer.cap_embedder[1](prompt)
        prompt = torch.where(
            prompt_padding_mask.unsqueeze(-1),
            transformer.cap_pad_token.reshape(1, 1, -1),
            prompt,
        )
        for layer in transformer.context_refiner:
            prompt = self._block(
                layer, prompt, prompt_attention_mask, prompt_cos, prompt_sin, None
            )

        unified = torch.cat((image, prompt), dim=1)
        unified_cos = torch.cat((image_cos, prompt_cos), dim=1)
        unified_sin = torch.cat((image_sin, prompt_sin), dim=1)
        unified_attention = torch.cat((image_attention, prompt_attention_mask), dim=1)
        for layer in transformer.layers:
            unified = self._block(
                layer, unified, unified_attention, unified_cos, unified_sin, adaln
            )

        final = transformer.all_final_layer["2-1"]
        scale = 1.0 + final.adaLN_modulation(adaln)
        unified = final.linear(final.norm_final(unified) * scale.unsqueeze(1))
        return unified[:, :image_length]

    @staticmethod
    def _apply_rope(
        value: torch.Tensor, rope_cos: torch.Tensor, rope_sin: torch.Tensor
    ) -> torch.Tensor:
        # Keep the publisher's complex64 operation, not only its mathematical
        # formula.  Separate real multiply/add kernels round differently on
        # MPS and that one-ULP error compounds across the full transformer.
        # coreai-torch 0.4.2 lowers this internal complex operation while the
        # public ABI remains contiguous float32 cosine/sine tensors.
        pairs = value.float().reshape(*value.shape[:-1], value.shape[-1] // 2, 2)
        complex_value = torch.view_as_complex(pairs)
        frequencies = torch.complex(
            rope_cos.float(), rope_sin.float()
        ).unsqueeze(2)
        return (
            torch.view_as_real(complex_value * frequencies)
            .flatten(-2)
            .type_as(value)
        )

    @staticmethod
    def _rms_norm(norm: nn.Module, value: torch.Tensor) -> torch.Tensor:
        normalized = value * torch.rsqrt(
            value.pow(2).mean(-1, keepdim=True) + norm.eps
        )
        if norm.weight is not None:
            normalized = normalized * norm.weight
        if getattr(norm, "bias", None) is not None:
            normalized = normalized + norm.bias
        return normalized

    @staticmethod
    def _attention(
        attention: nn.Module,
        hidden: torch.Tensor,
        active_mask: torch.Tensor,
        rope_cos: torch.Tensor,
        rope_sin: torch.Tensor,
        accumulation: str,
    ) -> torch.Tensor:
        import torch.nn.functional as functional

        query = attention.to_q(hidden).unflatten(-1, (attention.heads, -1))
        key = attention.to_k(hidden).unflatten(-1, (attention.heads, -1))
        value = attention.to_v(hidden).unflatten(-1, (attention.heads, -1))
        if attention.norm_q is not None:
            query = DenoiserWrapper._rms_norm(attention.norm_q, query)
        if attention.norm_k is not None:
            key = DenoiserWrapper._rms_norm(attention.norm_k, key)
        query = DenoiserWrapper._apply_rope(query, rope_cos, rope_sin).transpose(1, 2)
        key = DenoiserWrapper._apply_rope(key, rope_cos, rope_sin).transpose(1, 2)
        value = value.transpose(1, 2)
        if accumulation == "float32":
            query, key, value = query.float(), key.float(), value.float()
        # The pinned publisher's native backend converts its Boolean valid-key
        # mask to an additive mask in the attention compute dtype before SDPA.
        # Preserve that detail because it can select a different MPS kernel.
        attention_mask = torch.where(
            active_mask,
            torch.zeros_like(active_mask, dtype=query.dtype),
            torch.full_like(active_mask, float("-inf"), dtype=query.dtype),
        )[:, None, None, :]
        attended = functional.scaled_dot_product_attention(
            query,
            key,
            value,
            attn_mask=attention_mask,
            dropout_p=0.0,
            is_causal=False,
        )
        attended = attended.transpose(1, 2).flatten(2, 3).type_as(hidden)
        output = attention.to_out[0](attended)
        if len(attention.to_out) > 1:
            output = attention.to_out[1](output)
        return output

    def _block(
        self,
        layer: nn.Module,
        hidden: torch.Tensor,
        active_mask: torch.Tensor,
        rope_cos: torch.Tensor,
        rope_sin: torch.Tensor,
        adaln: torch.Tensor | None,
    ) -> torch.Tensor:
        if layer.modulation:
            if adaln is None:
                raise RuntimeError("modulated Z-Image block requires a timestep embedding")
            modulation = layer.adaLN_modulation(adaln).unsqueeze(1)
            scale_attention, gate_attention, scale_feed_forward, gate_feed_forward = modulation.chunk(4, dim=2)
            gate_attention = gate_attention.tanh()
            gate_feed_forward = gate_feed_forward.tanh()
            scale_attention = torch.ones_like(scale_attention) + scale_attention
            scale_feed_forward = torch.ones_like(scale_feed_forward) + scale_feed_forward
            attention_input = self._rms_norm(layer.attention_norm1, hidden) * scale_attention
            attention_output = self._attention(
                layer.attention,
                attention_input,
                active_mask,
                rope_cos,
                rope_sin,
                self.attention_accumulation,
            )
            hidden = hidden + gate_attention * self._rms_norm(
                layer.attention_norm2, attention_output
            )
            feed_forward = layer.feed_forward(
                self._rms_norm(layer.ffn_norm1, hidden) * scale_feed_forward
            )
            return hidden + gate_feed_forward * self._rms_norm(
                layer.ffn_norm2, feed_forward
            )

        attention_output = self._attention(
            layer.attention,
            self._rms_norm(layer.attention_norm1, hidden),
            active_mask,
            rope_cos,
            rope_sin,
            self.attention_accumulation,
        )
        hidden = hidden + self._rms_norm(layer.attention_norm2, attention_output)
        return hidden + self._rms_norm(
            layer.ffn_norm2,
            layer.feed_forward(self._rms_norm(layer.ffn_norm1, hidden)),
        )


def make_rope(
    image_grid_height: int,
    image_grid_width: int,
    valid_prompt_tokens: int,
    prompt_bucket: int = 32,
    maximum_prompt_tokens: int = 512,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    """Build deterministic reference padding masks and real Z-Image RoPE."""
    if not 1 <= valid_prompt_tokens <= prompt_bucket <= maximum_prompt_tokens:
        raise ValueError("invalid prompt lengths")
    image_count = image_grid_height * image_grid_width
    padded_image_count = ((image_count + 31) // 32) * 32
    image_padding = torch.arange(padded_image_count) >= image_count
    prompt_padding = torch.arange(maximum_prompt_tokens) >= valid_prompt_tokens
    prompt_active = torch.arange(maximum_prompt_tokens) < prompt_bucket

    prompt_positions = torch.zeros(maximum_prompt_tokens, 3, dtype=torch.int64)
    # Diffusers constructs caption coordinates through the selected 32-token
    # bucket before replacing padding features with cap_pad_token. Consequently
    # the learned padding tokens keep positions valid+1...bucket, rather than
    # position zero. Preserve that observable publisher behavior exactly.
    prompt_positions[:prompt_bucket, 0] = torch.arange(1, prompt_bucket + 1)
    rows = torch.arange(image_grid_height, dtype=torch.int64)
    columns = torch.arange(image_grid_width, dtype=torch.int64)
    row_grid, column_grid = torch.meshgrid(rows, columns, indexing="ij")
    image_positions = torch.stack(
        (
            torch.full_like(row_grid, prompt_bucket + 1),
            row_grid,
            column_grid,
        ),
        dim=-1,
    ).reshape(-1, 3)
    if padded_image_count > image_count:
        image_positions = torch.cat(
            (image_positions, torch.zeros(padded_image_count - image_count, 3, dtype=torch.int64)),
            dim=0,
        )
    positions = torch.cat((image_positions, prompt_positions), dim=0)
    dimensions = (32, 48, 48)
    theta = 256.0
    frequencies = []
    for axis, dimension in enumerate(dimensions):
        inverse = 1.0 / (
            theta
            ** (torch.arange(0, dimension, 2, dtype=torch.float64) / dimension)
        )
        frequencies.append(positions[:, axis : axis + 1].double() * inverse.unsqueeze(0))
    angles = torch.cat(frequencies, dim=1).float()
    # Match the pinned publisher's RopeEmbedder exactly.  Although separate
    # cos/sin calls are mathematically equivalent, torch.polar rounds a small
    # number of float32 values differently; that one-ULP discrepancy compounds
    # through every attention layer in the full denoiser.
    complex_frequencies = torch.polar(torch.ones_like(angles), angles).to(
        torch.complex64
    )
    return (
        image_padding,
        prompt_padding,
        prompt_active,
        complex_frequencies.real.contiguous(),
        complex_frequencies.imag.contiguous(),
    )


def _locked_files_for_component(component: str) -> tuple[str, ...]:
    common = ("model_index.json",)
    if component == "prompt-encoder":
        return common + (
            "text_encoder/config.json", "text_encoder/generation_config.json",
            "text_encoder/model.safetensors.index.json",
            "text_encoder/model-00001-of-00003.safetensors",
            "text_encoder/model-00002-of-00003.safetensors",
            "text_encoder/model-00003-of-00003.safetensors",
        )
    if component == "denoiser":
        return common + (
            "transformer/config.json", "transformer/diffusion_pytorch_model.safetensors.index.json",
            "transformer/diffusion_pytorch_model-00001-of-00003.safetensors",
            "transformer/diffusion_pytorch_model-00002-of-00003.safetensors",
            "transformer/diffusion_pytorch_model-00003-of-00003.safetensors",
        )
    if component in {"vae-encoder", "vae-decoder"}:
        return common + ("vae/config.json", "vae/diffusion_pytorch_model.safetensors")
    raise ContractError(f"unknown component {component!r}")


def verify_component_source(source: Path, component: str) -> list[dict[str, Any]]:
    lock = load_json(HERE / "source-lock.json")
    if lock["publisherModel"]["revision"] != SOURCE_REVISION:
        raise ContractError("exporter revision and source lock disagree")
    source = audit_git_checkout(source, SOURCE_REVISION, "publisher source")
    locked = {item["path"]: item for item in lock["publisherModel"]["files"]}
    verified: list[dict[str, Any]] = []
    for relative in _locked_files_for_component(component):
        item = locked[relative]
        path = source / relative
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"missing source input: {relative}")
        if path.stat().st_size <= 1024 and path.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1"):
            raise ContractError(f"source input is still a Git LFS pointer: {relative}")
        if "size" in item and path.stat().st_size != item["size"]:
            raise ContractError(f"source input size mismatch: {relative}")
        digest = sha256_file(path)
        if digest != item["sha256"]:
            raise ContractError(f"source input digest mismatch: {relative}")
        verified.append({"path": relative, "sha256": digest, "size": path.stat().st_size})
    return verified


def _load_vae(source: Path, dtype: torch.dtype) -> nn.Module:
    from diffusers import AutoencoderKL

    return AutoencoderKL.from_pretrained(
        source,
        subfolder="vae",
        local_files_only=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    ).eval()


def _load_prompt_encoder(source: Path, dtype: torch.dtype) -> nn.Module:
    from transformers import Qwen3Model

    return Qwen3Model.from_pretrained(
        source / "text_encoder",
        local_files_only=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    ).eval()


def _load_denoiser(source: Path, dtype: torch.dtype) -> nn.Module:
    from diffusers import ZImageTransformer2DModel

    return ZImageTransformer2DModel.from_pretrained(
        source,
        subfolder="transformer",
        local_files_only=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    ).eval()


def _tiny_denoiser(dtype: torch.dtype = torch.float16) -> nn.Module:
    from diffusers import ZImageTransformer2DModel

    torch.manual_seed(7)
    return ZImageTransformer2DModel(
        all_patch_size=(2,), all_f_patch_size=(1,), in_channels=16,
        dim=128, n_layers=1, n_refiner_layers=1, n_heads=1, n_kv_heads=1,
        cap_feat_dim=64, axes_dims=[32, 48, 48], axes_lens=[1536, 512, 512],
    ).to(dtype).eval()


def _dynamic_shapes(component: str) -> dict[str, Any] | None:
    from torch.export import Dim

    latent_height_base = Dim("latent_height_base", min=32, max=128)
    latent_width_base = Dim("latent_width_base", min=32, max=128)
    latent_height = 2 * latent_height_base
    latent_width = 2 * latent_width_base
    pixel_height = 8 * latent_height
    pixel_width = 8 * latent_width
    if component == "vae-encoder":
        return {"image": {2: pixel_height, 3: pixel_width}}
    if component == "vae-decoder":
        return {"latent": {2: latent_height, 3: latent_width}}
    if component == "prompt-encoder":
        # The publisher tokenizer pads to its declared maximum length. Keeping
        # this ABI fixed avoids a second dynamic sequence axis in Core AI; the
        # host removes padding before choosing the denoiser's dynamic
        # 32-token-bucket input length.
        return None
    if component == "denoiser":
        image_token_groups = Dim("image_token_groups", min=32, max=512)
        prompt_token_groups = Dim("prompt_token_groups", min=1, max=16)
        image_tokens = 32 * image_token_groups
        prompt_tokens = 32 * prompt_token_groups
        return {
            "image_tokens": {1: image_tokens},
            "image_padding_mask": {1: image_tokens},
            "prompt_embeddings": {1: prompt_tokens},
            "prompt_padding_mask": {1: prompt_tokens},
            "prompt_attention_mask": {1: prompt_tokens},
            "timestep": None,
            "image_rope_cos": {1: image_tokens},
            "image_rope_sin": {1: image_tokens},
            "prompt_rope_cos": {1: prompt_tokens},
            "prompt_rope_sin": {1: prompt_tokens},
        }
    raise ContractError(f"no dynamic-shape contract for {component}")


def _denoiser_inputs(dtype: torch.dtype, prompt_width: int, prompt_bucket: int = 32) -> dict[str, torch.Tensor]:
    if prompt_bucket % 32 or not 32 <= prompt_bucket <= 512:
        raise ContractError("prompt bucket must be a multiple of 32 from 32 through 512")
    valid_prompt_tokens = max(1, prompt_bucket - 15)
    image_padding, prompt_padding, prompt_active, rope_cos, rope_sin = make_rope(
        32,
        32,
        valid_prompt_tokens=valid_prompt_tokens,
        prompt_bucket=prompt_bucket,
        maximum_prompt_tokens=prompt_bucket,
    )
    image_tokens = image_padding.shape[0]
    return {
        "image_tokens": torch.zeros(1, 1024, 64, dtype=dtype),
        "image_padding_mask": image_padding.unsqueeze(0),
        "prompt_embeddings": torch.zeros(1, prompt_bucket, prompt_width, dtype=dtype),
        "prompt_padding_mask": prompt_padding.unsqueeze(0),
        "prompt_attention_mask": prompt_active.unsqueeze(0),
        # The scheduler and publisher pass normalized timesteps in float32.
        "timestep": torch.full((1,), 0.5, dtype=torch.float32),
        # Publisher RoPE is generated and applied in float32 before casting
        # the rotated Q/K tensors back to model precision.
        "image_rope_cos": rope_cos[:image_tokens].unsqueeze(0).float(),
        "image_rope_sin": rope_sin[:image_tokens].unsqueeze(0).float(),
        "prompt_rope_cos": rope_cos[image_tokens:].unsqueeze(0).float(),
        "prompt_rope_sin": rope_sin[image_tokens:].unsqueeze(0).float(),
    }


def _build_export(component: str, source: Path, precision: str, probe: bool) -> tuple[nn.Module, dict[str, torch.Tensor], tuple[str, ...], tuple[str, ...], dict[str, Any] | None]:
    dtype = dtype_for_precision(precision)
    if component == "vae-encoder":
        model = VAEEncoderWrapper(_load_vae(source, dtype)).eval()
        inputs = {"image": torch.zeros(1, 3, 512, 512, dtype=dtype)}
        outputs = ("latent",)
    elif component == "vae-decoder":
        model = VAEDecoderWrapper(_load_vae(source, dtype)).eval()
        inputs = {"latent": torch.zeros(1, 16, 64, 64, dtype=dtype)}
        outputs = ("image",)
    elif component == "prompt-encoder":
        model = PromptEncoderWrapper(_load_prompt_encoder(source, dtype)).eval()
        inputs = {
            "input_ids": torch.zeros(1, 512, dtype=torch.int32),
            "attention_mask": torch.ones(1, 512, dtype=torch.bool),
        }
        outputs = ("prompt_embeddings",)
    elif component == "denoiser":
        transformer = _tiny_denoiser(dtype) if probe else _load_denoiser(source, dtype)
        prompt_width = 64 if probe else 2560
        model = DenoiserWrapper(transformer).eval()
        # Use an interior dynamic-shape example. Torch 2.9's non-strict
        # exporter mishandles a derived root whose example value is exactly
        # one, even though the declared prompt range still starts at 32.
        inputs = _denoiser_inputs(dtype, prompt_width, 64)
        outputs = ("noise_prediction",)
    else:
        raise ContractError(f"unsupported component: {component}")
    return model, inputs, tuple(inputs), outputs, _dynamic_shapes(component)


def _converter_mode(coreai_torch: Any, debug_export: bool) -> Any:
    return (
        coreai_torch.TorchConverter.Mode.DEBUG
        if debug_export
        else coreai_torch.TorchConverter.Mode.RELEASE
    )


def export_denoiser(
    model: nn.Module,
    precision: str,
    probe: bool,
    debug_export: bool = False,
) -> tuple[Any, dict[str, torch.Tensor]]:
    if debug_export and not probe:
        raise ContractError("DEBUG conversion is restricted to the tiny denoiser probe")
    import coreai_torch

    dtype = dtype_for_precision(precision)
    prompt_width = 64 if probe else 2560
    converter = coreai_torch.TorchConverter(
        mode=_converter_mode(coreai_torch, debug_export)
    )
    decomposition_table = coreai_torch.get_decomp_table()
    inputs = _denoiser_inputs(dtype, prompt_width, prompt_bucket=64)
    with torch.no_grad():
        exported = torch.export.export(
            model,
            args=(),
            kwargs=inputs,
            dynamic_shapes=_dynamic_shapes("denoiser"),
        )
    decomposed = exported.run_decompositions(decomposition_table)
    converter.add_exported_program(
        decomposed,
        input_names=tuple(inputs),
        output_names=("noise_prediction",),
        entrypoint_name="main",
    )
    program = converter.to_coreai()
    program.optimize()
    return program, inputs


def export_component(args: argparse.Namespace) -> None:
    started_utc = datetime.now(UTC).isoformat()
    started = time.perf_counter()
    source = guarded_resolve(Path(args.source))
    lexical_output = lexical_path(Path(args.output))
    if lexical_output.is_symlink():
        raise ContractError(f"component output must not be a symlink: {lexical_output}")
    output = outside_checkout(lexical_output)
    report_path = (
        outside_checkout(Path(args.report))
        if args.report
        else output.with_suffix(".export.json")
    )
    if args.debug_export and (args.component != "denoiser" or not args.probe):
        raise ContractError("--debug-export requires denoiser --probe")
    if output.suffix != ".aimodel":
        raise ContractError("component output must end in .aimodel")
    if output.exists():
        raise ContractError(f"refusing to replace existing output: {output}")
    if report_path.is_symlink() or report_path.exists():
        raise ContractError(f"refusing to replace existing report: {report_path}")
    if report_path == output or output in report_path.parents:
        raise ContractError(
            f"conversion report must stay outside the model artifact: {report_path}"
        )
    prepare_atomic_new_json(report_path, "conversion report")
    source_files = [] if args.probe else verify_component_source(source, args.component)

    from coreai_models.export.macos import export_to_coreai
    import coreai.runtime as runtime

    model, inputs, input_names, output_names, dynamic_shapes = _build_export(
        args.component, source, args.precision, args.probe
    )
    eager_values: tuple[torch.Tensor, ...] = ()
    if not args.skip_eager:
        eager_device = torch.device(args.eager_device)
        if eager_device.type == "mps" and not torch.backends.mps.is_available():
            raise ContractError("MPS eager validation was requested but is unavailable")
        if eager_device.type != "cpu":
            model.to(eager_device)
            eager_inputs = {name: value.to(eager_device) for name, value in inputs.items()}
        else:
            eager_inputs = inputs
        with torch.inference_mode():
            eager = model(**eager_inputs)
        eager_values = (eager,) if isinstance(eager, torch.Tensor) else tuple(eager)
        if len(eager_values) != len(output_names) or any(
            not torch.isfinite(value).all() for value in eager_values
        ):
            raise ContractError("eager reference output is non-finite or has the wrong arity")
        eager_values = tuple(value.detach().cpu() for value in eager_values)
        if eager_device.type != "cpu":
            model.to("cpu")

    if args.component == "denoiser":
        program, _ = export_denoiser(
            model,
            args.precision,
            args.probe,
            args.debug_export,
        )
    else:
        program = export_to_coreai(
            model,
            inputs,
            dynamic_shapes=dynamic_shapes,
            input_names=input_names,
            output_names=output_names,
        )
        program.optimize()
    output.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    metadata = runtime.AIModelAssetMetadata()
    debug_probe_metadata = None
    if args.debug_export:
        debug_probe_metadata = profiler_probe_metadata(args.precision)
        metadata.set_custom(DEBUG_METADATA_KEY, debug_probe_metadata)
    program.save_asset(output, metadata)
    report = {
        "schemaVersion": "1.0.0",
        "component": args.component,
        "variant": (
            "tiny-probe"
            if args.component == "denoiser" and args.probe
            else "dynamic-image-dynamic-prompt-bucket"
            if args.component == "denoiser"
            else "dynamic-512-2048"
            if args.component != "prompt-encoder"
            else "fixed-512-tokens"
        ),
        "functionNames": ["main"],
        "probe": args.probe,
        "debugExport": args.debug_export,
        "converterMode": "debug" if args.debug_export else "release",
        "profilerProbe": debug_probe_metadata,
        "precision": args.precision,
        "computationPrecision": (
            f"{args.precision}-with-float32-timestep-and-rope"
            if args.component == "denoiser"
            else args.precision
        ),
        "attentionAccumulation": "model-precision" if args.component == "denoiser" else None,
        "sourceRevision": None if args.probe else SOURCE_REVISION,
        "sourceFiles": source_files,
        "artifact": output.name,
        "digestAlgorithm": "sha256-tree-v1",
        "digest": sha256_tree(output),
        "eagerOutputShapes": [list(value.shape) for value in eager_values],
        "eagerValidation": "skipped" if args.skip_eager else f"passed-on-{args.eager_device}",
        "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
        "toolSHA256": sha256_file(Path(__file__).resolve()),
        "commandArguments": sys.argv[1:],
        "startedUTC": started_utc,
        "finishedUTC": datetime.now(UTC).isoformat(),
        "elapsedSeconds": time.perf_counter() - started,
        "peakResidentBytes": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        "system": system_record(),
    }
    write_atomic_new_json(report_path, report)
    print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("prompt-encoder", "denoiser", "vae-encoder", "vae-decoder"))
    parser.add_argument("--source", required=True, help="locked publisher snapshot directory")
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", help="write the conversion report outside the model artifact directory")
    parser.add_argument(
        "--precision",
        choices=("float16", "bfloat16", "float32"),
        help="component precision; defaults to bfloat16 for the denoiser, float16 for the prompt encoder, and float32 for the VAE",
    )
    parser.add_argument("--eager-device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--skip-eager", action="store_true", help="skip only the pre-export smoke pass; parity remains mandatory")
    parser.add_argument("--probe", action="store_true", help="denoiser only: export a tiny random graph to test operator support")
    parser.add_argument(
        "--debug-export",
        action="store_true",
        help=(
            "denoiser probe only: retain public Core AI profiler debug data; "
            "production exports remain RELEASE by default"
        ),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.precision is None:
        args.precision = default_precision(args.component)
    if args.probe and args.component != "denoiser":
        print("error: --probe is supported only for denoiser", file=sys.stderr)
        return 2
    if args.debug_export and (args.component != "denoiser" or not args.probe):
        print(
            "error: --debug-export requires denoiser --probe",
            file=sys.stderr,
        )
        return 2
    try:
        export_component(args)
    except (ContractError, RuntimeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
