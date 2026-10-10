#!/usr/bin/env python3
"""Evaluate a native 1024-pixel/25%-overlap VAE tiling strategy.

The constants match the pinned VAE's own declared sample size and are accepted
only if this tool's full-vs-tiled quality, seam, Core AI parity, shape, finite,
and repeatability gates pass. No output is resampled.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import math
import os
import resource
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Awaitable, Callable

import torch

from export_components import VAEDecoderWrapper, VAEEncoderWrapper, _load_vae, verify_component_source
from pixaimodel import (
    ContractError,
    HERE,
    guarded_resolve,
    outside_checkout,
    sha256_file,
    sha256_tree,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json
from validate_components import (
    _system_record,
    describe_function,
    invoke,
    metrics,
    synthetic_image,
    synthetic_latent,
    validation_specialization_options,
)


TILE_PIXELS = 1024
OVERLAP_FACTOR = 0.25


def blend_vertical(previous: torch.Tensor, current: torch.Tensor, extent: int) -> torch.Tensor:
    extent = min(previous.shape[2], current.shape[2], extent)
    if extent == 0:
        return current
    weights = torch.arange(extent, dtype=current.dtype).reshape(1, 1, extent, 1) / extent
    current[:, :, :extent, :] = previous[:, :, -extent:, :] * (1 - weights) + current[:, :, :extent, :] * weights
    return current


def blend_horizontal(previous: torch.Tensor, current: torch.Tensor, extent: int) -> torch.Tensor:
    extent = min(previous.shape[3], current.shape[3], extent)
    if extent == 0:
        return current
    weights = torch.arange(extent, dtype=current.dtype).reshape(1, 1, 1, extent) / extent
    current[:, :, :, :extent] = previous[:, :, :, -extent:] * (1 - weights) + current[:, :, :, :extent] * weights
    return current


async def tiled_coreai_encoder(function: Any, image: torch.Tensor) -> torch.Tensor:
    stride = int(TILE_PIXELS * (1 - OVERLAP_FACTOR))
    blend_extent = int((TILE_PIXELS // 8) * OVERLAP_FACTOR)
    row_limit = TILE_PIXELS // 8 - blend_extent
    rows = []
    for top in range(0, image.shape[2], stride):
        row = []
        for left in range(0, image.shape[3], stride):
            tile = image[:, :, top : top + TILE_PIXELS, left : left + TILE_PIXELS]
            output, _ = await invoke(function, image=tile)
            row.append(output["latent"])
        rows.append(row)
    result_rows = []
    for row_index, row in enumerate(rows):
        result = []
        for column_index, tile in enumerate(row):
            if row_index:
                tile = blend_vertical(rows[row_index - 1][column_index], tile, blend_extent)
            if column_index:
                tile = blend_horizontal(row[column_index - 1], tile, blend_extent)
            result.append(tile[:, :, :row_limit, :row_limit])
        result_rows.append(torch.cat(result, dim=3))
    return torch.cat(result_rows, dim=2)


async def tiled_coreai_decoder(function: Any, latent: torch.Tensor) -> torch.Tensor:
    tile_latent = TILE_PIXELS // 8
    stride = int(tile_latent * (1 - OVERLAP_FACTOR))
    blend_extent = int(TILE_PIXELS * OVERLAP_FACTOR)
    row_limit = TILE_PIXELS - blend_extent
    rows = []
    for top in range(0, latent.shape[2], stride):
        row = []
        for left in range(0, latent.shape[3], stride):
            tile = latent[:, :, top : top + tile_latent, left : left + tile_latent]
            output, _ = await invoke(function, latent=tile)
            row.append(output["image"])
        rows.append(row)
    result_rows = []
    for row_index, row in enumerate(rows):
        result = []
        for column_index, tile in enumerate(row):
            if row_index:
                tile = blend_vertical(rows[row_index - 1][column_index], tile, blend_extent)
            if column_index:
                tile = blend_horizontal(row[column_index - 1], tile, blend_extent)
            result.append(tile[:, :, :row_limit, :row_limit])
        result_rows.append(torch.cat(result, dim=3))
    return torch.cat(result_rows, dim=2)


def seam_metrics(actual: torch.Tensor, expected: torch.Tensor, seams: list[int], radius: int = 16) -> dict[str, float]:
    error = (actual.float() - expected.float()).abs()
    mask = torch.zeros_like(error, dtype=torch.bool)
    for position in seams:
        mask[:, :, max(0, position - radius) : position + radius, :] = True
        mask[:, :, :, max(0, position - radius) : position + radius] = True
    overall = float(error.mean())
    seam = float(error[mask].mean()) if bool(mask.any()) else overall
    return {"overallMeanAbsoluteError": overall, "seamMeanAbsoluteError": seam, "seamToOverallRatio": seam / max(overall, 1e-12)}


async def validate(args: argparse.Namespace) -> dict[str, Any]:
    import coreai.runtime as runtime

    source = Path(args.source).resolve()
    asset = Path(args.asset).resolve()
    source_files = verify_component_source(source, args.component)
    vae = _load_vae(source, torch.float32).to(args.reference_device).eval()
    wrapper = VAEEncoderWrapper(vae) if args.component == "vae-encoder" else VAEDecoderWrapper(vae)

    comparison_width, comparison_height = args.comparison_shape
    comparison_input = synthetic_image(comparison_width, comparison_height) if args.component == "vae-encoder" else synthetic_latent(comparison_width, comparison_height)
    with torch.inference_mode():
        full = wrapper(comparison_input.to(args.reference_device)).detach().cpu().float()
        vae.enable_tiling()
        target_input = synthetic_image(2048, 2048) if args.component == "vae-encoder" else synthetic_latent(2048, 2048)
        if args.component == "vae-encoder":
            comparison_moments = vae._tiled_encode(comparison_input.to(args.reference_device))
            target_moments = vae._tiled_encode(target_input.to(args.reference_device))
            tiled_comparison = torch.chunk(comparison_moments, 2, dim=1)[0].detach().cpu().float()
            tiled_target = torch.chunk(target_moments, 2, dim=1)[0].detach().cpu().float()
        else:
            tiled_comparison = wrapper(comparison_input.to(args.reference_device)).detach().cpu().float()
            tiled_target = wrapper(target_input.to(args.reference_device)).detach().cpu().float()
    full_to_tiled = metrics(tiled_comparison, full)
    output_scale = 8 if args.component == "vae-encoder" else 1
    seam_stride = int(TILE_PIXELS * (1 - OVERLAP_FACTOR)) // output_scale
    output_minimum = min(full.shape[2], full.shape[3])
    seams = list(range(seam_stride, output_minimum, seam_stride))
    full_to_tiled_seams = seam_metrics(tiled_comparison, full, seams)
    del wrapper, vae
    gc.collect()
    if args.reference_device == "mps":
        torch.mps.empty_cache()

    started = time.perf_counter()
    model = await runtime.AIModel.load(str(asset), validation_specialization_options(runtime))
    load_seconds = time.perf_counter() - started
    function = model.load_function("main")
    descriptor = describe_function(function)
    execute = tiled_coreai_encoder if args.component == "vae-encoder" else tiled_coreai_decoder
    first_started = time.perf_counter()
    actual = await execute(function, target_input)
    first_seconds = time.perf_counter() - first_started
    repeat_started = time.perf_counter()
    repeated = await execute(function, target_input)
    repeat_seconds = time.perf_counter() - repeat_started
    coreai_to_publisher = metrics(actual, tiled_target)
    coreai_seams = seam_metrics(
        actual, tiled_target,
        [position // output_scale for position in (768, 1536)],
        radius=max(2, 16 // output_scale),
    )
    repeat_error = float((actual - repeated).abs().max())
    expected_shape = (1, 16, 256, 256) if args.component == "vae-encoder" else (1, 3, 2048, 2048)
    quality_passed = (
        full_to_tiled["correlation"] >= args.minimum_full_correlation
        and full_to_tiled["peakSignalToNoiseRatio"] >= args.minimum_full_psnr
        and full_to_tiled_seams["seamToOverallRatio"] <= args.maximum_seam_ratio
    )
    parity_passed = (
        tuple(actual.shape) == expected_shape and bool(torch.isfinite(actual).all())
        and coreai_to_publisher["correlation"] >= 0.9999
        and coreai_to_publisher["maximumAbsoluteError"] <= 0.02
        and coreai_seams["seamToOverallRatio"] <= 1.25
        and repeat_error == 0.0
    )
    return {
        "schemaVersion": "1.0.0", "component": args.component,
        "variant": "overlapped-tiles-1024-25-percent", "asset": asset.name,
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": sha256_tree(asset),
        "computePolicy": os.environ.get("PIXELTJE_COREAI_COMPUTE", "gpu-preferred"),
        "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
        "toolSHA256": sha256_file(Path(__file__).resolve()),
        "sourceFiles": source_files,
        "strategy": {"tilePixels": TILE_PIXELS, "overlapFactor": OVERLAP_FACTOR, "native": True, "resampled": False},
        "descriptor": descriptor, "modelLoadSeconds": load_seconds,
        "comparison": {
            "width": comparison_width, "height": comparison_height,
            "fullToTiledMetrics": full_to_tiled, "seamMetrics": full_to_tiled_seams,
            "status": "passed" if quality_passed else "failed",
        },
        "target": {
            "width": 2048, "height": 2048, "outputShape": list(actual.shape),
            "finite": bool(torch.isfinite(actual).all()),
            "coreAIToPublisherTiledMetrics": coreai_to_publisher,
            "seamMetrics": coreai_seams, "repeatMaximumAbsoluteError": repeat_error,
            "firstInvocationSeconds": first_seconds, "repeatInvocationSeconds": repeat_seconds,
            "status": "passed" if parity_passed else "failed",
        },
        "status": "passed" if quality_passed and parity_passed else "failed",
    }


def shape(value: str) -> tuple[int, int]:
    try:
        return tuple(int(part) for part in value.lower().split("x", 1))  # type: ignore[return-value]
    except ValueError as error:
        raise argparse.ArgumentTypeError("shape must be WIDTHxHEIGHT") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("vae-encoder", "vae-decoder"))
    parser.add_argument("--asset", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--reference-device", choices=("cpu", "mps"), default="mps")
    parser.add_argument("--comparison-shape", type=shape, default=(1280, 1280))
    parser.add_argument("--minimum-full-correlation", type=float, default=0.99)
    parser.add_argument("--minimum-full-psnr", type=float, default=30.0)
    parser.add_argument("--maximum-seam-ratio", type=float, default=2.0)
    parser.add_argument("--report", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    report_path: Path | None = None
    started = time.perf_counter()
    started_utc = datetime.now(UTC).isoformat()
    try:
        args.asset = str(guarded_resolve(Path(args.asset)))
        args.source = str(guarded_resolve(Path(args.source)))
        args.report = str(outside_checkout(Path(args.report)))
        report_path = prepare_atomic_new_json(
            Path(args.report), "VAE tiling validation report"
        )
        report = asyncio.run(validate(args))
        report["peakResidentBytes"] = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        report["system"] = _system_record()
        report["commandArguments"] = sys.argv[1:]
        report["startedUTC"] = started_utc
        report["finishedUTC"] = datetime.now(UTC).isoformat()
        report["elapsedSeconds"] = time.perf_counter() - started
        write_atomic_new_json(report_path, report)
        print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
        return 0 if report["status"] == "passed" else 1
    except (ContractError, RuntimeError, OSError, ValueError) as error:
        if report_path is not None and not report_path.exists():
            asset = Path(args.asset)
            try:
                asset_digest = sha256_tree(asset) if asset.is_dir() else None
            except (ContractError, OSError):
                asset_digest = None
            write_atomic_new_json(
                report_path,
                {
                    "schemaVersion": "1.0.0",
                    "component": args.component,
                    "variant": "overlapped-tiles-1024-25-percent",
                    "asset": asset.name,
                    "assetDigestAlgorithm": (
                        "sha256-tree-v1" if asset_digest is not None else None
                    ),
                    "assetDigest": asset_digest,
                    "computePolicy": os.environ.get(
                        "PIXELTJE_COREAI_COMPUTE", "gpu-preferred"
                    ),
                    "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
                    "toolSHA256": sha256_file(Path(__file__).resolve()),
                    "system": _system_record(),
                    "commandArguments": sys.argv[1:],
                    "startedUTC": started_utc,
                    "finishedUTC": datetime.now(UTC).isoformat(),
                    "elapsedSeconds": time.perf_counter() - started,
                    "status": "failed",
                    "error": str(error),
                },
            )
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
