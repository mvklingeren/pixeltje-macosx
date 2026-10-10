#!/usr/bin/env python3
"""End-to-end publisher/Core AI parity for the text-to-image pipeline.

Large learned stages are loaded sequentially so the test does not require the
publisher and Core AI copies of a component to be resident together.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import resource
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
import torch

from export_components import _load_prompt_encoder, _load_vae, make_rope
from glue import decode_vae_affine, flow_match_schedule, normalized_timestep
from pixaimodel import (
    ContractError,
    HERE,
    audit_source,
    guarded_resolve,
    outside_checkout,
    sha256_file,
    sha256_tree,
    verify_glue_test_log,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json
from validate_components import (
    invoke,
    load_publisher_denoiser,
    metrics,
    patchify_latents,
    unpatchify_tokens,
    validation_specialization_options,
    verify_tokenizer_source,
)
from validate_vae_tiling import tiled_coreai_decoder


REQUIRED_SHAPES = (
    (512, 512), (1024, 1024), (1280, 720), (720, 1280),
    (2048, 1152), (1152, 2048), (2048, 2048),
)
DENOISER_DTYPE = torch.bfloat16
PIPELINE_COMPONENT_ARGUMENTS = {
    "prompt-encoder": "prompt_encoder",
    "denoiser": "denoiser",
    "vae-decoder": "vae_decoder",
}


def component_asset_bindings(args: argparse.Namespace) -> dict[str, dict[str, str]]:
    bindings = {}
    for component_id, argument in PIPELINE_COMPONENT_ARGUMENTS.items():
        asset = Path(getattr(args, argument)).resolve()
        if not asset.is_dir() or asset.is_symlink():
            raise ContractError(f"invalid pipeline component asset: {asset}")
        bindings[component_id] = {
            "assetDigestAlgorithm": "sha256-tree-v1",
            "assetDigest": sha256_tree(asset),
        }
    return bindings


def release_mps() -> None:
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()


def system_record() -> dict[str, str]:
    return {
        "macOS": subprocess.run(["sw_vers", "-productVersion"], check=True, capture_output=True, text=True).stdout.strip(),
        "build": subprocess.run(["sw_vers", "-buildVersion"], check=True, capture_output=True, text=True).stdout.strip(),
        "machine": platform.machine(),
        "coreAIRuntime": importlib.metadata.version("coreai-core"),
        "python": platform.python_version(),
        "torch": torch.__version__,
        "coreAITorch": importlib.metadata.version("coreai-torch"),
    }


def initial_noise(width: int, height: int, seed: int) -> torch.Tensor:
    generator = torch.Generator(device="cpu").manual_seed(seed)
    return torch.randn(1, 16, height // 8, width // 8, generator=generator, dtype=torch.float32)


def prompt_inputs(source: Path, prompt: str) -> tuple[torch.Tensor, torch.Tensor, dict[str, Any]]:
    from transformers import AutoTokenizer

    verify_tokenizer_source(source)
    tokenizer = AutoTokenizer.from_pretrained(source / "tokenizer", local_files_only=True)
    formatted = tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt}], tokenize=False,
        add_generation_prompt=True, enable_thinking=True,
    )
    encoded = tokenizer(
        formatted, padding="max_length", max_length=512,
        truncation=True, return_tensors="pt",
    )
    details = {
        "promptSHA256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
        "formattedPromptSHA256": hashlib.sha256(formatted.encode("utf-8")).hexdigest(),
        "activeTokens": int(encoded.attention_mask.sum()),
    }
    return encoded.input_ids.to(torch.int32), encoded.attention_mask.bool(), details


def publisher_prompt(source: Path, ids: torch.Tensor, mask: torch.Tensor, device: str) -> torch.Tensor:
    model = _load_prompt_encoder(source, torch.float16).to(device).eval()
    with torch.inference_mode():
        result = model(
            input_ids=ids.to(device=device, dtype=torch.int64),
            attention_mask=mask.to(device), output_hidden_states=True,
        ).hidden_states[-2][0, mask[0]].detach().cpu().half()
    del model
    release_mps()
    return result


async def coreai_prompt(asset: Path, ids: torch.Tensor, mask: torch.Tensor) -> tuple[torch.Tensor, float, float]:
    import coreai.runtime as runtime

    start = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - start
    function = model.load_function("main")
    output, invoke_seconds = await invoke(function, input_ids=ids, attention_mask=mask)
    result = output["prompt_embeddings"][0, mask[0]].half()
    del function, model
    release_mps()
    return result, load_seconds, invoke_seconds


def denoise_publisher(
    source: Path,
    publisher_reference: Path,
    prompts: torch.Tensor,
    noises: dict[tuple[int, int], torch.Tensor],
    device: str,
) -> tuple[
    dict[tuple[int, int], torch.Tensor],
    dict[tuple[int, int], list[float]],
    dict[str, Any],
]:
    model, publisher_record = load_publisher_denoiser(
        source, publisher_reference, DENOISER_DTYPE
    )
    model.to(device)
    timesteps, sigmas = flow_match_schedule(9)
    outputs = {}
    durations = {}
    with torch.inference_mode():
        for (width, height), starting in noises.items():
            latent = starting.clone()
            shape_durations = []
            for index, scheduler_timestep in enumerate(timesteps):
                delta = float(sigmas[index + 1] - sigmas[index])
                if delta == 0.0:
                    continue
                started = time.perf_counter()
                typed = latent.to(device=device, dtype=DENOISER_DTYPE)
                prediction = model(
                    [typed[0].unsqueeze(1)],
                    torch.tensor(
                        [normalized_timestep(float(scheduler_timestep))],
                        device=device,
                        dtype=torch.float32,
                    ),
                    [prompts.to(device=device, dtype=DENOISER_DTYPE)],
                )[0][0]
                noise = -prediction.squeeze(1).unsqueeze(0).float().cpu()
                latent = latent + delta * noise
                shape_durations.append(time.perf_counter() - started)
            outputs[(width, height)] = latent
            durations[(width, height)] = shape_durations
    del model
    release_mps()
    return outputs, durations, publisher_record


def denoiser_values(latent: torch.Tensor, prompts: torch.Tensor, scheduler_timestep: float) -> tuple[int, dict[str, torch.Tensor]]:
    height, width = latent.shape[2] * 8, latent.shape[3] * 8
    active = prompts.shape[0]
    bucket = min(512, max(32, math.ceil(active / 32) * 32))
    padded_prompt = torch.zeros(1, bucket, 2560, dtype=DENOISER_DTYPE)
    padded_prompt[0, :active] = prompts[:bucket].to(DENOISER_DTYPE)
    image_tokens, image_padding = patchify_latents(latent.to(DENOISER_DTYPE))
    prompt_padding = torch.arange(bucket).unsqueeze(0) >= active
    prompt_attention = torch.ones(1, bucket, dtype=torch.bool)
    _, _, _, rope_cos, rope_sin = make_rope(
        height // 16, width // 16, active, bucket, maximum_prompt_tokens=bucket,
    )
    image_length = image_tokens.shape[1]
    return bucket, {
        "image_tokens": image_tokens,
        "image_padding_mask": image_padding,
        "prompt_embeddings": padded_prompt,
        "prompt_padding_mask": prompt_padding,
        "prompt_attention_mask": prompt_attention,
        "timestep": torch.tensor(
            [normalized_timestep(scheduler_timestep)], dtype=torch.float32
        ),
        "image_rope_cos": rope_cos[:image_length].unsqueeze(0).float(),
        "image_rope_sin": rope_sin[:image_length].unsqueeze(0).float(),
        "prompt_rope_cos": rope_cos[image_length:].unsqueeze(0).float(),
        "prompt_rope_sin": rope_sin[image_length:].unsqueeze(0).float(),
    }


async def denoise_coreai(asset: Path, prompts: torch.Tensor, noises: dict[tuple[int, int], torch.Tensor]) -> tuple[dict[tuple[int, int], torch.Tensor], dict[str, Any]]:
    import coreai.runtime as runtime

    started = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - started
    function = model.load_function("main")
    timesteps, sigmas = flow_match_schedule(9)
    outputs = {}
    invocations = {}
    for (width, height), starting in noises.items():
        latent = starting.clone()
        shape_invocations = []
        for index, scheduler_timestep in enumerate(timesteps):
            delta = float(sigmas[index + 1] - sigmas[index])
            if delta == 0.0:
                continue
            bucket, values = denoiser_values(latent, prompts, float(scheduler_timestep))
            output, elapsed = await invoke(function, **values)
            prediction = unpatchify_tokens(output["noise_prediction"], width, height)
            latent = latent - delta * prediction.float()
            shape_invocations.append(elapsed)
        outputs[(width, height)] = latent
        invocations[(width, height)] = shape_invocations
    del function, model
    release_mps()
    return outputs, {"loadSeconds": load_seconds, "invocationSeconds": invocations}


def decode_publisher(source: Path, latents: dict[tuple[int, int], torch.Tensor], device: str) -> dict[tuple[int, int], torch.Tensor]:
    vae = _load_vae(source, torch.float32).to(device).eval()
    outputs = {}
    with torch.inference_mode():
        for shape, latent in latents.items():
            prepared = torch.from_numpy(decode_vae_affine(latent.numpy())).to(device)
            if shape == (2048, 2048):
                vae.enable_tiling()
            outputs[shape] = vae.decode(prepared, return_dict=False)[0].detach().cpu().float()
            if device == "mps":
                torch.mps.empty_cache()
    del vae
    release_mps()
    return outputs


async def decode_coreai(asset: Path, latents: dict[tuple[int, int], torch.Tensor]) -> tuple[dict[tuple[int, int], torch.Tensor], dict[str, Any], bool]:
    import coreai.runtime as runtime

    started = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - started
    function = model.load_function("main")
    outputs = {}
    invocations = {}
    for shape, latent in latents.items():
        prepared = torch.from_numpy(decode_vae_affine(latent.numpy()))
        started = time.perf_counter()
        if shape == (2048, 2048):
            outputs[shape] = await tiled_coreai_decoder(function, prepared)
        else:
            output, _ = await invoke(function, latent=prepared)
            outputs[shape] = output["image"]
        elapsed = time.perf_counter() - started
        invocations[shape] = elapsed

    cancellation_ok = False
    probe = torch.from_numpy(decode_vae_affine(next(iter(latents.values())).numpy()))
    task = asyncio.create_task(invoke(function, latent=probe))
    await asyncio.sleep(0)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        followup, _ = await invoke(function, latent=probe)
        cancellation_ok = bool(torch.isfinite(followup["image"]).all())
    del function, model
    release_mps()
    return outputs, {"loadSeconds": load_seconds, "invocationSeconds": invocations}, cancellation_ok


async def validate(
    args: argparse.Namespace,
    component_assets: dict[str, dict[str, str]] | None = None,
    glue_test_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if glue_test_evidence is None:
        raise ContractError("pipeline validation requires bound passing glue-test evidence")
    source = Path(args.source).resolve()
    audit_source(source, HERE / "source-lock.json", allow_lfs_pointers=False)
    component_assets = component_assets or component_asset_bindings(args)
    ids, mask, prompt_details = prompt_inputs(source, args.prompt)
    source_prompt = publisher_prompt(source, ids, mask, args.reference_device)
    core_prompt, prompt_load, prompt_invoke = await coreai_prompt(Path(args.prompt_encoder), ids, mask)
    noises = {shape: initial_noise(*shape, args.seed) for shape in REQUIRED_SHAPES}

    source_latents, source_steps, publisher_record = denoise_publisher(
        source,
        Path(args.publisher_reference).resolve(),
        source_prompt,
        noises,
        args.reference_device,
    )
    core_latents, denoiser_performance = await denoise_coreai(Path(args.denoiser), core_prompt, noises)
    repeated_latents, repeated_denoiser_performance = await denoise_coreai(Path(args.denoiser), core_prompt, noises)
    source_images = decode_publisher(source, source_latents, args.reference_device)
    core_images, decoder_performance, cancellation_ok = await decode_coreai(Path(args.vae_decoder), core_latents)
    repeated_images, repeated_decoder_performance, repeated_cancellation_ok = await decode_coreai(Path(args.vae_decoder), repeated_latents)

    results = []
    for width, height in REQUIRED_SHAPES:
        shape = (width, height)
        expected = source_images[shape]
        actual = core_images[shape]
        repeated = repeated_images[shape]
        observed = metrics(actual, expected)
        repeat_error = float((actual - repeated).abs().max())
        finite = bool(torch.isfinite(actual).all())
        passed = (
            actual.shape == expected.shape == (1, 3, height, width)
            and finite
            and observed["correlation"] >= args.minimum_correlation
            and observed["peakSignalToNoiseRatio"] >= args.minimum_psnr
            and repeat_error == 0.0
        )
        normalized = (actual / 2 + 0.5).clamp(0, 1).numpy().astype("<f4", copy=False)
        duration = (
            sum(denoiser_performance["invocationSeconds"][shape])
            + decoder_performance["invocationSeconds"][shape]
        )
        results.append(
            {
                "width": width, "height": height,
                "status": "passed" if passed else "failed",
                "native": True, "resampled": False,
                "imageTokens": (width // 16) * (height // 16),
                "outputSHA256": hashlib.sha256(normalized.tobytes()).hexdigest(),
                "outputShape": list(actual.shape), "finite": finite,
                "metrics": observed,
                "repeatMaximumAbsoluteError": repeat_error,
                "durationSeconds": duration,
            }
        )
    # These release gates require dedicated lifecycle instrumentation. Distinct
    # output hashes across resolutions do not prove fresh invocation state;
    # requesting cancellation immediately after task creation does not prove
    # native work began; and this script does not measure specialization
    # residency or trace every component load. Keep the gate fail-closed until
    # those observations are implemented explicitly.
    runtime_checks = {
        "freshInvocations": False,
        "specializationResidencyFunction": False,
        "cancellationCleanup": False,
        "textToImageSkippedVAEEncoder": False,
    }
    runtime_evidence = {
        "freshInvocations": {
            "status": "not-measured",
            "detail": "resolution output hashes are not lifecycle evidence",
        },
        "specializationResidencyFunction": {
            "status": "not-measured",
            "detail": "no public residency measurement is recorded",
        },
        "cancellationCleanup": {
            "status": "not-measured",
            "detail": "task cancellation is not synchronized to confirmed native work",
            "diagnosticFollowupFinite": cancellation_ok and repeated_cancellation_ok,
        },
        "textToImageSkippedVAEEncoder": {
            "status": "not-measured",
            "detail": "no component-load trace is recorded",
        },
    }
    parity_passed = all(item["status"] == "passed" for item in results)
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return {
        "schemaVersion": "1.0.0", "pipeline": "z-image-turbo-text-to-image",
        "status": "blocked" if parity_passed else "failed",
        "parityStatus": "passed" if parity_passed else "failed",
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "denoiserPrecision": "bfloat16-with-float32-timestep-and-rope",
        "publisherReference": publisher_record,
        "componentAssets": component_assets,
        "decoderStrategy": "overlapped-tiles", "system": system_record(),
        "prompt": prompt_details, "seed": args.seed,
        "glueTestEvidence": glue_test_evidence,
        "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
        "toolSHA256": sha256_file(Path(__file__).resolve()),
        "runtimeChecks": runtime_checks,
        "runtimeEvidence": runtime_evidence,
        "results": results,
        "performance": {
            "peakResidentBytes": int(peak),
            "componentLoadSeconds": {
                "prompt-encoder": prompt_load,
                "denoiser": denoiser_performance["loadSeconds"],
                "vae-decoder": decoder_performance["loadSeconds"],
            },
            "firstSpecializationSeconds": {
                "prompt-encoder": prompt_load,
                "denoiser": denoiser_performance["loadSeconds"],
                "vae-decoder": decoder_performance["loadSeconds"],
            },
            "repeatInvocationSeconds": {
                "prompt-encoder": prompt_invoke,
                "denoiser": sum(
                    elapsed
                    for values in repeated_denoiser_performance["invocationSeconds"].values()
                    for elapsed in values
                ),
                "vae-decoder": sum(repeated_decoder_performance["invocationSeconds"].values()),
            },
            "denoiserStepSeconds": {
                "publisherMean": float(
                    np.mean([elapsed for values in source_steps.values() for elapsed in values])
                ),
                "coreAIMean": float(
                    np.mean([
                        elapsed
                        for values in denoiser_performance["invocationSeconds"].values()
                        for elapsed in values
                    ])
                ),
                "coreAIMaximum": max(
                    elapsed
                    for values in denoiser_performance["invocationSeconds"].values()
                    for elapsed in values
                ),
            },
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--publisher-reference", required=True)
    parser.add_argument("--prompt-encoder", required=True)
    parser.add_argument("--denoiser", required=True)
    parser.add_argument("--vae-decoder", required=True)
    parser.add_argument("--prompt", default="A red ceramic teapot on a walnut table, soft window light.")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--reference-device", choices=("cpu", "mps"), default="mps")
    parser.add_argument("--minimum-correlation", type=float, default=0.99)
    parser.add_argument("--minimum-psnr", type=float, default=30.0)
    parser.add_argument("--glue-test-log", required=True)
    parser.add_argument("--report", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    component_assets = None
    report_path: Path | None = None
    started = time.perf_counter()
    started_utc = datetime.now(UTC).isoformat()
    try:
        for attribute in (
            "source",
            "publisher_reference",
            "prompt_encoder",
            "denoiser",
            "vae_decoder",
        ):
            setattr(
                args,
                attribute,
                str(guarded_resolve(Path(getattr(args, attribute)))),
            )
        args.report = str(outside_checkout(Path(args.report)))
        report_path = prepare_atomic_new_json(
            Path(args.report), "pipeline validation report"
        )
        glue_test_evidence = verify_glue_test_log(
            Path(args.glue_test_log)
        )
        component_assets = component_asset_bindings(args)
        report = asyncio.run(
            validate(args, component_assets, glue_test_evidence)
        )
        report["commandArguments"] = sys.argv[1:]
        report["startedUTC"] = started_utc
        report["finishedUTC"] = datetime.now(UTC).isoformat()
        report["elapsedSeconds"] = time.perf_counter() - started
        write_atomic_new_json(report_path, report)
        print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
        return 0 if report["status"] == "passed" else 1
    except (ContractError, RuntimeError, OSError, ValueError) as error:
        if report_path is not None and not report_path.exists():
            failure = {
                "schemaVersion": "1.0.0",
                "pipeline": "z-image-turbo-text-to-image",
                "status": "failed",
                "parityStatus": "failed",
                "error": str(error),
                "system": system_record(),
                "computePolicy": os.environ.get(
                    "PIXELTJE_COREAI_COMPUTE", "gpu-preferred"
                ),
                "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
                "toolSHA256": sha256_file(Path(__file__).resolve()),
                "commandArguments": sys.argv[1:],
                "startedUTC": started_utc,
                "finishedUTC": datetime.now(UTC).isoformat(),
                "elapsedSeconds": time.perf_counter() - started,
            }
            if component_assets is not None:
                failure["componentAssets"] = component_assets
            write_atomic_new_json(report_path, failure)
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
