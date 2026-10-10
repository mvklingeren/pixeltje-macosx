#!/usr/bin/env python3
"""Numerically bisect the full-width Z-Image denoiser without exporting it whole.

This offline-only diagnostic loads one block directly from the locked publisher
snapshot, exports that real 3,840-wide block to Core AI, and compares named
operator checkpoints.  It deliberately starts with a fixed 512x512 contract so
dynamic-axis behavior cannot obscure the first numerical failure.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import resource
import subprocess
import sys
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as functional
from safetensors import safe_open

from export_components import DenoiserWrapper, make_rope, verify_component_source
from pixaimodel import (
    ContractError,
    guarded_resolve,
    load_json,
    outside_checkout,
    sha256_file,
    sha256_tree,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json
from validate_components import (
    describe_function,
    invoke,
    load_publisher_transformer_module,
    metrics,
)


DIMENSION = 3_840
HEADS = 30
HEAD_DIMENSION = 128
FEED_FORWARD_DIMENSION = 10_240
PROMPT_CAPACITY = 512
IMAGE_TOKENS_512 = 1_024
UNIFIED_TOKENS_512 = IMAGE_TOKENS_512 + PROMPT_CAPACITY
ACTIVE_UNIFIED_TOKENS_512 = IMAGE_TOKENS_512 + 32
SOURCE_INDEX = "transformer/diffusion_pytorch_model.safetensors.index.json"

CHECKPOINT_NAMES = (
    "modulation",
    "attention_input",
    "query_projected",
    "key_projected",
    "value_projected",
    "query_normalized",
    "key_normalized",
    "query_rotated",
    "key_rotated",
    "attention_context_float32",
    "attention_context_model_precision",
    "attention_projected",
    "after_attention",
    "feed_forward_input",
    "feed_forward_w1",
    "feed_forward_w3",
    "feed_forward_gated",
    "feed_forward_projected",
    "output",
)


def _system_record() -> dict[str, Any]:
    try:
        macos = subprocess.run(
            ["sw_vers", "-productVersion"], check=True, capture_output=True, text=True
        ).stdout.strip()
        build = subprocess.run(
            ["sw_vers", "-buildVersion"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        macos, build = platform.mac_ver()[0] or "unknown", "unknown"
    try:
        xcode = subprocess.run(
            ["xcodebuild", "-version"], check=True, capture_output=True, text=True
        ).stdout.strip().splitlines()
    except (OSError, subprocess.CalledProcessError):
        xcode = []
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
        "xcode": xcode,
        "packages": packages,
    }


def _tensor_bytes(value: torch.Tensor) -> bytes:
    cpu = value.detach().cpu().contiguous()
    if cpu.dtype == torch.bfloat16:
        cpu = cpu.view(torch.uint16)
    array = cpu.numpy()
    return array.tobytes(order="C")


def tensor_record(value: torch.Tensor) -> dict[str, Any]:
    cpu = value.detach().cpu().contiguous()
    numeric = cpu.float()
    nan_mask = torch.isnan(numeric)
    positive_infinity = torch.isposinf(numeric)
    negative_infinity = torch.isneginf(numeric)
    finite_mask = torch.isfinite(numeric)
    finite_count = int(finite_mask.sum())
    record: dict[str, Any] = {
        "dtype": str(cpu.dtype).removeprefix("torch."),
        "shape": list(cpu.shape),
        "encoding": "native-endian-contiguous",
        "sha256": hashlib.sha256(_tensor_bytes(cpu)).hexdigest(),
        "elements": cpu.numel(),
        "finiteCount": finite_count,
        "nanCount": int(nan_mask.sum()),
        "positiveInfinityCount": int(positive_infinity.sum()),
        "negativeInfinityCount": int(negative_infinity.sum()),
    }
    if finite_count:
        finite = numeric[finite_mask].double()
        record.update(
            {
                "finiteMinimum": float(finite.min()),
                "finiteMaximum": float(finite.max()),
                "finiteAbsoluteMaximum": float(finite.abs().max()),
                "finiteMean": float(finite.mean()),
                "finiteStandardDeviation": float(finite.std(correction=0)),
                "finiteL2Norm": float(torch.linalg.vector_norm(finite)),
            }
        )
    return record


def _module_from_meta(factory: Any) -> nn.Module:
    with torch.device("meta"):
        return factory()


def _load_module_prefix(
    source: Path,
    module: nn.Module,
    prefix: str,
    dtype: torch.dtype,
) -> tuple[nn.Module, list[dict[str, Any]]]:
    index = load_json(source / SOURCE_INDEX)["weight_map"]
    expected = tuple(module.state_dict())
    by_shard: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for relative_name in expected:
        source_name = f"{prefix}.{relative_name}"
        shard = index.get(source_name)
        if shard is None:
            raise ContractError(f"locked source lacks tensor {source_name!r}")
        by_shard[shard].append((relative_name, source_name))

    state: dict[str, torch.Tensor] = {}
    records = []
    for shard, names in sorted(by_shard.items()):
        shard_path = source / "transformer" / shard
        with safe_open(shard_path, framework="pt", device="cpu") as tensors:
            for relative_name, source_name in names:
                original = tensors.get_tensor(source_name)
                converted = original.to(dtype=dtype)
                state[relative_name] = converted
                records.append(
                    {
                        "name": source_name,
                        "sourceDtype": str(original.dtype).removeprefix("torch."),
                        "runtimeDtype": str(converted.dtype).removeprefix("torch."),
                        "shape": list(converted.shape),
                        "finite": bool(torch.isfinite(converted).all()),
                        "minimum": float(converted.float().min()),
                        "maximum": float(converted.float().max()),
                    }
                )
                del original
    incompatible = module.load_state_dict(state, strict=True, assign=True)
    if incompatible.missing_keys or incompatible.unexpected_keys:
        raise ContractError(
            f"state mismatch for {prefix}: missing={incompatible.missing_keys}, "
            f"unexpected={incompatible.unexpected_keys}"
        )
    return module.eval(), sorted(records, key=lambda item: item["name"])


def load_block(source: Path, stage: str, index: int, dtype: torch.dtype) -> tuple[nn.Module, list[dict[str, Any]]]:
    from diffusers.models.transformers.transformer_z_image import ZImageTransformerBlock

    limits = {"noise-refiner": 2, "context-refiner": 2, "layer": 30}
    if not 0 <= index < limits[stage]:
        raise ContractError(f"{stage} index must be from 0 through {limits[stage] - 1}")
    modulation = stage != "context-refiner"
    module = _module_from_meta(
        lambda: ZImageTransformerBlock(
            index,
            DIMENSION,
            HEADS,
            HEADS,
            1e-5,
            True,
            modulation=modulation,
        )
    )
    prefix = {
        "noise-refiner": "noise_refiner",
        "context-refiner": "context_refiner",
        "layer": "layers",
    }[stage]
    return _load_module_prefix(source, module, f"{prefix}.{index}", dtype)


def load_publisher_block(
    source: Path,
    publisher_reference: Path,
    stage: str,
    index: int,
    dtype: torch.dtype,
) -> tuple[nn.Module, list[dict[str, Any]], dict[str, Any]]:
    publisher, reference_record = load_publisher_transformer_module(
        publisher_reference
    )
    layer_id = 1000 + index if stage == "noise-refiner" else index
    modulation = stage != "context-refiner"
    module = _module_from_meta(
        lambda: publisher.ZImageTransformerBlock(
            layer_id,
            DIMENSION,
            HEADS,
            HEADS,
            1e-5,
            True,
            modulation=modulation,
        )
    )
    prefix = {
        "noise-refiner": "noise_refiner",
        "context-refiner": "context_refiner",
        "layer": "layers",
    }[stage]
    loaded, records = _load_module_prefix(
        source, module, f"{prefix}.{index}", dtype
    )
    return loaded, records, reference_record


def load_timestep_embedder(source: Path, dtype: torch.dtype) -> nn.Module:
    from diffusers.models.transformers.transformer_z_image import TimestepEmbedder

    module = _module_from_meta(lambda: TimestepEmbedder(256, mid_size=1_024))
    loaded, _ = _load_module_prefix(source, module, "t_embedder", dtype)
    return loaded


def load_image_embedder(source: Path, dtype: torch.dtype) -> nn.Module:
    module = _module_from_meta(lambda: nn.Linear(64, DIMENSION, bias=True))
    loaded, _ = _load_module_prefix(
        source, module, "all_x_embedder.2-1", dtype
    )
    return loaded


def apply_rope(value: torch.Tensor, cosine: torch.Tensor, sine: torch.Tensor, precision: str) -> torch.Tensor:
    if precision == "adapter-float16":
        pairs = value.reshape(*value.shape[:-1], value.shape[-1] // 2, 2)
        even = pairs[..., 0]
        odd = pairs[..., 1]
        cosine_model = cosine.unsqueeze(2).type_as(value)
        sine_model = sine.unsqueeze(2).type_as(value)
        rotated_even = even * cosine_model - odd * sine_model
        rotated_odd = even * sine_model + odd * cosine_model
        return torch.stack((rotated_even, rotated_odd), dim=-1).flatten(-2)
    return DenoiserWrapper._apply_rope(value, cosine, sine)


class BlockCheckpointProbe(nn.Module):
    """Expose stable checkpoints inside one real Z-Image transformer block."""

    def __init__(
        self,
        block: nn.Module,
        rope_precision: str,
        attention_accumulation: str,
    ) -> None:
        super().__init__()
        self.block = block
        self.rope_precision = rope_precision
        self.attention_accumulation = attention_accumulation

    def forward(
        self,
        hidden: torch.Tensor,
        active_mask: torch.Tensor,
        rope_cos: torch.Tensor,
        rope_sin: torch.Tensor,
        adaln: torch.Tensor,
    ) -> tuple[torch.Tensor, ...]:
        block = self.block
        if block.modulation:
            modulation_layer = block.adaLN_modulation
            if isinstance(modulation_layer, nn.ModuleList):
                modulation_layer = modulation_layer[0]
            modulation = modulation_layer(adaln).unsqueeze(1)
            scale_attention, gate_attention, scale_feed_forward, gate_feed_forward = modulation.chunk(4, dim=2)
            gate_attention = gate_attention.tanh()
            gate_feed_forward = gate_feed_forward.tanh()
            scale_attention = torch.ones_like(scale_attention) + scale_attention
            scale_feed_forward = torch.ones_like(scale_feed_forward) + scale_feed_forward
            attention_input = DenoiserWrapper._rms_norm(
                block.attention_norm1, hidden
            ) * scale_attention
        else:
            modulation = torch.zeros(1, 1, 1, dtype=hidden.dtype, device=hidden.device)
            gate_attention = torch.ones(1, 1, 1, dtype=hidden.dtype, device=hidden.device)
            gate_feed_forward = torch.ones(1, 1, 1, dtype=hidden.dtype, device=hidden.device)
            scale_feed_forward = torch.ones(1, 1, 1, dtype=hidden.dtype, device=hidden.device)
            attention_input = DenoiserWrapper._rms_norm(
                block.attention_norm1, hidden
            )

        attention = block.attention
        heads = getattr(attention, "heads", None)
        if heads is None:
            heads = attention.n_heads
        query_projected = attention.to_q(attention_input).unflatten(-1, (heads, -1))
        key_projected = attention.to_k(attention_input).unflatten(-1, (heads, -1))
        value_projected = attention.to_v(attention_input).unflatten(-1, (heads, -1))
        query_normalized = DenoiserWrapper._rms_norm(
            attention.norm_q, query_projected
        )
        key_normalized = DenoiserWrapper._rms_norm(
            attention.norm_k, key_projected
        )
        query_rotated = apply_rope(query_normalized, rope_cos, rope_sin, self.rope_precision).transpose(1, 2)
        key_rotated = apply_rope(key_normalized, rope_cos, rope_sin, self.rope_precision).transpose(1, 2)
        value_heads = value_projected.transpose(1, 2)
        attention_query = query_rotated
        attention_key = key_rotated
        attention_value = value_heads
        if self.attention_accumulation == "float32":
            attention_query = attention_query.float()
            attention_key = attention_key.float()
            attention_value = attention_value.float()
        attention_mask = torch.where(
            active_mask,
            torch.zeros_like(active_mask, dtype=attention_query.dtype),
            torch.full_like(
                active_mask, float("-inf"), dtype=attention_query.dtype
            ),
        )[:, None, None, :]
        attention_context = functional.scaled_dot_product_attention(
            attention_query,
            attention_key,
            attention_value,
            attn_mask=attention_mask,
            dropout_p=0.0,
            is_causal=False,
        ).transpose(1, 2).flatten(2, 3)
        attention_context_float32 = attention_context.float()
        attention_context_model_precision = attention_context.type_as(hidden)
        attention_projected = attention.to_out[0](attention_context_model_precision)
        after_attention = hidden + gate_attention * DenoiserWrapper._rms_norm(
            block.attention_norm2, attention_projected
        )
        feed_forward_input = DenoiserWrapper._rms_norm(
            block.ffn_norm1, after_attention
        ) * scale_feed_forward
        feed_forward_w1 = block.feed_forward.w1(feed_forward_input)
        feed_forward_w3 = block.feed_forward.w3(feed_forward_input)
        feed_forward_gated = functional.silu(feed_forward_w1) * feed_forward_w3
        feed_forward_projected = block.feed_forward.w2(feed_forward_gated)
        output = after_attention + gate_feed_forward * DenoiserWrapper._rms_norm(
            block.ffn_norm2, feed_forward_projected
        )
        return (
            modulation,
            attention_input,
            query_projected,
            key_projected,
            value_projected,
            query_normalized,
            key_normalized,
            query_rotated,
            key_rotated,
            attention_context_float32,
            attention_context_model_precision,
            attention_projected,
            after_attention,
            feed_forward_input,
            feed_forward_w1,
            feed_forward_w3,
            feed_forward_gated,
            feed_forward_projected,
            output,
        )


def publisher_operation_sensitivity(
    block: nn.Module,
    hidden: torch.Tensor,
    active_mask: torch.Tensor,
    frequencies: torch.Tensor,
    adaln: torch.Tensor | None,
    rope_cos: torch.Tensor,
    rope_sin: torch.Tensor,
    standalone_output: torch.Tensor,
) -> dict[str, Any]:
    """Separate publisher complex-RoPE rounding from attention dispatch.

    The pinned block resolves both helpers through module globals at call time,
    which lets this diagnostic substitute one operation at a time without
    changing weights, inputs, or the learned graph.
    """

    transformer_module = sys.modules[block.__class__.__module__]
    attention_module = sys.modules.get("utils.attention")
    if attention_module is None:
        raise ContractError("publisher attention module was not loaded")
    publisher_apply_rope = transformer_module.apply_rotary_emb
    publisher_dispatch = attention_module.dispatch_attention

    def adapter_real_rope(
        value: torch.Tensor, complex_frequencies: torch.Tensor
    ) -> torch.Tensor:
        pairs = value.float().reshape(
            *value.shape[:-1], value.shape[-1] // 2, 2
        )
        even = pairs[..., 0]
        odd = pairs[..., 1]
        cosine = complex_frequencies.real.contiguous().unsqueeze(2)
        sine = complex_frequencies.imag.contiguous().unsqueeze(2)
        return (
            torch.stack(
                (even * cosine - odd * sine, even * sine + odd * cosine),
                dim=-1,
            )
            .flatten(-2)
            .type_as(value)
        )

    def adapter_direct_dispatch(
        query: torch.Tensor,
        key: torch.Tensor,
        value: torch.Tensor,
        attn_mask: torch.Tensor | None = None,
        dropout_p: float = 0.0,
        is_causal: bool = False,
        scale: float | None = None,
        backend: Any = None,
    ) -> torch.Tensor:
        del backend
        query = query.transpose(1, 2)
        key = key.transpose(1, 2)
        value = value.transpose(1, 2)
        if attn_mask is not None and attn_mask.ndim == 2:
            attn_mask = attn_mask[:, None, None, :]
        if attn_mask is not None and attn_mask.dtype == torch.bool:
            attn_mask = torch.where(
                attn_mask,
                torch.zeros_like(attn_mask, dtype=query.dtype),
                torch.full_like(attn_mask, float("-inf"), dtype=query.dtype),
            )
        result = functional.scaled_dot_product_attention(
            query,
            key,
            value,
            attn_mask=attn_mask,
            dropout_p=dropout_p,
            is_causal=is_causal,
            scale=scale,
        )
        return result.transpose(1, 2).contiguous()

    variants = (
        ("publisher-complex-publisher-dispatch", publisher_apply_rope, publisher_dispatch),
        ("adapter-real-publisher-dispatch", adapter_real_rope, publisher_dispatch),
        ("publisher-complex-adapter-direct", publisher_apply_rope, adapter_direct_dispatch),
        ("adapter-real-adapter-direct", adapter_real_rope, adapter_direct_dispatch),
    )
    outputs: dict[str, torch.Tensor] = {}
    records = []
    try:
        with torch.inference_mode():
            for name, rope_operation, dispatch_operation in variants:
                transformer_module.apply_rotary_emb = rope_operation
                attention_module.dispatch_attention = dispatch_operation
                started = time.perf_counter()
                first = block(
                    hidden, active_mask, frequencies, adaln
                ).detach().cpu()
                first_seconds = time.perf_counter() - started
                started = time.perf_counter()
                repeated = block(
                    hidden, active_mask, frequencies, adaln
                ).detach().cpu()
                repeat_seconds = time.perf_counter() - started
                outputs[name] = first
                records.append(
                    {
                        "name": name,
                        "output": tensor_record(first),
                        "repeatMaximumAbsoluteError": float(
                            (first.float() - repeated.float()).abs().max()
                        ),
                        "firstInvocationSeconds": first_seconds,
                        "repeatInvocationSeconds": repeat_seconds,
                    }
                )
    finally:
        transformer_module.apply_rotary_emb = publisher_apply_rope
        attention_module.dispatch_attention = publisher_dispatch

    baseline = outputs["publisher-complex-publisher-dispatch"]
    for record in records:
        record["toPublisherBaselineMetrics"] = metrics(
            outputs[record["name"]].float(), baseline.float()
        )
    return {
        "standaloneToPublisherBaselineMetrics": metrics(
            standalone_output.float(), baseline.float()
        ),
        "variants": records,
    }


def deterministic_inputs(
    source: Path,
    stage: str,
    dtype: torch.dtype,
    rope_precision: str,
    prompt_capacity: int,
    input_mode: str,
) -> dict[str, torch.Tensor]:
    generator = torch.Generator(device="cpu").manual_seed(0x5A1_512)
    if stage == "noise-refiner":
        sequence_length = IMAGE_TOKENS_512
        active_length = IMAGE_TOKENS_512
        _, _, _, rope_cos, rope_sin = make_rope(32, 32, 17, 32, PROMPT_CAPACITY)
        rope_cos = rope_cos[:sequence_length]
        rope_sin = rope_sin[:sequence_length]
    elif stage == "context-refiner":
        sequence_length = prompt_capacity
        active_length = min(32, prompt_capacity)
        _, _, _, all_cos, all_sin = make_rope(32, 32, 17, 32, PROMPT_CAPACITY)
        rope_cos = all_cos[IMAGE_TOKENS_512 : IMAGE_TOKENS_512 + prompt_capacity]
        rope_sin = all_sin[IMAGE_TOKENS_512 : IMAGE_TOKENS_512 + prompt_capacity]
    else:
        sequence_length = IMAGE_TOKENS_512 + prompt_capacity
        active_length = IMAGE_TOKENS_512 + min(32, prompt_capacity)
        _, _, _, all_cos, all_sin = make_rope(32, 32, 17, 32, PROMPT_CAPACITY)
        rope_cos = torch.cat(
            (all_cos[:IMAGE_TOKENS_512], all_cos[IMAGE_TOKENS_512 : IMAGE_TOKENS_512 + prompt_capacity])
        )
        rope_sin = torch.cat(
            (all_sin[:IMAGE_TOKENS_512], all_sin[IMAGE_TOKENS_512 : IMAGE_TOKENS_512 + prompt_capacity])
        )

    if input_mode == "publisher-prefix":
        if stage != "noise-refiner":
            raise ContractError(
                "publisher-prefix input is currently defined only for noise-refiner"
            )
        latent_generator = torch.Generator(device="cpu").manual_seed(
            512 * 100_003 + 512 * 101 + 32
        )
        latent = (
            torch.randn(
                1,
                16,
                64,
                64,
                dtype=torch.float32,
                generator=latent_generator,
            )
            * 0.1
        ).to(dtype)
        hidden_tokens = (
            latent.reshape(1, 16, 32, 2, 32, 2)
            .permute(0, 2, 4, 3, 5, 1)
            .reshape(1, IMAGE_TOKENS_512, 64)
            .contiguous()
        )
        image_embedder = load_image_embedder(source, dtype)
        with torch.inference_mode():
            hidden = image_embedder(hidden_tokens)
        del image_embedder, hidden_tokens, latent
    else:
        hidden = torch.randn(
            1, sequence_length, DIMENSION, dtype=dtype, generator=generator
        )
    active_mask = (torch.arange(sequence_length) < active_length).unsqueeze(0)
    timestep_embedder = load_timestep_embedder(source, dtype)
    with torch.inference_mode():
        adaln = timestep_embedder(torch.tensor([500.0], dtype=torch.float32)).to(dtype)
    del timestep_embedder
    rope_dtype = dtype if rope_precision == "adapter-float16" else torch.float32
    return {
        "hidden": hidden,
        "active_mask": active_mask,
        "rope_cos": rope_cos.unsqueeze(0).to(rope_dtype),
        "rope_sin": rope_sin.unsqueeze(0).to(rope_dtype),
        "adaln": adaln,
    }


def export_program(
    model: nn.Module,
    inputs: dict[str, torch.Tensor],
    optimize: bool,
    dynamic_axes: bool,
    stage: str,
    prompt_capacity: int,
) -> tuple[Any, Any, float]:
    import coreai_torch

    dynamic_shapes = None
    if dynamic_axes:
        from torch.export import Dim

        image_token_groups = Dim("image_token_groups", min=32, max=512)
        image_tokens = 32 * image_token_groups
        sequence = image_tokens + prompt_capacity if stage == "layer" else image_tokens
        dynamic_shapes = {
            "hidden": {1: sequence},
            "active_mask": {1: sequence},
            "rope_cos": {1: sequence},
            "rope_sin": {1: sequence},
            "adaln": None,
        }
    started = time.perf_counter()
    with torch.no_grad():
        exported = torch.export.export(
            model, args=(), kwargs=inputs, dynamic_shapes=dynamic_shapes
        )
    decomposed = exported.run_decompositions(coreai_torch.get_decomp_table())
    converter = coreai_torch.TorchConverter(mode=coreai_torch.TorchConverter.Mode.DEBUG)
    converter.add_exported_program(
        decomposed,
        input_names=tuple(inputs),
        output_names=CHECKPOINT_NAMES,
        entrypoint_name="main",
    )
    program = converter.to_coreai()
    if optimize:
        program.optimize()
    return program, decomposed, time.perf_counter() - started


async def run_probe(args: argparse.Namespace) -> dict[str, Any]:
    import coreai.runtime as runtime

    started_utc = datetime.now(UTC).isoformat()
    source = Path(args.source).resolve()
    output = Path(args.output).resolve()
    report_path = Path(args.report).resolve()
    if output.suffix != ".aimodel":
        raise ContractError("diagnostic output must end in .aimodel")
    for target in (output, report_path):
        if target.is_symlink() or target.exists():
            raise ContractError(f"refusing to replace existing evidence: {target}")
    if output.is_relative_to(Path(__file__).resolve().parents[2]):
        raise ContractError("large diagnostic assets must be outside the Git checkout")

    source_files = verify_component_source(source, "denoiser")
    dtype = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }[args.precision]
    block, weight_records = load_block(source, args.stage, args.index, dtype)
    publisher_block, publisher_weight_records, publisher_reference = (
        load_publisher_block(
            source,
            Path(args.publisher_reference).resolve(),
            args.stage,
            args.index,
            dtype,
        )
    )
    if args.dynamic_axes and args.stage == "context-refiner":
        raise ContractError("context-refiner prompt capacity is fixed; dynamic axes do not apply")
    inputs = deterministic_inputs(
        source,
        args.stage,
        dtype,
        args.rope_precision,
        args.prompt_capacity,
        args.input_mode,
    )
    model = BlockCheckpointProbe(
        block, args.rope_precision, args.attention_accumulation
    ).eval()
    eager_device = torch.device(args.eager_device)
    if eager_device.type == "mps" and not torch.backends.mps.is_available():
        raise ContractError("MPS eager diagnostics were requested but MPS is unavailable")
    eager_inputs = {name: value.to(eager_device) for name, value in inputs.items()}

    publisher_probe = BlockCheckpointProbe(
        publisher_block,
        args.rope_precision,
        args.attention_accumulation,
    ).eval().to(eager_device)
    with torch.inference_mode():
        publisher_started = time.perf_counter()
        publisher_values = tuple(
            value.detach().cpu() for value in publisher_probe(**eager_inputs)
        )
        publisher_probe_seconds = time.perf_counter() - publisher_started
        frequencies = torch.complex(
            eager_inputs["rope_cos"].float(), eager_inputs["rope_sin"].float()
        )
        publisher_actual_started = time.perf_counter()
        publisher_actual_output = publisher_block(
            eager_inputs["hidden"],
            eager_inputs["active_mask"],
            frequencies,
            eager_inputs["adaln"] if publisher_block.modulation else None,
        ).detach().cpu()
        publisher_actual_seconds = time.perf_counter() - publisher_actual_started
        publisher_sensitivity = publisher_operation_sensitivity(
            publisher_block,
            eager_inputs["hidden"],
            eager_inputs["active_mask"],
            frequencies,
            eager_inputs["adaln"] if publisher_block.modulation else None,
            eager_inputs["rope_cos"],
            eager_inputs["rope_sin"],
            publisher_actual_output,
        )
    publisher_probe.to("cpu")
    publisher = dict(zip(CHECKPOINT_NAMES, publisher_values, strict=True))
    publisher_output_finite = bool(
        torch.isfinite(publisher["output"]).all()
        and torch.isfinite(publisher_actual_output).all()
    )
    publisher_instrumentation_metrics = (
        metrics(publisher["output"].float(), publisher_actual_output.float())
        if publisher_output_finite else None
    )
    publisher_instrumentation_repeat_error = (
        float(
            (publisher["output"].float() - publisher_actual_output.float())
            .abs()
            .max()
        )
        if publisher_output_finite else None
    )
    if eager_device.type == "mps":
        torch.mps.empty_cache()

    model.to(eager_device)
    with torch.inference_mode():
        eager_started = time.perf_counter()
        eager_values = tuple(value.detach().cpu() for value in model(**eager_inputs))
        eager_seconds = time.perf_counter() - eager_started
    model.to("cpu")
    del eager_inputs
    if eager_device.type == "mps":
        torch.mps.empty_cache()
    eager = dict(zip(CHECKPOINT_NAMES, eager_values, strict=True))
    eager_all_finite = all(torch.isfinite(value).all() for value in eager.values())
    publisher_all_finite = all(
        torch.isfinite(value).all() for value in publisher.values()
    ) and bool(torch.isfinite(publisher_actual_output).all())
    if not eager_all_finite or args.eager_only:
        eager_results = []
        prior_finite = True
        for name in CHECKPOINT_NAMES:
            finite = bool(torch.isfinite(eager[name]).all())
            publisher_finite = bool(torch.isfinite(publisher[name]).all())
            adapter_metrics = (
                metrics(eager[name].float(), publisher[name].float())
                if finite and publisher_finite else None
            )
            passed = (
                finite
                and publisher_finite
                and adapter_metrics is not None
                and adapter_metrics["correlation"] >= 0.99999
                and adapter_metrics["peakSignalToNoiseRatio"] >= 60.0
            )
            eager_results.append(
                {
                    "name": name,
                    "publisher": tensor_record(publisher[name]),
                    "eager": tensor_record(eager[name]),
                    "adapterToPublisherMetrics": adapter_metrics,
                    "firstNonFiniteCheckpoint": prior_finite and not finite,
                    "status": "passed" if passed else "failed",
                }
            )
            prior_finite = prior_finite and finite
        return {
            "schemaVersion": "1.0.0",
            "diagnostic": "z-image-denoiser-full-width-block-eager-checkpoints",
            "stage": args.stage,
            "index": args.index,
            "imageResolution": {"width": 512, "height": 512},
            "promptBucket": 32,
            "promptCapacity": args.prompt_capacity,
            "inputMode": args.input_mode,
            "weightPrecision": f"{args.precision}-from-locked-float32-publisher-weights",
            "ropePrecision": args.rope_precision,
            "attentionAccumulation": args.attention_accumulation,
            "eagerDevice": args.eager_device,
            "sourceFiles": source_files,
            "weights": weight_records,
            "publisherWeights": publisher_weight_records,
            "publisherReference": publisher_reference,
            "publisherInstrumentation": {
                "actualOutput": tensor_record(publisher_actual_output),
                "instrumentedToActualMetrics": publisher_instrumentation_metrics,
                "maximumAbsoluteError": publisher_instrumentation_repeat_error,
            },
            "publisherOperationSensitivity": publisher_sensitivity,
            "inputs": {name: tensor_record(value) for name, value in inputs.items()},
            "asset": None,
            "tool": str(Path(__file__).resolve()),
            "toolSHA256": sha256_file(Path(__file__).resolve()),
            "sourceLockSHA256": sha256_file(Path(__file__).with_name("source-lock.json")),
            "commandArguments": sys.argv[1:],
            "startedUTC": started_utc,
            "finishedUTC": datetime.now(UTC).isoformat(),
            "system": _system_record(),
            "timings": {
                "publisherProbeSeconds": publisher_probe_seconds,
                "publisherActualSeconds": publisher_actual_seconds,
                "adapterEagerSeconds": eager_seconds,
            },
            "results": eager_results,
            "peakResidentBytes": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
            "status": (
                "passed"
                if eager_all_finite
                and publisher_all_finite
                and all(item["status"] == "passed" for item in eager_results)
                and publisher_instrumentation_metrics is not None
                and publisher_instrumentation_metrics["correlation"] >= 0.99999
                and publisher_instrumentation_metrics["peakSignalToNoiseRatio"] >= 60.0
                else "failed"
            ),
        }

    program, _exported, export_seconds = export_program(
        model,
        inputs,
        args.optimize,
        args.dynamic_axes,
        args.stage,
        args.prompt_capacity,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    metadata = runtime.AIModelAssetMetadata()
    program.save_asset(output, metadata)
    asset_digest = sha256_tree(output)

    load_started = time.perf_counter()
    options = runtime.SpecializationOptions.cpu_only()
    loaded = await runtime.AIModel.load(str(output), options)
    load_seconds = time.perf_counter() - load_started
    function = loaded.load_function("main")
    descriptor = describe_function(function)
    actual_outputs, first_seconds = await invoke(function, **inputs)
    repeated_outputs, repeat_seconds = await invoke(function, **inputs)

    results = []
    all_passed = True
    for name in CHECKPOINT_NAMES:
        expected = eager[name].float()
        publisher_expected = publisher[name].float()
        actual = actual_outputs[name]
        repeated = repeated_outputs[name]
        actual_finite = bool(torch.isfinite(actual).all())
        repeated_finite = bool(torch.isfinite(repeated).all())
        observed = metrics(actual, expected) if actual_finite else None
        adapter_to_publisher = metrics(expected, publisher_expected)
        coreai_to_publisher = (
            metrics(actual, publisher_expected) if actual_finite else None
        )
        repeat_maximum_error = (
            float((actual - repeated).abs().max())
            if actual_finite and repeated_finite
            else None
        )
        passed = (
            actual.shape == expected.shape
            and actual_finite
            and repeated_finite
            and observed is not None
            and observed["correlation"] >= 0.999
            and observed["peakSignalToNoiseRatio"] >= 40.0
            and adapter_to_publisher["correlation"] >= 0.99999
            and adapter_to_publisher["peakSignalToNoiseRatio"] >= 60.0
            and coreai_to_publisher is not None
            and coreai_to_publisher["correlation"] >= 0.999
            and coreai_to_publisher["peakSignalToNoiseRatio"] >= 40.0
            and repeat_maximum_error == 0.0
        )
        all_passed = all_passed and passed
        result: dict[str, Any] = {
            "name": name,
            "publisher": tensor_record(publisher[name]),
            "eager": tensor_record(expected),
            "coreAI": tensor_record(actual),
            "repeatedCoreAI": tensor_record(repeated),
            "coreAIToEagerMetrics": observed,
            "adapterToPublisherMetrics": adapter_to_publisher,
            "coreAIToPublisherMetrics": coreai_to_publisher,
            "repeatMaximumAbsoluteError": repeat_maximum_error,
            "status": "passed" if passed else "failed",
        }
        results.append(result)

    return {
        "schemaVersion": "1.0.0",
        "diagnostic": "z-image-denoiser-full-width-block-checkpoints",
        "stage": args.stage,
        "index": args.index,
        "imageResolution": {"width": 512, "height": 512},
        "promptBucket": 32,
        "promptCapacity": args.prompt_capacity,
        "inputMode": args.input_mode,
        "weightPrecision": f"{args.precision}-from-locked-float32-publisher-weights",
        "ropePrecision": args.rope_precision,
        "attentionAccumulation": args.attention_accumulation,
        "eagerDevice": args.eager_device,
        "dynamicAxes": args.dynamic_axes,
        "optimized": args.optimize,
        "computePolicy": "cpu-only",
        "sourceFiles": source_files,
        "weights": weight_records,
        "publisherWeights": publisher_weight_records,
        "publisherReference": publisher_reference,
        "publisherInstrumentation": {
            "actualOutput": tensor_record(publisher_actual_output),
            "instrumentedToActualMetrics": publisher_instrumentation_metrics,
            "maximumAbsoluteError": publisher_instrumentation_repeat_error,
        },
        "publisherOperationSensitivity": publisher_sensitivity,
        "inputs": {name: tensor_record(value) for name, value in inputs.items()},
        "asset": str(output),
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": asset_digest,
        "tool": str(Path(__file__).resolve()),
        "toolSHA256": sha256_file(Path(__file__).resolve()),
        "sourceLockSHA256": sha256_file(Path(__file__).with_name("source-lock.json")),
        "commandArguments": sys.argv[1:],
        "startedUTC": started_utc,
        "finishedUTC": datetime.now(UTC).isoformat(),
        "descriptor": descriptor,
        "system": _system_record(),
        "timings": {
            "publisherProbeSeconds": publisher_probe_seconds,
            "publisherActualSeconds": publisher_actual_seconds,
            "adapterEagerSeconds": eager_seconds,
            "exportSeconds": export_seconds,
            "modelLoadSeconds": load_seconds,
            "firstInvocationSeconds": first_seconds,
            "repeatInvocationSeconds": repeat_seconds,
        },
        "results": results,
        "peakResidentBytes": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        "status": (
            "passed"
            if all_passed
            and publisher_all_finite
            and publisher_instrumentation_metrics is not None
            and publisher_instrumentation_metrics["correlation"] >= 0.99999
            and publisher_instrumentation_metrics["peakSignalToNoiseRatio"] >= 60.0
            else "failed"
        ),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="locked publisher snapshot")
    parser.add_argument(
        "--publisher-reference",
        required=True,
        help="pinned Tongyi-MAI/Z-Image checkout used as the eager oracle",
    )
    parser.add_argument("--stage", choices=("noise-refiner", "context-refiner", "layer"), default="layer")
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument(
        "--precision",
        choices=("float16", "bfloat16", "float32"),
        default="bfloat16",
    )
    parser.add_argument("--eager-device", choices=("cpu", "mps"), default="mps")
    parser.add_argument(
        "--prompt-capacity",
        type=int,
        choices=(32, 512),
        default=512,
        help="fixed prompt tensor capacity; 32 is the canonical bucket-32 topology",
    )
    parser.add_argument("--dynamic-axes", action="store_true")
    parser.add_argument(
        "--input-mode",
        choices=("synthetic", "publisher-prefix"),
        default="synthetic",
    )
    parser.add_argument("--eager-only", action="store_true")
    parser.add_argument(
        "--rope-precision",
        choices=("publisher-float32", "adapter-float16"),
        default="publisher-float32",
    )
    parser.add_argument(
        "--attention-accumulation",
        choices=("model", "float32"),
        default="model",
    )
    parser.add_argument("--optimize", action=argparse.BooleanOptionalAction, default=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.source = str(guarded_resolve(Path(args.source)))
        args.publisher_reference = str(
            guarded_resolve(Path(args.publisher_reference))
        )
        args.output = str(outside_checkout(Path(args.output)))
        args.report = str(outside_checkout(Path(args.report)))
        report_path = prepare_atomic_new_json(
            Path(args.report).resolve(), "denoiser diagnostic report"
        )
        report = asyncio.run(run_probe(args))
        write_atomic_new_json(report_path, report)
        print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
        return 0 if report["status"] == "passed" else 1
    except (ContractError, RuntimeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        gc.collect()


if __name__ == "__main__":
    raise SystemExit(main())
