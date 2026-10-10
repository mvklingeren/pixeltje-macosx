#!/usr/bin/env python3
"""Run Core AI descriptor, numerical parity, finiteness and repeatability gates."""

from __future__ import annotations

import argparse
import asyncio
import gc
import hashlib
import importlib.util
import importlib.metadata
import json
import math
import os
import platform
import resource
import subprocess
import sys
import time
import types
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
from safetensors import safe_open

from export_components import (
    DenoiserWrapper,
    PromptEncoderWrapper,
    VAEDecoderWrapper,
    VAEEncoderWrapper,
    _load_vae,
    _load_prompt_encoder,
    _load_denoiser,
    _tiny_denoiser,
    dtype_for_precision,
    make_rope,
    verify_component_source,
)
from pixaimodel import (
    ContractError,
    HERE,
    audit_git_checkout,
    guarded_resolve,
    load_json,
    outside_checkout,
    sha256_file,
    sha256_tree,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json


def parse_shape(value: str) -> tuple[int, int]:
    try:
        width, height = (int(part) for part in value.lower().split("x", 1))
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError(f"invalid WIDTHxHEIGHT shape: {value!r}") from error
    for name, dimension in (("width", width), ("height", height)):
        if not 512 <= dimension <= 2048 or dimension % 16:
            raise argparse.ArgumentTypeError(f"{name} must be a multiple of 16 from 512 through 2048")
    return width, height


def parse_prompt_bucket(value: str) -> int:
    try:
        bucket = int(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError(
            f"invalid prompt bucket: {value!r}"
        ) from error
    if not 32 <= bucket <= 512 or bucket % 32:
        raise argparse.ArgumentTypeError(
            "prompt bucket must be a multiple of 32 from 32 through 512"
        )
    return bucket


def descriptor_value(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (list, tuple)):
        return [descriptor_value(item) for item in value]
    return str(value)


def describe_function(function: Any) -> dict[str, Any]:
    description = function.desc
    inputs = []
    for name in description.input_names:
        item = description.input_descriptor(name)
        inputs.append(
            {
                "name": name,
                "dtype": descriptor_value(item.dtype),
                "rank": item.rank,
                "shape": descriptor_value(item.shape),
                "storageKind": descriptor_value(item.storage_kind),
            }
        )
    outputs = []
    for name in description.output_names:
        item = description.output_descriptor(name)
        outputs.append(
            {
                "name": name,
                "dtype": descriptor_value(item.dtype),
                "rank": item.rank,
                "shape": descriptor_value(item.shape),
                "storageKind": descriptor_value(item.storage_kind),
            }
        )
    return {"name": description.name, "inputs": inputs, "outputs": outputs}


def correlation(first: torch.Tensor, second: torch.Tensor) -> float:
    first_values = first.flatten().double().numpy()
    second_values = second.flatten().double().numpy()
    if not np.isfinite(first_values).all() or not np.isfinite(second_values).all():
        raise ContractError("cannot calculate parity metrics for non-finite tensors")
    if np.std(first_values) == 0 or np.std(second_values) == 0:
        return 1.0 if np.array_equal(first_values, second_values) else 0.0
    return float(np.corrcoef(first_values, second_values)[0, 1])


def metrics(actual: torch.Tensor, expected: torch.Tensor) -> dict[str, float]:
    difference = (actual.float() - expected.float()).abs()
    mean_squared_error = float(torch.mean(difference.square()))
    data_range = float(expected.max() - expected.min())
    # Keep reports strict JSON. A large finite sentinel retains the useful
    # ordering for exact equality without serializing non-standard Infinity.
    psnr = 999.0 if mean_squared_error == 0 else 20 * math.log10(max(data_range, 1e-12)) - 10 * math.log10(mean_squared_error)
    return {
        "correlation": correlation(actual, expected),
        "maximumAbsoluteError": float(difference.max()),
        "meanAbsoluteError": float(difference.mean()),
        "rootMeanSquaredError": math.sqrt(mean_squared_error),
        "peakSignalToNoiseRatio": psnr,
    }


def repeat_error(first: torch.Tensor, second: torch.Tensor) -> float | None:
    difference = (first.float() - second.float()).abs()
    if not bool(torch.isfinite(difference).all()):
        return None
    return float(difference.max())


def tensor_summary(value: torch.Tensor) -> dict[str, Any]:
    numeric = value.detach().cpu().float().contiguous()
    finite = torch.isfinite(numeric)
    result: dict[str, Any] = {
        "shape": list(value.shape),
        "dtype": str(value.dtype).removeprefix("torch."),
        "elements": value.numel(),
        "finiteCount": int(finite.sum()),
        "nanCount": int(torch.isnan(numeric).sum()),
        "positiveInfinityCount": int(torch.isposinf(numeric).sum()),
        "negativeInfinityCount": int(torch.isneginf(numeric).sum()),
        "float32SHA256": hashlib.sha256(numeric.numpy().tobytes(order="C")).hexdigest(),
    }
    if bool(finite.any()):
        values = numeric[finite].double()
        result.update(
            {
                "finiteMinimum": float(values.min()),
                "finiteMaximum": float(values.max()),
                "finiteAbsoluteMaximum": float(values.abs().max()),
                "finiteMean": float(values.mean()),
                "finiteStandardDeviation": float(values.std(correction=0)),
            }
        )
    return result


def verify_publisher_reference(reference: Path) -> dict[str, Any]:
    locked = load_json(HERE / "source-lock.json")["publisherReference"]
    reference = audit_git_checkout(
        reference, locked["revision"], "publisher reference"
    )
    revision = locked["revision"]
    license_path = reference / "LICENSE"
    if sha256_file(license_path) != locked["licenseSHA256"]:
        raise ContractError("publisher reference license digest mismatch")
    transformer_path = reference / "src" / "zimage" / "transformer.py"
    attention_path = reference / "src" / "utils" / "attention.py"
    return {
        "repository": locked["repository"],
        "revision": revision,
        "licenseSHA256": locked["licenseSHA256"],
        "transformerSHA256": sha256_file(transformer_path),
        "attentionSHA256": sha256_file(attention_path),
    }


def _assign_meta_tensor(module: nn.Module, name: str, value: torch.Tensor) -> None:
    owner: nn.Module = module
    parts = name.split(".")
    for part in parts[:-1]:
        child = owner._modules.get(part)
        if child is None:
            raise ContractError(f"publisher module has no state owner for {name!r}")
        owner = child
    leaf = parts[-1]
    if leaf in owner._parameters:
        original = owner._parameters[leaf]
        owner._parameters[leaf] = nn.Parameter(
            value, requires_grad=False if original is None else original.requires_grad
        )
    elif leaf in owner._buffers:
        owner._buffers[leaf] = value
    else:
        raise ContractError(f"publisher module has no state tensor {name!r}")


def load_publisher_transformer_module(
    reference: Path,
) -> tuple[Any, dict[str, Any]]:
    reference_record = verify_publisher_reference(reference)
    source_root = reference / "src"
    source_directory = str(source_root)
    if source_directory not in sys.path:
        sys.path.insert(0, source_directory)

    # Loading zimage as a package executes the publisher's convenience
    # pipeline and optional UI/logging imports. This validator needs only the
    # pinned transformer and attention math, so load those files directly.
    utilities_root = source_root / "utils"
    existing_utilities = sys.modules.get("utils")
    if existing_utilities is None:
        utilities = types.ModuleType("utils")
        utilities.__path__ = [str(utilities_root)]
        utilities.__package__ = "utils"
        sys.modules["utils"] = utilities
    elif str(utilities_root) not in getattr(existing_utilities, "__path__", []):
        raise ContractError("a different top-level utils package is already loaded")

    transformer_path = source_root / "zimage" / "transformer.py"
    module_name = "pixeltje_pinned_zimage_transformer"
    specification = importlib.util.spec_from_file_location(module_name, transformer_path)
    if specification is None or specification.loader is None:
        raise ContractError("cannot load pinned publisher transformer module")
    publisher_module = importlib.util.module_from_spec(specification)
    sys.modules[module_name] = publisher_module
    specification.loader.exec_module(publisher_module)
    return publisher_module, reference_record


def load_publisher_denoiser(
    source: Path,
    reference: Path,
    dtype: torch.dtype,
) -> tuple[nn.Module, dict[str, Any]]:
    publisher_module, reference_record = load_publisher_transformer_module(reference)
    ZImageTransformer2DModel = publisher_module.ZImageTransformer2DModel

    config = load_json(source / "transformer" / "config.json")
    constructor_keys = (
        "all_patch_size",
        "all_f_patch_size",
        "in_channels",
        "dim",
        "n_layers",
        "n_refiner_layers",
        "n_heads",
        "n_kv_heads",
        "norm_eps",
        "qk_norm",
        "cap_feat_dim",
        "rope_theta",
        "t_scale",
        "axes_dims",
        "axes_lens",
    )
    arguments = {key: config[key] for key in constructor_keys}
    arguments["all_patch_size"] = tuple(arguments["all_patch_size"])
    arguments["all_f_patch_size"] = tuple(arguments["all_f_patch_size"])
    with torch.device("meta"):
        model = ZImageTransformer2DModel(**arguments)

    expected = set(model.state_dict())
    index = load_json(
        source / "transformer" / "diffusion_pytorch_model.safetensors.index.json"
    )["weight_map"]
    if expected != set(index):
        missing = sorted(expected - set(index))
        unexpected = sorted(set(index) - expected)
        raise ContractError(
            f"publisher state mapping mismatch: missing={missing[:5]}, unexpected={unexpected[:5]}"
        )
    by_shard: dict[str, list[str]] = {}
    for name in sorted(expected):
        by_shard.setdefault(index[name], []).append(name)
    for shard, names in sorted(by_shard.items()):
        path = source / "transformer" / shard
        with safe_open(path, framework="pt", device="cpu") as tensors:
            for name in names:
                _assign_meta_tensor(model, name, tensors.get_tensor(name).to(dtype))
    remaining_meta = [
        name for name, value in model.state_dict().items() if value.device.type == "meta"
    ]
    if remaining_meta:
        raise ContractError(f"publisher state remains unmaterialized: {remaining_meta[:5]}")
    return model.eval(), reference_record


def synthetic_image(width: int, height: int) -> torch.Tensor:
    horizontal = torch.linspace(-1.0, 1.0, width, dtype=torch.float32)
    vertical = torch.linspace(-1.0, 1.0, height, dtype=torch.float32)
    x = horizontal[None, None, None, :].expand(1, 1, height, width)
    y = vertical[None, None, :, None].expand(1, 1, height, width)
    return torch.cat((x, y, 0.5 * (x + y)), dim=1).contiguous()


def synthetic_latent(width: int, height: int) -> torch.Tensor:
    latent_width, latent_height = width // 8, height // 8
    x = torch.linspace(-math.pi, math.pi, latent_width, dtype=torch.float32)
    y = torch.linspace(-math.pi, math.pi, latent_height, dtype=torch.float32)
    grid_y, grid_x = torch.meshgrid(y, x, indexing="ij")
    channels = []
    for index in range(16):
        channels.append(0.2 * torch.sin(grid_x * (index + 1) / 7) * torch.cos(grid_y * (index + 2) / 9))
    return torch.stack(channels, dim=0).unsqueeze(0).contiguous()


def patchify_latents(latents: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    batch, channels, height, width = latents.shape
    if batch != 1 or channels != 16 or height % 2 or width % 2:
        raise ContractError("Z-Image latent must be batch-one 16-channel with even spatial axes")
    tokens = (
        latents.reshape(batch, channels, height // 2, 2, width // 2, 2)
        .permute(0, 2, 4, 3, 5, 1)
        .reshape(batch, -1, 64)
    )
    count = tokens.shape[1]
    padded_count = ((count + 31) // 32) * 32
    padding_mask = torch.arange(padded_count) >= count
    if padded_count > count:
        tokens = torch.cat((tokens, tokens[:, -1:].expand(batch, padded_count - count, 64)), dim=1)
    return tokens.contiguous(), padding_mask.unsqueeze(0)


def unpatchify_tokens(tokens: torch.Tensor, width: int, height: int) -> torch.Tensor:
    grid_width, grid_height = width // 16, height // 16
    count = grid_width * grid_height
    return (
        tokens[:, :count]
        .reshape(1, grid_height, grid_width, 2, 2, 16)
        .permute(0, 5, 1, 3, 2, 4)
        .reshape(1, 16, height // 8, width // 8)
        .contiguous()
    )


def _system_record() -> dict[str, Any]:
    try:
        macos = subprocess.run(["sw_vers", "-productVersion"], check=True, capture_output=True, text=True).stdout.strip()
        build = subprocess.run(["sw_vers", "-buildVersion"], check=True, capture_output=True, text=True).stdout.strip()
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


def validation_specialization_options(runtime: Any) -> Any:
    """Select the explicit validation policy without hiding CPU fallback."""
    policy = os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred")
    if policy == "cpu-only":
        return runtime.SpecializationOptions.cpu_only()
    if policy == "gpu-preferred":
        preferred = runtime.ComputeUnitKind.gpu()
    elif policy == "ane-preferred":
        preferred = runtime.ComputeUnitKind.neural_engine()
    else:
        raise ContractError(f"unsupported PIXELTJE_COREAI_COMPUTE policy: {policy}")
    return runtime.SpecializationOptions.from_preferred_compute_unit_kind(
        preferred
    )


def specialization_record(runtime: Any) -> dict[str, Any]:
    options = validation_specialization_options(runtime)
    preferred = options.preferred_compute_unit_kind
    return {
        "allowedComputeUnits": [str(kind) for kind in options.allowed_compute_unit_kinds],
        "preferredComputeUnit": None if preferred is None else str(preferred),
    }


async def load_function(asset: Path, function_name: str) -> tuple[Any, dict[str, Any], float]:
    import coreai.runtime as runtime

    start = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    elapsed = time.perf_counter() - start
    if function_name not in model.function_names:
        raise ContractError(f"Core AI asset lacks function {function_name!r}: {model.function_names}")
    function = model.load_function(function_name)
    return function, describe_function(function), elapsed


async def invoke(function: Any, **values: torch.Tensor) -> tuple[dict[str, torch.Tensor], float]:
    import coreai.runtime as runtime

    runtime_values = {
        name: runtime.NDArray(value.detach().cpu().contiguous()) for name, value in values.items()
    }
    start = time.perf_counter()
    # coreai-core 1.0.0b2's public call surface accepts the named tensor map
    # under `inputs`; later examples in coreai-models that splat kwargs do not
    # match this pinned runtime and are therefore not used here.
    output = await function(inputs=runtime_values)
    elapsed = time.perf_counter() - start
    converted = {
        name: torch.as_tensor(value.numpy().astype(np.float32)).contiguous()
        for name, value in output.items()
    }
    return converted, elapsed


def vae_descriptor_matches(component: str, descriptor: dict[str, Any]) -> bool:
    if component == "vae-encoder":
        expected_input = ("image", "float32", 4, [1, 3, -1, -1])
        expected_output = ("latent", "float32", 4, [1, 16, -1, -1])
    elif component == "vae-decoder":
        expected_input = ("latent", "float32", 4, [1, 16, -1, -1])
        expected_output = ("image", "float32", 4, [1, 3, -1, -1])
    else:
        raise ContractError(f"not a VAE component: {component}")
    observed_inputs = [
        (item["name"], item["dtype"], item["rank"], item["shape"])
        for item in descriptor["inputs"]
    ]
    observed_outputs = [
        (item["name"], item["dtype"], item["rank"], item["shape"])
        for item in descriptor["outputs"]
    ]
    return observed_inputs == [expected_input] and observed_outputs == [expected_output]


async def validate_vae(args: argparse.Namespace) -> dict[str, Any]:
    component = args.component
    source = Path(args.source).resolve()
    asset = Path(args.asset).resolve()
    source_files = verify_component_source(source, component)
    vae = _load_vae(source, torch.float32).to(args.reference_device).eval()
    wrapper: torch.nn.Module
    input_name: str
    output_name: str
    if component == "vae-encoder":
        wrapper = VAEEncoderWrapper(vae).eval()
        input_name, output_name = "image", "latent"
    else:
        wrapper = VAEDecoderWrapper(vae).eval()
        input_name, output_name = "latent", "image"

    prepared = []
    for width, height in args.shapes:
        reference_input = synthetic_image(width, height) if component == "vae-encoder" else synthetic_latent(width, height)
        with torch.inference_mode():
            expected = wrapper(reference_input.to(args.reference_device)).detach().cpu().float()
        prepared.append((width, height, reference_input, expected))
        if args.reference_device == "mps":
            torch.mps.empty_cache()
    del wrapper, vae
    gc.collect()
    if args.reference_device == "mps":
        torch.mps.empty_cache()

    function, descriptor, load_seconds = await load_function(asset, "main")
    descriptor_match = vae_descriptor_matches(component, descriptor)
    results = []
    for width, height, reference_input, expected in prepared:
        actual_outputs, first_seconds = await invoke(function, **{input_name: reference_input})
        repeated_outputs, repeat_seconds = await invoke(function, **{input_name: reference_input})
        if output_name not in actual_outputs:
            raise ContractError(f"Core AI output lacks {output_name!r}")
        actual = actual_outputs[output_name]
        repeated = repeated_outputs[output_name]
        if actual.shape != expected.shape:
            raise ContractError(f"{component} returned {tuple(actual.shape)}, expected {tuple(expected.shape)}")
        if not torch.isfinite(actual).all():
            raise ContractError(f"{component} returned non-finite values for {width}x{height}")
        observed = metrics(actual, expected)
        repeat_error = float((actual - repeated).abs().max())
        if component == "vae-encoder":
            passed = (
                observed["correlation"] >= 0.99999
                and observed["peakSignalToNoiseRatio"] >= 80.0
                and observed["rootMeanSquaredError"] <= 0.001
                and observed["maximumAbsoluteError"] <= 0.075
            )
        else:
            passed = observed["correlation"] >= 0.9999 and observed["maximumAbsoluteError"] <= 0.02
        passed = passed and repeat_error == 0.0 and descriptor_match
        results.append(
            {
                "width": width,
                "height": height,
                "outputShape": list(actual.shape),
                "finite": True,
                "metrics": observed,
                "repeatMaximumAbsoluteError": repeat_error,
                "firstInvocationSeconds": first_seconds,
                "repeatInvocationSeconds": repeat_seconds,
                "status": "passed" if passed else "failed",
            }
        )
        del reference_input, expected, actual, repeated
        if not passed and not args.keep_going:
            break

    return {
        "schemaVersion": "1.0.0",
        "component": component,
        "variant": "dynamic-512-2048",
        "asset": asset.name,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": sha256_tree(asset),
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "sourceFiles": source_files,
        "descriptor": descriptor,
        "descriptorMatch": descriptor_match,
        "system": _system_record(),
        "modelLoadSeconds": load_seconds,
        "results": results,
        "status": "passed" if len(results) == len(args.shapes) and all(item["status"] == "passed" for item in results) else "failed",
    }


def verify_tokenizer_source(source: Path) -> list[dict[str, Any]]:
    locked = {
        item["path"]: item
        for item in load_json(HERE / "source-lock.json")["publisherModel"]["files"]
    }
    results = []
    for relative in (
        "tokenizer/merges.txt",
        "tokenizer/tokenizer.json",
        "tokenizer/tokenizer_config.json",
        "tokenizer/vocab.json",
    ):
        path = source / relative
        item = locked[relative]
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"missing tokenizer source: {relative}")
        if "size" in item and path.stat().st_size != item["size"]:
            raise ContractError(f"tokenizer source size mismatch: {relative}")
        digest = sha256_file(path)
        if digest != item["sha256"]:
            raise ContractError(f"tokenizer source digest mismatch: {relative}")
        results.append({"path": relative, "sha256": digest, "size": path.stat().st_size})
    return results


def prompt_descriptor_matches(descriptor: dict[str, Any]) -> bool:
    return (
        [
            (item["name"], item["dtype"], item["rank"], item["shape"])
            for item in descriptor["inputs"]
        ]
        == [
            ("input_ids", "int32", 2, [1, 512]),
            ("attention_mask", "bool", 2, [1, 512]),
        ]
        and [
            (item["name"], item["dtype"], item["rank"], item["shape"])
            for item in descriptor["outputs"]
        ]
        == [("prompt_embeddings", "float16", 3, [1, 512, 2560])]
    )


async def validate_prompt_encoder(args: argparse.Namespace) -> dict[str, Any]:
    from transformers import AutoTokenizer

    source = Path(args.source).resolve()
    asset = Path(args.asset).resolve()
    source_files = verify_component_source(source, "prompt-encoder")
    tokenizer_files = verify_tokenizer_source(source)
    tokenizer = AutoTokenizer.from_pretrained(source / "tokenizer", local_files_only=True)
    prompts = [
        "A red ceramic teapot on a walnut table, soft window light.",
        "竖幅山水画，雨后的石桥与薄雾，细腻笔触。",
    ]
    prepared = []
    for prompt in prompts:
        formatted = tokenizer.apply_chat_template(
            [{"role": "user", "content": prompt}], tokenize=False,
            add_generation_prompt=True, enable_thinking=True,
        )
        encoded = tokenizer(
            formatted, padding="max_length", max_length=512,
            truncation=True, return_tensors="pt",
        )
        prepared.append(
            {
                "prompt": prompt,
                "formatted": formatted,
                "input_ids": encoded.input_ids.to(torch.int32),
                "attention_mask": encoded.attention_mask.bool(),
            }
        )

    reference_model = _load_prompt_encoder(source, torch.float16).to(args.reference_device).eval()
    reference_wrapper = PromptEncoderWrapper(reference_model).eval()
    expected_outputs = []
    with torch.inference_mode():
        for item in prepared:
            expected_outputs.append(
                reference_wrapper(
                    item["input_ids"].to(args.reference_device),
                    item["attention_mask"].to(args.reference_device),
                ).detach().cpu().float()
            )
    del reference_wrapper, reference_model
    gc.collect()
    if args.reference_device == "mps":
        torch.mps.empty_cache()

    function, descriptor, load_seconds = await load_function(asset, "main")
    descriptor_match = prompt_descriptor_matches(descriptor)
    results = []
    for item, expected in zip(prepared, expected_outputs):
        values = {
            "input_ids": item["input_ids"],
            "attention_mask": item["attention_mask"],
        }
        output, first_seconds = await invoke(function, **values)
        repeated, repeat_seconds = await invoke(function, **values)
        actual = output["prompt_embeddings"]
        repeat_error = float((actual - repeated["prompt_embeddings"]).abs().max())
        # The publisher pipeline discards padding immediately. Parity is
        # therefore evaluated only over the active hidden states that feed the
        # denoiser; inactive positions remain covered by finiteness and exact
        # repeatability checks.
        observed = metrics(actual[:, item["attention_mask"][0]], expected[:, item["attention_mask"][0]])
        finite = bool(torch.isfinite(actual).all())
        passed = (
            descriptor_match and finite and actual.shape == expected.shape
            and observed["correlation"] >= 0.999
            and observed["peakSignalToNoiseRatio"] >= 40.0
            and repeat_error == 0.0
        )
        ids_bytes = item["input_ids"].numpy().astype("<i4", copy=False).tobytes()
        results.append(
            {
                "promptSHA256": hashlib.sha256(item["prompt"].encode("utf-8")).hexdigest(),
                "formattedPromptSHA256": hashlib.sha256(item["formatted"].encode("utf-8")).hexdigest(),
                "inputIDsSHA256": hashlib.sha256(ids_bytes).hexdigest(),
                "activeTokens": int(item["attention_mask"].sum()),
                "outputShape": list(actual.shape),
                "finite": finite,
                "metrics": observed,
                "repeatMaximumAbsoluteError": repeat_error,
                "firstInvocationSeconds": first_seconds,
                "repeatInvocationSeconds": repeat_seconds,
                "status": "passed" if passed else "failed",
            }
        )
        if not passed and not args.keep_going:
            break
    return {
        "schemaVersion": "1.0.0", "component": "prompt-encoder",
        "variant": "fixed-512-tokens", "asset": asset.name,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": sha256_tree(asset),
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "sourceFiles": source_files, "tokenizerFiles": tokenizer_files,
        "descriptor": descriptor, "descriptorMatch": descriptor_match,
        "system": _system_record(), "modelLoadSeconds": load_seconds,
        "results": results,
        "status": "passed" if len(results) == len(prepared) and all(item["status"] == "passed" for item in results) else "failed",
    }


async def validate_denoiser_probe(args: argparse.Namespace) -> dict[str, Any]:
    asset = Path(args.asset).resolve()
    function, descriptor, load_seconds = await load_function(asset, "main")
    dtype = dtype_for_precision(args.precision)
    transformer = _tiny_denoiser(dtype)
    wrapper = DenoiserWrapper(transformer).eval()
    publisher_module, publisher_record = load_publisher_transformer_module(
        Path(args.publisher_reference).resolve()
    )
    publisher = publisher_module.ZImageTransformer2DModel(
        all_patch_size=(2,), all_f_patch_size=(1,), in_channels=16,
        dim=128, n_layers=1, n_refiner_layers=1, n_heads=1, n_kv_heads=1,
        cap_feat_dim=64, axes_dims=[32, 48, 48], axes_lens=[1536, 512, 512],
    ).to(dtype).eval()
    incompatible = publisher.load_state_dict(transformer.state_dict(), strict=True)
    if incompatible.missing_keys or incompatible.unexpected_keys:
        raise ContractError("tiny publisher state mapping is not exact")
    expected_inputs = (
        ("image_tokens", args.precision, 3, [1, -1, 64]),
        ("image_padding_mask", "bool", 2, [1, -1]),
        ("prompt_embeddings", args.precision, 3, [1, -1, 64]),
        ("prompt_padding_mask", "bool", 2, [1, -1]),
        ("prompt_attention_mask", "bool", 2, [1, -1]),
        ("timestep", "float32", 1, [1]),
        ("image_rope_cos", "float32", 3, [1, -1, 64]),
        ("image_rope_sin", "float32", 3, [1, -1, 64]),
        ("prompt_rope_cos", "float32", 3, [1, -1, 64]),
        ("prompt_rope_sin", "float32", 3, [1, -1, 64]),
    )
    descriptor_match = [
        (item["name"], item["dtype"], item["rank"], item["shape"])
        for item in descriptor["inputs"]
    ] == list(expected_inputs) and [
        (item["name"], item["dtype"], item["rank"], item["shape"])
        for item in descriptor["outputs"]
    ] == [("noise_prediction", args.precision, 3, [1, -1, 64])]
    results = []
    cases = [(width, height, 32) for width, height in args.shapes]
    cases.extend(
        (512, 512, bucket) for bucket in args.prompt_buckets if bucket != 32
    )
    for width, height, bucket in cases:
        valid_prompt_tokens = max(1, bucket - 15)
        torch.manual_seed(11 + bucket)
        latents = (
            torch.randn(1, 16, height // 8, width // 8, dtype=torch.float32) * 0.1
        ).to(dtype)
        image_tokens, image_padding = patchify_latents(latents)
        prompt = (
            torch.randn(1, bucket, 64, dtype=torch.float32) * 0.1
        ).to(dtype)
        prompt_padding = (
            torch.arange(bucket).unsqueeze(0) >= valid_prompt_tokens
        )
        prompt_active = torch.ones(1, bucket, dtype=torch.bool)
        _, _, _, rope_cos, rope_sin = make_rope(
            height // 16,
            width // 16,
            valid_prompt_tokens,
            bucket,
            maximum_prompt_tokens=bucket,
        )
        image_length = image_tokens.shape[1]
        values = {
            "image_tokens": image_tokens,
            "image_padding_mask": image_padding,
            "prompt_embeddings": prompt,
            "prompt_padding_mask": prompt_padding,
            "prompt_attention_mask": prompt_active,
            "timestep": torch.tensor([0.5], dtype=torch.float32),
            "image_rope_cos": rope_cos[:image_length].unsqueeze(0).float(),
            "image_rope_sin": rope_sin[:image_length].unsqueeze(0).float(),
            "prompt_rope_cos": rope_cos[image_length:].unsqueeze(0).float(),
            "prompt_rope_sin": rope_sin[image_length:].unsqueeze(0).float(),
        }
        with torch.inference_mode():
            adapter_output = wrapper(**values).float()
            publisher_output = publisher(
                [latents[0].unsqueeze(1)],
                values["timestep"],
                [prompt[0, :valid_prompt_tokens]],
            )[0][0]
            publisher_tokens, _ = patchify_latents(
                publisher_output.squeeze(1).unsqueeze(0)
            )
            publisher_tokens = publisher_tokens.float()
        output, elapsed = await invoke(function, **values)
        repeated, repeat_elapsed = await invoke(function, **values)
        actual = output["noise_prediction"]
        repeat_maximum_error = repeat_error(
            actual, repeated["noise_prediction"]
        )
        token_count = (width // 16) * (height // 16)
        adapter_metrics = metrics(adapter_output[:, :token_count], publisher_tokens[:, :token_count])
        observed = metrics(actual[:, :token_count], publisher_tokens[:, :token_count])
        coreai_to_adapter = metrics(
            actual[:, :token_count], adapter_output[:, :token_count]
        )
        passed = (
            actual.shape == adapter_output.shape
            and torch.isfinite(actual).all()
            and adapter_metrics["peakSignalToNoiseRatio"] >= 60.0
            and adapter_metrics["correlation"] >= 0.99999
            and observed["peakSignalToNoiseRatio"] >= 40.0
            and observed["correlation"] >= 0.999
            and repeat_maximum_error == 0.0
            and descriptor_match
        )
        results.append(
            {
                "width": width, "height": height, "promptBucket": bucket,
                "outputShape": list(actual.shape),
                "adapterToPublisherMetrics": adapter_metrics,
                "coreAIToPublisherMetrics": observed,
                "coreAIToAdapterMetrics": coreai_to_adapter,
                "repeatMaximumAbsoluteError": repeat_maximum_error,
                "invocationSeconds": elapsed,
                "repeatInvocationSeconds": repeat_elapsed,
                "status": "passed" if passed else "failed",
            }
        )
        if not passed and not args.keep_going:
            break
    return {
        "schemaVersion": "1.0.0", "component": "denoiser", "variant": "tiny-probe",
        "asset": asset.name, "precision": args.precision,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": sha256_tree(asset),
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "publisherReference": publisher_record,
        "descriptor": descriptor, "descriptorMatch": descriptor_match,
        "system": _system_record(),
        "modelLoadSeconds": load_seconds, "results": results,
        "status": "passed" if len(results) == len(cases) and all(item["status"] == "passed" for item in results) else "failed",
    }


def denoiser_case(
    width: int,
    height: int,
    bucket: int,
    dtype: torch.dtype,
    prompt_capacity: int = 512,
) -> tuple[dict[str, torch.Tensor], torch.Tensor, int]:
    if bucket > prompt_capacity:
        raise ContractError("prompt bucket exceeds the diagnostic prompt capacity")
    valid_prompt_tokens = max(1, bucket - 15)
    generator = torch.Generator(device="cpu").manual_seed(width * 100_003 + height * 101 + bucket)
    latents = (
        torch.randn(
            1, 16, height // 8, width // 8,
            dtype=torch.float32, generator=generator,
        )
        * 0.1
    ).to(dtype)
    image_tokens, image_padding = patchify_latents(latents)
    prompt = (
        torch.randn(1, 512, 2560, dtype=torch.float32, generator=generator) * 0.1
    )[:, :prompt_capacity].to(dtype)
    prompt_padding = torch.arange(prompt_capacity).unsqueeze(0) >= valid_prompt_tokens
    prompt_active = torch.arange(prompt_capacity).unsqueeze(0) < bucket
    _, _, _, rope_cos, rope_sin = make_rope(
        height // 16, width // 16, valid_prompt_tokens, bucket,
        maximum_prompt_tokens=prompt_capacity,
    )
    values = {
        "image_tokens": image_tokens,
        "image_padding_mask": image_padding,
        "prompt_embeddings": prompt,
        "prompt_padding_mask": prompt_padding,
        "prompt_attention_mask": prompt_active,
        "timestep": torch.tensor([0.5], dtype=torch.float32),
        "image_rope_cos": rope_cos[: image_tokens.shape[1]].unsqueeze(0).float(),
        "image_rope_sin": rope_sin[: image_tokens.shape[1]].unsqueeze(0).float(),
        "prompt_rope_cos": rope_cos[image_tokens.shape[1] :].unsqueeze(0).float(),
        "prompt_rope_sin": rope_sin[image_tokens.shape[1] :].unsqueeze(0).float(),
    }
    return values, latents, valid_prompt_tokens


async def validate_denoiser(args: argparse.Namespace) -> dict[str, Any]:
    import coreai.runtime as runtime

    source = Path(args.source).resolve()
    asset = Path(args.asset).resolve() if args.asset else None
    source_files = verify_component_source(source, "denoiser")
    dtype = dtype_for_precision(args.precision)
    cases = [(width, height, 32) for width, height in args.shapes]
    cases.extend((512, 512, bucket) for bucket in args.prompt_buckets if bucket != 32)
    prepared: list[dict[str, Any]] = []
    for width, height, bucket in cases:
        prompt_capacity = args.adapter_prompt_capacity if args.eager_only else bucket
        values, latents, valid = denoiser_case(
            width, height, bucket, dtype, prompt_capacity
        )
        prepared.append(
            {
                "width": width,
                "height": height,
                "bucket": bucket,
                "values": values,
                "latents": latents,
                "validPromptTokens": valid,
                "validImageTokens": (width // 16) * (height // 16),
            }
        )

    publisher_reference = Path(args.publisher_reference).resolve()
    publisher_model, publisher_record = load_publisher_denoiser(
        source, publisher_reference, dtype
    )
    publisher_model.to(args.reference_device)
    with torch.inference_mode():
        for item in prepared:
            try:
                device_values = {
                    name: value.to(args.reference_device)
                    for name, value in item["values"].items()
                }
                publisher = publisher_model(
                    [item["latents"][0].unsqueeze(1).to(args.reference_device)],
                    device_values["timestep"],
                    [
                        device_values["prompt_embeddings"][
                            0, : item["validPromptTokens"]
                        ]
                    ],
                )[0][0]
            except RuntimeError as error:
                raise ContractError(
                    "pinned publisher denoiser failed at "
                    f"{item['width']}x{item['height']}, prompt bucket {item['bucket']}: {error}"
                ) from error
            publisher_tokens, _ = patchify_latents(
                publisher.squeeze(1).unsqueeze(0).detach().cpu()
            )
            item["expected"] = publisher_tokens.float()
            item["expectedShape"] = list(publisher_tokens.shape)
            item["publisherSummary"] = tensor_summary(
                publisher_tokens[:, : item["validImageTokens"]]
            )
    del publisher_model
    gc.collect()
    if args.reference_device == "mps":
        torch.mps.empty_cache()

    adapter_model = _load_denoiser(source, dtype).to(args.reference_device).eval()
    adapter = DenoiserWrapper(adapter_model).eval()
    with torch.inference_mode():
        for item in prepared:
            item["adapterMetrics"] = None
            item["adapterSummary"] = None
            if not args.skip_adapter_check:
                device_values = {
                    name: value.to(args.reference_device)
                    for name, value in item["values"].items()
                }
                adapter_output = adapter(**device_values).detach().cpu().float()
                valid_image_tokens = item["validImageTokens"]
                item["adapterMetrics"] = metrics(
                    adapter_output[:, :valid_image_tokens],
                    item["expected"][:, :valid_image_tokens],
                )
                item["adapterSummary"] = tensor_summary(
                    adapter_output[:, :valid_image_tokens]
                )
    del adapter, adapter_model
    gc.collect()
    if args.reference_device == "mps":
        torch.mps.empty_cache()

    if args.eager_only:
        results = []
        for item in prepared:
            observed = item["adapterMetrics"]
            passed = (
                observed is not None
                and observed["peakSignalToNoiseRatio"] >= 60.0
                and observed["correlation"] >= 0.99999
            )
            results.append(
                {
                    "width": item["width"],
                    "height": item["height"],
                    "promptBucket": item["bucket"],
                    "validImageTokens": item["validImageTokens"],
                    "publisherOutput": item["publisherSummary"],
                    "adapterOutput": item["adapterSummary"],
                    "adapterToPublisherMetrics": observed,
                    "status": "passed" if passed else "failed",
                }
            )
        return {
            "schemaVersion": "1.0.0",
            "component": "denoiser",
            "variant": "full-eager-adapter-check",
            "asset": None,
            "precision": args.precision,
            "adapterPromptCapacity": args.adapter_prompt_capacity,
            "referenceImplementation": "pinned Tongyi-MAI/Z-Image ZImageTransformer2DModel.forward",
            "publisherReference": publisher_record,
            "adapterImplementation": "DenoiserWrapper",
            "sourceFiles": source_files,
            "system": _system_record(),
            "results": results,
            "status": (
                "passed" if results and all(item["status"] == "passed" for item in results)
                else "failed"
            ),
        }

    assert asset is not None
    load_start = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - load_start
    expected_functions = {"main"}
    if set(model.function_names) != expected_functions:
        raise ContractError(f"denoiser function set mismatch: {model.function_names}")
    function = model.load_function("main")
    descriptors = {"main": describe_function(function)}
    expected_input_types = {
        "image_tokens": args.precision,
        "image_padding_mask": "bool",
        "prompt_embeddings": args.precision,
        "prompt_padding_mask": "bool",
        "prompt_attention_mask": "bool",
        "timestep": "float32",
        "image_rope_cos": "float32",
        "image_rope_sin": "float32",
        "prompt_rope_cos": "float32",
        "prompt_rope_sin": "float32",
    }
    expected_input_ranks = {
        "image_tokens": 3,
        "image_padding_mask": 2,
        "prompt_embeddings": 3,
        "prompt_padding_mask": 2,
        "prompt_attention_mask": 2,
        "timestep": 1,
        "image_rope_cos": 3,
        "image_rope_sin": 3,
        "prompt_rope_cos": 3,
        "prompt_rope_sin": 3,
    }
    expected_input_shapes = {
        "image_tokens": [1, -1, 64],
        "image_padding_mask": [1, -1],
        "prompt_embeddings": [1, -1, 2560],
        "prompt_padding_mask": [1, -1],
        "prompt_attention_mask": [1, -1],
        "timestep": [1],
        "image_rope_cos": [1, -1, 64],
        "image_rope_sin": [1, -1, 64],
        "prompt_rope_cos": [1, -1, 64],
        "prompt_rope_sin": [1, -1, 64],
    }
    described_inputs = descriptors["main"]["inputs"]
    described_outputs = descriptors["main"]["outputs"]
    descriptor_match = (
        [item["name"] for item in described_inputs] == list(expected_input_types)
        and all(
            item["dtype"] == expected_input_types[item["name"]]
            and item["rank"] == expected_input_ranks[item["name"]]
            and item["shape"] == expected_input_shapes[item["name"]]
            for item in described_inputs
        )
        and [
            (item["name"], item["dtype"], item["rank"], item["shape"])
            for item in described_outputs
        ]
        == [("noise_prediction", args.precision, 3, [1, -1, 64])]
    )

    results = []
    for item in prepared:
        output, first_seconds = await invoke(function, **item["values"])
        repeated, repeat_seconds = await invoke(function, **item["values"])
        actual = output["noise_prediction"]
        expected = item["expected"]
        finite = bool(torch.isfinite(actual).all())
        token_count = item["validImageTokens"]
        observed = (
            metrics(actual[:, :token_count], expected[:, :token_count])
            if finite else None
        )
        repeated_error = repeat_error(actual, repeated["noise_prediction"])
        adapter_ok = args.skip_adapter_check or (
            item["adapterMetrics"] is not None
            and item["adapterMetrics"]["peakSignalToNoiseRatio"] >= 60.0
            and item["adapterMetrics"]["correlation"] >= 0.99999
        )
        passed = (
            list(actual.shape) == item["expectedShape"] and finite and observed is not None
            and observed["peakSignalToNoiseRatio"] >= 40.0
            and observed["correlation"] >= 0.999
            and repeated_error == 0.0 and adapter_ok and descriptor_match
        )
        results.append(
            {
                "width": item["width"], "height": item["height"],
                "promptBucket": item["bucket"], "outputShape": list(actual.shape),
                "validImageTokens": token_count,
                "finite": finite,
                "publisherOutput": item["publisherSummary"],
                "coreAIOutput": tensor_summary(actual[:, :token_count]),
                "adapterToPublisherMetrics": item["adapterMetrics"],
                "coreAIToPublisherMetrics": observed,
                "repeatMaximumAbsoluteError": repeated_error,
                "firstInvocationSeconds": first_seconds,
                "repeatInvocationSeconds": repeat_seconds,
                "status": "passed" if passed else "failed",
            }
        )
        if not passed and not args.keep_going:
            break
    return {
        "schemaVersion": "1.0.0", "component": "denoiser",
        "variant": "dynamic-image-dynamic-prompt-bucket", "asset": asset.name,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": sha256_tree(asset),
        "precision": args.precision,
        "computationPrecision": f"{args.precision}-with-float32-timestep-and-rope",
        "attentionAccumulation": "model-precision",
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "specialization": specialization_record(runtime),
        "adapterCheckSkipped": args.skip_adapter_check,
        "referenceImplementation": "pinned Tongyi-MAI/Z-Image ZImageTransformer2DModel.forward",
        "publisherReference": publisher_record,
        "sourceFiles": source_files, "descriptors": descriptors,
        "descriptorMatch": descriptor_match,
        "system": _system_record(), "modelLoadSeconds": load_seconds,
        "results": results,
        "status": "passed" if len(results) == len(prepared) and all(item["status"] == "passed" for item in results) else "failed",
    }


async def probe_denoiser_coreai(args: argparse.Namespace) -> dict[str, Any]:
    import coreai.runtime as runtime

    asset = Path(args.asset).resolve()
    started = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - started
    if set(model.function_names) != {"main"}:
        raise ContractError(f"denoiser function set mismatch: {model.function_names}")
    function = model.load_function("main")
    dtype = dtype_for_precision(args.precision)
    results = []
    for width, height in args.shapes:
        values, _latents, _valid = denoiser_case(
            width, height, 32, dtype, prompt_capacity=32
        )
        output, first_seconds = await invoke(function, **values)
        repeated, repeat_seconds = await invoke(function, **values)
        actual = output["noise_prediction"]
        repeated_error = repeat_error(actual, repeated["noise_prediction"])
        passed = (
            actual.shape == values["image_tokens"].shape
            and bool(torch.isfinite(actual).all()) and repeated_error == 0.0
        )
        results.append(
            {
                "width": width, "height": height, "promptBucket": 32,
                "outputShape": list(actual.shape), "finite": bool(torch.isfinite(actual).all()),
                "coreAIOutput": tensor_summary(actual),
                "repeatMaximumAbsoluteError": repeated_error,
                "firstInvocationSeconds": first_seconds,
                "repeatInvocationSeconds": repeat_seconds,
                "status": "passed" if passed else "failed",
            }
        )
    return {
        "schemaVersion": "1.0.0", "component": "denoiser",
        "variant": "dynamic-image-dynamic-prompt-bucket", "probeOnly": True,
        "asset": asset.name, "precision": args.precision,
        "assetDigestAlgorithm": "sha256-tree-v1", "assetDigest": sha256_tree(asset),
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "specialization": specialization_record(runtime),
        "descriptor": describe_function(function),
        "system": _system_record(), "modelLoadSeconds": load_seconds,
        "results": results,
        "status": "passed" if all(item["status"] == "passed" for item in results) else "failed",
    }


async def run(args: argparse.Namespace) -> int:
    started = time.perf_counter()
    started_utc = datetime.now(UTC).isoformat()
    if args.component in {"vae-encoder", "vae-decoder"}:
        report = await validate_vae(args)
    elif args.component == "prompt-encoder":
        report = await validate_prompt_encoder(args)
    elif args.component == "denoiser":
        report = await (probe_denoiser_coreai(args) if args.coreai_only else validate_denoiser(args))
    else:
        report = await validate_denoiser_probe(args)
    report["peakResidentBytes"] = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    report["sourceLockSHA256"] = sha256_file(HERE / "source-lock.json")
    report["toolSHA256"] = sha256_file(Path(__file__).resolve())
    report["commandArguments"] = sys.argv[1:]
    report["startedUTC"] = started_utc
    report["finishedUTC"] = datetime.now(UTC).isoformat()
    report["elapsedSeconds"] = time.perf_counter() - started
    if args.report:
        write_atomic_new_json(Path(args.report), report)
    print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("prompt-encoder", "denoiser", "vae-encoder", "vae-decoder", "denoiser-probe"))
    parser.add_argument("--asset")
    parser.add_argument("--source", help="locked publisher snapshot; required for VAE checks")
    parser.add_argument(
        "--publisher-reference",
        help="pinned Tongyi-MAI/Z-Image checkout; required for full denoiser parity",
    )
    parser.add_argument("--shapes", nargs="+", type=parse_shape, default=[(512, 512), (1280, 720), (720, 1280), (1024, 1024)])
    parser.add_argument("--reference-device", choices=("cpu", "mps"), default="mps")
    parser.add_argument("--keep-going", action="store_true")
    parser.add_argument("--skip-adapter-check", action="store_true", help="diagnostic only; a complete report must retain the adapter check")
    diagnostic_mode = parser.add_mutually_exclusive_group()
    diagnostic_mode.add_argument("--coreai-only", action="store_true", help="diagnostic only: check native Core AI execution without claiming publisher parity")
    diagnostic_mode.add_argument(
        "--eager-only",
        action="store_true",
        help="full denoiser only: compare the publisher forward with the tensor adapter without loading Core AI",
    )
    parser.add_argument(
        "--precision",
        choices=("float16", "bfloat16", "float32"),
        default="bfloat16",
        help="denoiser model and numeric tensor precision",
    )
    parser.add_argument(
        "--adapter-prompt-capacity",
        type=int,
        choices=(32, 512),
        default=512,
        help="eager-only fixed-capacity diagnostic topology; the converted denoiser uses a dynamic 32-512 prompt axis",
    )
    parser.add_argument(
        "--prompt-buckets", nargs="*", type=parse_prompt_bucket, default=[256, 512],
        help="full denoiser only: additional 32-token prompt-bucket capacities checked at 512x512",
    )
    parser.add_argument("--report")
    return parser


def main() -> int:
    started = time.perf_counter()
    started_utc = datetime.now(UTC).isoformat()
    args = build_parser().parse_args()
    try:
        for attribute in ("asset", "source", "publisher_reference"):
            value = getattr(args, attribute)
            if value:
                setattr(args, attribute, str(guarded_resolve(Path(value))))
        if args.report:
            args.report = str(outside_checkout(Path(args.report)))
            prepare_atomic_new_json(
                Path(args.report), "component validation report"
            )
    except (ContractError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.eager_only and args.component != "denoiser":
        print("error: --eager-only is supported only for full denoiser validation", file=sys.stderr)
        return 2
    if not args.eager_only and not args.asset:
        print("error: --asset is required unless --eager-only is selected", file=sys.stderr)
        return 2
    coreai_only_denoiser = args.component == "denoiser" and args.coreai_only
    if (
        args.component in {"prompt-encoder", "denoiser", "vae-encoder", "vae-decoder"}
        and not coreai_only_denoiser
        and not args.source
    ):
        print(f"error: --source is required for {args.component} validation", file=sys.stderr)
        return 2
    if (
        args.component in {"denoiser", "denoiser-probe"}
        and not coreai_only_denoiser
        and not args.publisher_reference
    ):
        print("error: --publisher-reference is required for denoiser validation", file=sys.stderr)
        return 2
    try:
        return asyncio.run(run(args))
    except (ContractError, RuntimeError, OSError, ValueError) as error:
        if args.report:
            asset = Path(args.asset).resolve() if args.asset else None
            asset_digest = (
                sha256_tree(asset)
                if asset is not None and asset.is_dir()
                else None
            )
            failure = {
                "schemaVersion": "1.0.0",
                "component": args.component,
                "variant": (
                    "dynamic-image-dynamic-prompt-bucket"
                    if args.component == "denoiser"
                    else "tiny-probe"
                    if args.component == "denoiser-probe"
                    else None
                ),
                "status": "failed",
                "asset": None if asset is None else asset.name,
                "assetDigestAlgorithm": (
                    "sha256-tree-v1" if asset_digest is not None else None
                ),
                "assetDigest": asset_digest,
                "precision": args.precision,
                "computationPrecision": (
                    f"{args.precision}-with-float32-timestep-and-rope"
                    if args.component in {"denoiser", "denoiser-probe"}
                    else args.precision
                ),
                "attentionAccumulation": (
                    "model-precision"
                    if args.component in {"denoiser", "denoiser-probe"}
                    else None
                ),
                "computePolicy": os.environ.get(
                    "PIXELTJE_COREAI_COMPUTE", "gpu-preferred"
                ),
                "adapterCheckSkipped": args.skip_adapter_check,
                "descriptorMatch": False,
                "referenceImplementation": (
                    "pinned Tongyi-MAI/Z-Image ZImageTransformer2DModel.forward"
                    if args.component in {"denoiser", "denoiser-probe"}
                    else None
                ),
                "results": [
                    {
                        "status": "failed",
                        "errorType": type(error).__name__,
                        "error": str(error),
                        "requestedShapes": [list(shape) for shape in args.shapes],
                        "requestedPromptBuckets": args.prompt_buckets,
                    }
                ],
                "peakResidentBytes": int(
                    resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                ),
                "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
                "toolSHA256": sha256_file(Path(__file__).resolve()),
                "commandArguments": sys.argv[1:],
                "startedUTC": started_utc,
                "finishedUTC": datetime.now(UTC).isoformat(),
                "elapsedSeconds": time.perf_counter() - started,
                "system": _system_record(),
            }
            try:
                write_atomic_new_json(Path(args.report), failure)
            except (OSError, ValueError) as report_error:
                print(f"error: could not write failure report: {report_error}", file=sys.stderr)
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
