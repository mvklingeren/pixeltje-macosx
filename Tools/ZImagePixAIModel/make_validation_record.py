#!/usr/bin/env python3
"""Combine passing external reports into a fail-closed validation record."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from pixaimodel import (
    ContractError,
    REQUIRED_GATES,
    REQUIRED_RESOLUTIONS,
    VALIDATION_SCHEMA,
    audit_references,
    audit_source,
    guarded_resolve,
    load_json,
    outside_checkout,
    sha256_file,
    validate_schema,
    verify_glue_test_log,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json


PACKAGE_ID = "app.pixeltje.model.z-image-turbo"
SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"
DIRECT_RESOLUTIONS = REQUIRED_RESOLUTIONS - {(2048, 2048)}
ASSET_DIGEST_ALGORITHM = "sha256-tree-v1"
EXPORT_CONTRACTS = {
    "prompt-encoder": ("fixed-512-tokens", "float16", "float16"),
    "denoiser": (
        "dynamic-image-dynamic-prompt-bucket",
        "bfloat16",
        "bfloat16-with-float32-timestep-and-rope",
    ),
    "vae-encoder": ("dynamic-512-2048", "float32", "float32"),
    "vae-decoder": ("dynamic-512-2048", "float32", "float32"),
}
UNMEASURED_RUNTIME_CHECKS = {
    "freshInvocations",
    "specializationResidencyFunction",
    "cancellationCleanup",
    "textToImageSkippedVAEEncoder",
}


def evidence(path: Path) -> str:
    return f"{path.name}:sha256:{sha256_file(path)}"


def require_report_identity(
    report: dict[str, Any], path: Path, tool_path: Path, lock_path: Path
) -> None:
    expected_lock = sha256_file(lock_path)
    expected_tool = sha256_file(tool_path)
    if report.get("sourceLockSHA256") != expected_lock:
        raise ContractError(f"report source-lock identity mismatch: {path}")
    if report.get("toolSHA256") != expected_tool:
        raise ContractError(f"report tool identity mismatch: {path}")


def publisher_reference_identity(
    publisher: Path, lock_path: Path
) -> dict[str, str]:
    locked = load_json(lock_path)["publisherReference"]
    return {
        "repository": locked["repository"],
        "revision": locked["revision"],
        "licenseSHA256": locked["licenseSHA256"],
        "transformerSHA256": sha256_file(
            publisher / "src" / "zimage" / "transformer.py"
        ),
        "attentionSHA256": sha256_file(
            publisher / "src" / "utils" / "attention.py"
        ),
    }


def require_publisher_reference_identity(
    report: dict[str, Any], expected: dict[str, str], path: Path
) -> None:
    if report.get("publisherReference") != expected:
        raise ContractError(f"report publisher-reference identity mismatch: {path}")


def require_execution_metadata(report: dict[str, Any], path: Path) -> None:
    arguments = report.get("commandArguments")
    if (
        not isinstance(arguments, list)
        or not arguments
        or any(not isinstance(item, str) or not item for item in arguments)
    ):
        raise ContractError(f"report lacks exact command arguments: {path}")
    timestamps = []
    for key in ("startedUTC", "finishedUTC"):
        value = report.get(key)
        if not isinstance(value, str) or not value:
            raise ContractError(f"report lacks {key}: {path}")
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError as error:
            raise ContractError(f"report has invalid {key}: {path}") from error
        if parsed.tzinfo is None:
            raise ContractError(f"report has timezone-free {key}: {path}")
        timestamps.append(parsed)
    if timestamps[1] < timestamps[0]:
        raise ContractError(f"report finishes before it starts: {path}")
    elapsed = report.get("elapsedSeconds")
    if (
        not isinstance(elapsed, (int, float))
        or isinstance(elapsed, bool)
        or not math.isfinite(elapsed)
        or elapsed < 0.0
    ):
        raise ContractError(f"report lacks a finite elapsed duration: {path}")


def require_export_report(
    path: Path,
    component: str,
    component_report: dict[str, Any],
    lock_path: Path,
) -> dict[str, Any]:
    report = load_json(path)
    require_execution_metadata(report, path)
    variant, precision, computation_precision = EXPORT_CONTRACTS[component]
    expected = {
        "schemaVersion": "1.0.0",
        "component": component,
        "variant": variant,
        "functionNames": ["main"],
        "probe": False,
        "debugExport": False,
        "converterMode": "release",
        "profilerProbe": None,
        "precision": precision,
        "computationPrecision": computation_precision,
        "sourceRevision": SOURCE_REVISION,
        "digestAlgorithm": ASSET_DIGEST_ALGORITHM,
        "digest": component_report["assetDigest"],
        "artifact": component_report.get("asset"),
        "sourceLockSHA256": sha256_file(lock_path),
        "toolSHA256": sha256_file(Path(__file__).with_name("export_components.py")),
        "sourceFiles": component_report.get("sourceFiles"),
        "system": component_report.get("system"),
    }
    for key, value in expected.items():
        if report.get(key) != value:
            raise ContractError(
                f"{component} export report {key} mismatch: "
                f"expected {value!r}, found {report.get(key)!r}: {path}"
            )
    expected_attention = "model-precision" if component == "denoiser" else None
    if report.get("attentionAccumulation") != expected_attention:
        raise ContractError(f"{component} export report has wrong attention contract: {path}")
    return {
        "id": component,
        "variant": variant,
        "reportFile": path.name,
        "reportSHA256": sha256_file(path),
        "assetDigestAlgorithm": ASSET_DIGEST_ALGORITHM,
        "assetDigest": report["digest"],
        "converterMode": "release",
        "probe": False,
        "precision": precision,
        "computationPrecision": computation_precision,
        "sourceRevision": SOURCE_REVISION,
        "sourceLockSHA256": report["sourceLockSHA256"],
        "toolSHA256": report["toolSHA256"],
        "system": report["system"],
    }


def require_asset_binding(report: dict[str, Any], path: Path) -> dict[str, str]:
    algorithm = report.get("assetDigestAlgorithm")
    digest = report.get("assetDigest")
    if algorithm != ASSET_DIGEST_ALGORITHM:
        raise ContractError(
            f"component report uses the wrong asset digest algorithm: {path}"
        )
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
    ):
        raise ContractError(f"component report lacks its tested asset digest: {path}")
    return {"assetDigestAlgorithm": algorithm, "assetDigest": digest}


def require_passing(
    path: Path,
    component: str | None = None,
    variant: str | None = None,
) -> dict[str, Any]:
    report = load_json(path)
    if report.get("schemaVersion") != "1.0.0" or report.get("status") != "passed":
        raise ContractError(f"report is not passing: {path}")
    if component is not None and report.get("component") != component:
        raise ContractError(f"wrong component report for {component}: {path}")
    if variant is not None and report.get("variant") != variant:
        raise ContractError(
            f"wrong {component or 'component'} report variant {report.get('variant')!r}: {path}"
        )
    if component is not None:
        require_asset_binding(report, path)
    return report


def require_same_component_asset(
    component: str,
    reports: tuple[tuple[dict[str, Any], Path], ...],
) -> None:
    bindings = set()
    for report, path in reports:
        binding = require_asset_binding(report, path)
        bindings.add(
            (binding["assetDigestAlgorithm"], binding["assetDigest"])
        )
    if len(bindings) != 1:
        raise ContractError(
            f"{component} validation variants were run against different assets"
        )


def require_pipeline_asset_bindings(
    pipeline: dict[str, Any],
    component_reports: dict[str, tuple[dict[str, Any], Path]],
    path: Path,
) -> None:
    assets = pipeline.get("componentAssets")
    if not isinstance(assets, dict) or set(assets) != set(component_reports):
        raise ContractError(
            f"pipeline report must bind exactly {sorted(component_reports)}: {path}"
        )
    for component_id, (report, report_path) in component_reports.items():
        binding = assets.get(component_id)
        if not isinstance(binding, dict):
            raise ContractError(
                f"pipeline report lacks the {component_id} asset binding: {path}"
            )
        expected = require_asset_binding(report, report_path)
        if binding != expected:
            raise ContractError(
                f"pipeline report used a different {component_id} asset: {path}"
            )


def require_blocked_pipeline_lifecycle(
    pipeline: dict[str, Any], path: Path
) -> dict[str, Any]:
    if (
        pipeline.get("schemaVersion") != "1.0.0"
        or pipeline.get("pipeline") != "z-image-turbo-text-to-image"
        or pipeline.get("status") != "blocked"
        or pipeline.get("parityStatus") != "passed"
    ):
        raise ContractError(f"pipeline report has the wrong identity/state: {path}")
    runtime_checks = pipeline.get("runtimeChecks")
    if (
        not isinstance(runtime_checks, dict)
        or set(runtime_checks) != UNMEASURED_RUNTIME_CHECKS
        or any(runtime_checks[key] is not False for key in UNMEASURED_RUNTIME_CHECKS)
    ):
        raise ContractError(
            "pipeline report must honestly mark every uninstrumented lifecycle check false"
        )
    runtime_evidence = pipeline.get("runtimeEvidence")
    if (
        not isinstance(runtime_evidence, dict)
        or set(runtime_evidence) != UNMEASURED_RUNTIME_CHECKS
    ):
        raise ContractError("pipeline report lacks exact uninstrumented lifecycle evidence")
    for key in UNMEASURED_RUNTIME_CHECKS:
        item = runtime_evidence[key]
        if (
            not isinstance(item, dict)
            or item.get("status") != "not-measured"
            or not isinstance(item.get("detail"), str)
            or not item["detail"]
        ):
            raise ContractError(
                f"pipeline lifecycle evidence is not fail-closed for {key}"
            )
    return runtime_evidence


def require_release_compute_policy(
    report: dict[str, Any], label: str, path: Path
) -> None:
    if report.get("computePolicy") != "gpu-preferred":
        raise ContractError(
            f"{label} report did not use the required gpu-preferred compute policy: {path}"
        )


def require_resolution_results(
    report: dict[str, Any], required: set[tuple[int, int]], label: str
) -> None:
    observed = {(item.get("width"), item.get("height")) for item in report.get("results", [])}
    if observed != required:
        raise ContractError(
            f"{label} resolution results mismatch: expected {sorted(required)}, got {sorted(observed)}"
        )


def require_runtime_identity(
    direct_reports: tuple[tuple[dict[str, Any], Path], ...],
    tiled_reports: tuple[tuple[dict[str, Any], Path], ...],
    pipeline: dict[str, Any],
    pipeline_path: Path,
) -> None:
    expected = direct_reports[0][0].get("system")
    if not isinstance(expected, dict):
        raise ContractError(f"component report lacks runtime identity: {direct_reports[0][1]}")
    for report, path in direct_reports + tiled_reports:
        if report.get("system") != expected:
            raise ContractError(f"component validation runtime identity mismatch: {path}")
    for (direct, _), (tiled, tiled_path) in zip(
        direct_reports[2:], tiled_reports, strict=True
    ):
        if tiled.get("sourceFiles") != direct.get("sourceFiles"):
            raise ContractError(
                f"tiled VAE source-file identity mismatch: {tiled_path}"
            )
    packages = expected.get("packages")
    if not isinstance(packages, dict):
        raise ContractError("component validation runtime identity lacks package versions")
    expected_pipeline = {
        "macOS": expected.get("macOS"),
        "build": expected.get("build"),
        "machine": expected.get("machine"),
        "coreAIRuntime": packages.get("coreai-core"),
        "python": expected.get("python"),
        "torch": packages.get("torch"),
        "coreAITorch": packages.get("coreai-torch"),
    }
    if pipeline.get("system") != expected_pipeline:
        raise ContractError(f"pipeline validation runtime identity mismatch: {pipeline_path}")


def require_metric(
    values: Any,
    name: str,
    label: str,
) -> float:
    if not isinstance(values, dict):
        raise ContractError(f"{label} lacks metrics")
    value = values.get(name)
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
    ):
        raise ContractError(f"{label} lacks numeric {name}")
    return float(value)


def require_vae_tiling_contract(
    report: dict[str, Any], component: str, path: Path
) -> None:
    label = f"{component} tiled"
    strategy = report.get("strategy")
    comparison = report.get("comparison")
    target = report.get("target")
    if not isinstance(strategy, dict) or (
        strategy.get("tilePixels") != 1024
        or strategy.get("overlapFactor") != 0.25
        or strategy.get("native") is not True
        or strategy.get("resampled") is not False
    ):
        raise ContractError(f"{label} report has the wrong execution strategy: {path}")
    if not isinstance(comparison, dict) or (
        comparison.get("status") != "passed"
        or (comparison.get("width"), comparison.get("height")) != (1280, 1280)
    ):
        raise ContractError(f"{label} full/tiled comparison did not pass: {path}")
    if (
        require_metric(
            comparison.get("fullToTiledMetrics"), "correlation", label
        )
        < 0.99
        or require_metric(
            comparison.get("fullToTiledMetrics"),
            "peakSignalToNoiseRatio",
            label,
        )
        < 30.0
        or require_metric(
            comparison.get("seamMetrics"), "seamToOverallRatio", label
        )
        > 2.0
    ):
        raise ContractError(f"{label} full/tiled quality is below release gates: {path}")

    expected_shape = (
        [1, 16, 256, 256]
        if component == "vae-encoder"
        else [1, 3, 2048, 2048]
    )
    if not isinstance(target, dict) or (
        (target.get("width"), target.get("height")) != (2048, 2048)
        or target.get("status") != "passed"
        or target.get("finite") is not True
        or target.get("outputShape") != expected_shape
        or target.get("repeatMaximumAbsoluteError") != 0.0
    ):
        raise ContractError(f"{label} lacks a finite, repeatable native target: {path}")
    if (
        require_metric(
            target.get("coreAIToPublisherTiledMetrics"), "correlation", label
        )
        < 0.9999
        or require_metric(
            target.get("coreAIToPublisherTiledMetrics"),
            "maximumAbsoluteError",
            label,
        )
        > 0.02
        or require_metric(
            target.get("seamMetrics"), "seamToOverallRatio", label
        )
        > 1.25
    ):
        raise ContractError(f"{label} Core AI target is below release gates: {path}")


def require_pipeline_result_contract(
    item: dict[str, Any], shape: tuple[int, int], path: Path
) -> None:
    width, height = shape
    if (
        item.get("status") != "passed"
        or item.get("native") is not True
        or item.get("resampled") is not False
        or item.get("finite") is not True
        or item.get("outputShape") != [1, 3, height, width]
        or item.get("imageTokens") != (width // 16) * (height // 16)
        or item.get("repeatMaximumAbsoluteError") != 0.0
    ):
        raise ContractError(
            f"pipeline result is not finite, repeatable, correctly shaped, and native: {shape}: {path}"
        )
    metrics = item.get("metrics")
    if (
        require_metric(metrics, "correlation", f"pipeline {width}x{height}")
        < 0.99
        or require_metric(
            metrics,
            "peakSignalToNoiseRatio",
            f"pipeline {width}x{height}",
        )
        < 30.0
    ):
        raise ContractError(
            f"pipeline result is below fixed release parity gates: {shape}: {path}"
        )


def require_full_denoiser_contract(report: dict[str, Any], path: Path) -> None:
    expected_metadata = {
        "variant": "dynamic-image-dynamic-prompt-bucket",
        "precision": "bfloat16",
        "computationPrecision": "bfloat16-with-float32-timestep-and-rope",
        "attentionAccumulation": "model-precision",
        "computePolicy": "gpu-preferred",
        "assetDigestAlgorithm": ASSET_DIGEST_ALGORITHM,
    }
    mismatches = {
        key: (expected, report.get(key))
        for key, expected in expected_metadata.items()
        if report.get(key) != expected
    }
    if mismatches:
        raise ContractError(f"denoiser report has the wrong conversion contract: {mismatches}: {path}")
    require_asset_binding(report, path)

    for item in report.get("results", []):
        width = item.get("width")
        height = item.get("height")
        if (
            not isinstance(width, int)
            or isinstance(width, bool)
            or not isinstance(height, int)
            or isinstance(height, bool)
        ):
            raise ContractError(f"denoiser result lacks integer dimensions: {path}")
        image_tokens = (width // 16) * (height // 16)
        padded_tokens = ((image_tokens + 31) // 32) * 32
        if (
            item.get("status") != "passed"
            or item.get("finite") is not True
            or item.get("validImageTokens") != image_tokens
            or item.get("outputShape") != [1, padded_tokens, 64]
            or require_metric(
                item, "repeatMaximumAbsoluteError", "denoiser result"
            )
            != 0.0
        ):
            raise ContractError(
                f"denoiser result is not finite, repeatable, or correctly shaped: {path}"
            )
        adapter = item.get("adapterToPublisherMetrics")
        core_ai = item.get("coreAIToPublisherMetrics")
        if not isinstance(adapter, dict) or not isinstance(core_ai, dict):
            raise ContractError(f"denoiser result lacks both parity comparisons: {path}")
        if not (
            require_metric(adapter, "correlation", "denoiser adapter") >= 0.99999
            and require_metric(
                adapter, "peakSignalToNoiseRatio", "denoiser adapter"
            )
            >= 60.0
        ):
            raise ContractError(f"denoiser tensor adapter is below its parity gate: {path}")
        if not (
            require_metric(core_ai, "correlation", "Core AI denoiser") >= 0.999
            and require_metric(
                core_ai, "peakSignalToNoiseRatio", "Core AI denoiser"
            )
            >= 40.0
        ):
            raise ContractError(f"Core AI denoiser is below its parity gate: {path}")


def require_direct_component_result_contract(
    component_id: str, item: dict[str, Any], path: Path
) -> None:
    label = f"{component_id} numerical result"
    if (
        item.get("status") != "passed"
        or item.get("finite") is not True
        or require_metric(item, "repeatMaximumAbsoluteError", label) != 0.0
    ):
        raise ContractError(f"{label} is not finite and exactly repeatable: {path}")
    metrics = item.get("metrics")
    if component_id == "prompt-encoder":
        if item.get("outputShape") != [1, 512, 2560]:
            raise ContractError(f"prompt encoder result has the wrong output shape: {path}")
        if (
            require_metric(metrics, "correlation", label) < 0.999
            or require_metric(metrics, "peakSignalToNoiseRatio", label) < 40.0
        ):
            raise ContractError(f"prompt encoder result is below fixed parity gates: {path}")
        return

    width = item.get("width")
    height = item.get("height")
    if (
        not isinstance(width, int)
        or isinstance(width, bool)
        or not isinstance(height, int)
        or isinstance(height, bool)
    ):
        raise ContractError(f"{label} lacks integer dimensions: {path}")
    if component_id == "vae-encoder":
        expected_shape = [1, 16, height // 8, width // 8]
        below_gate = (
            require_metric(metrics, "correlation", label) < 0.99999
            or require_metric(metrics, "peakSignalToNoiseRatio", label) < 80.0
            or require_metric(metrics, "rootMeanSquaredError", label) > 0.001
            or require_metric(metrics, "maximumAbsoluteError", label) > 0.075
        )
    elif component_id == "vae-decoder":
        expected_shape = [1, 3, height, width]
        below_gate = (
            require_metric(metrics, "correlation", label) < 0.9999
            or require_metric(metrics, "maximumAbsoluteError", label) > 0.02
        )
    else:
        return
    if item.get("outputShape") != expected_shape:
        raise ContractError(f"{label} has the wrong output shape: {path}")
    if below_gate:
        raise ContractError(f"{label} is below fixed parity gates: {path}")


def parity_result(component_id: str, variant: str, results: list[dict[str, Any]], report: dict[str, Any], metric_key: str, threshold: float) -> dict[str, Any]:
    if not results or any(item.get("status") != "passed" for item in results):
        raise ContractError(f"{component_id}/{variant} has a missing or failed numerical result")
    observed = []
    for item in results:
        require_direct_component_result_contract(component_id, item, Path(report.get("asset", component_id)))
        metrics = item.get("metrics") or item.get("coreAIToPublisherMetrics")
        observed.append(
            require_metric(metrics, metric_key, f"{component_id}/{variant}")
        )
    worst_observed = min(observed)
    if worst_observed < threshold:
        raise ContractError(
            f"{component_id}/{variant} {metric_key} {worst_observed} is below {threshold}"
        )
    if report.get("descriptorMatch") is not True:
        raise ContractError(f"{component_id}/{variant} lacks an explicit passing descriptor gate")
    if any(item.get("finite") is not True for item in results):
        raise ContractError(f"{component_id}/{variant} lacks an explicit finite-output gate")
    return {
        "id": component_id,
        "variant": variant,
        "assetDigestAlgorithm": report["assetDigestAlgorithm"],
        "assetDigest": report["assetDigest"],
        "descriptorMatch": True,
        "finiteOutputs": True,
        "estimatedResidentBytes": int(
            report.get("estimatedResidentBytes", report.get("peakResidentBytes", 0))
        ),
        "parity": {
            "status": "passed",
            "metric": metric_key,
            "threshold": threshold,
            "worstObserved": worst_observed,
        },
    }


def make_record(args: argparse.Namespace) -> dict[str, Any]:
    source = Path(args.source).resolve()
    publisher = Path(args.publisher_reference).resolve()
    apple = Path(args.apple_reference).resolve()
    audit_source(source, Path(args.lock), allow_lfs_pointers=False)
    audit_references(publisher, apple, Path(args.lock))
    lock_path = Path(args.lock)

    prompt_path = Path(args.prompt_report)
    denoiser_path = Path(args.denoiser_report)
    encoder_path = Path(args.vae_encoder_report)
    decoder_path = Path(args.vae_decoder_report)
    encoder_tiling_path = Path(args.vae_encoder_tiling_report)
    decoder_tiling_path = Path(args.vae_decoder_tiling_report)
    pipeline_path = Path(args.pipeline_report)
    glue_test_path = Path(args.glue_test_log)
    export_paths = {
        "prompt-encoder": Path(args.prompt_export_report),
        "denoiser": Path(args.denoiser_export_report),
        "vae-encoder": Path(args.vae_encoder_export_report),
        "vae-decoder": Path(args.vae_decoder_export_report),
    }
    prompt = require_passing(
        prompt_path, "prompt-encoder", "fixed-512-tokens"
    )
    denoiser = require_passing(
        denoiser_path, "denoiser", "dynamic-image-dynamic-prompt-bucket"
    )
    if denoiser.get("adapterCheckSkipped") is not False:
        raise ContractError("complete denoiser report must include the tensor-adapter parity check")
    require_full_denoiser_contract(denoiser, denoiser_path)
    encoder = require_passing(
        encoder_path, "vae-encoder", "dynamic-512-2048"
    )
    decoder = require_passing(
        decoder_path, "vae-decoder", "dynamic-512-2048"
    )
    encoder_tiling = require_passing(
        encoder_tiling_path,
        "vae-encoder",
        "overlapped-tiles-1024-25-percent",
    )
    decoder_tiling = require_passing(
        decoder_tiling_path,
        "vae-decoder",
        "overlapped-tiles-1024-25-percent",
    )
    for report, label, path in (
        (prompt, "prompt encoder", prompt_path),
        (denoiser, "denoiser", denoiser_path),
        (encoder, "VAE encoder direct", encoder_path),
        (decoder, "VAE decoder direct", decoder_path),
        (encoder_tiling, "VAE encoder tiled", encoder_tiling_path),
        (decoder_tiling, "VAE decoder tiled", decoder_tiling_path),
    ):
        require_release_compute_policy(report, label, path)
    require_same_component_asset(
        "vae-encoder",
        ((encoder, encoder_path), (encoder_tiling, encoder_tiling_path)),
    )
    require_same_component_asset(
        "vae-decoder",
        ((decoder, decoder_path), (decoder_tiling, decoder_tiling_path)),
    )
    pipeline = load_json(pipeline_path)
    runtime_evidence = require_blocked_pipeline_lifecycle(
        pipeline, pipeline_path
    )
    glue_test_evidence = verify_glue_test_log(glue_test_path)
    if pipeline.get("glueTestEvidence") != glue_test_evidence:
        raise ContractError(
            f"pipeline report is not bound to the current passing glue test log: {pipeline_path}"
        )
    require_release_compute_policy(pipeline, "pipeline", pipeline_path)
    require_pipeline_asset_bindings(
        pipeline,
        {
            "prompt-encoder": (prompt, prompt_path),
            "denoiser": (denoiser, denoiser_path),
            "vae-decoder": (decoder, decoder_path),
        },
        pipeline_path,
    )
    direct_reports = (
        (prompt, prompt_path),
        (denoiser, denoiser_path),
        (encoder, encoder_path),
        (decoder, decoder_path),
    )
    tiled_reports = (
        (encoder_tiling, encoder_tiling_path),
        (decoder_tiling, decoder_tiling_path),
    )
    for report, path in direct_reports + tiled_reports + ((pipeline, pipeline_path),):
        require_execution_metadata(report, path)
    require_runtime_identity(
        direct_reports, tiled_reports, pipeline, pipeline_path
    )
    validate_components_tool = Path(__file__).with_name("validate_components.py")
    validate_tiling_tool = Path(__file__).with_name("validate_vae_tiling.py")
    validate_pipeline_tool = Path(__file__).with_name("validate_pipeline.py")
    for report, path, tool in (
        (prompt, prompt_path, validate_components_tool),
        (denoiser, denoiser_path, validate_components_tool),
        (encoder, encoder_path, validate_components_tool),
        (decoder, decoder_path, validate_components_tool),
        (encoder_tiling, encoder_tiling_path, validate_tiling_tool),
        (decoder_tiling, decoder_tiling_path, validate_tiling_tool),
        (pipeline, pipeline_path, validate_pipeline_tool),
    ):
        require_report_identity(report, path, tool, lock_path)
    expected_publisher_reference = publisher_reference_identity(
        publisher, lock_path
    )
    require_publisher_reference_identity(
        denoiser, expected_publisher_reference, denoiser_path
    )
    require_publisher_reference_identity(
        pipeline, expected_publisher_reference, pipeline_path
    )
    export_reports = [
        require_export_report(
            export_paths[component],
            component,
            {
                "prompt-encoder": prompt,
                "denoiser": denoiser,
                "vae-encoder": encoder,
                "vae-decoder": decoder,
            }[component],
            lock_path,
        )
        for component in EXPORT_CONTRACTS
    ]
    require_resolution_results(encoder, DIRECT_RESOLUTIONS, "VAE encoder direct")
    require_resolution_results(decoder, DIRECT_RESOLUTIONS, "VAE decoder direct")
    require_resolution_results(denoiser, REQUIRED_RESOLUTIONS, "denoiser")
    denoiser_buckets = {
        item.get("promptBucket")
        for item in denoiser.get("results", [])
        if item.get("width") == 512 and item.get("height") == 512
    }
    if not {32, 256, 512}.issubset(denoiser_buckets):
        raise ContractError("denoiser report lacks representative minimum/middle/maximum prompt buckets")
    require_vae_tiling_contract(
        encoder_tiling, "vae-encoder", encoder_tiling_path
    )
    require_vae_tiling_contract(
        decoder_tiling, "vae-decoder", decoder_tiling_path
    )

    pipeline_results = pipeline.get("results", [])
    if not isinstance(pipeline_results, list) or any(
        not isinstance(item, dict) for item in pipeline_results
    ):
        raise ContractError("pipeline report has invalid resolution results")
    result_shapes = [(item.get("width"), item.get("height")) for item in pipeline_results]
    if len(result_shapes) != len(set(result_shapes)):
        raise ContractError("pipeline report has duplicate resolution results")
    resolution_results = {
        (item["width"], item["height"]): item for item in pipeline_results
    }
    if set(resolution_results) != REQUIRED_RESOLUTIONS:
        raise ContractError("pipeline report must contain exactly the required native resolution matrix")
    for shape, item in resolution_results.items():
        require_pipeline_result_contract(item, shape, pipeline_path)

    components = [
        parity_result("prompt-encoder", "fixed-512-tokens", prompt["results"], prompt, "peakSignalToNoiseRatio", 40.0),
        parity_result("vae-encoder", "direct-up-to-9216-tokens", encoder["results"], encoder, "correlation", 0.99999),
        parity_result("vae-decoder", "direct-up-to-9216-tokens", decoder["results"], decoder, "correlation", 0.9999),
        {
            "id": "vae-encoder", "variant": "overlapped-tiles-up-to-16384-tokens",
            "assetDigestAlgorithm": encoder_tiling["assetDigestAlgorithm"],
            "assetDigest": encoder_tiling["assetDigest"],
            "descriptorMatch": True, "finiteOutputs": True,
            "estimatedResidentBytes": int(
                encoder_tiling.get("estimatedResidentBytes", encoder_tiling.get("peakResidentBytes", 0))
            ),
            "parity": {"status": "passed", "metric": "correlation", "threshold": 0.9999, "worstObserved": encoder_tiling["target"]["coreAIToPublisherTiledMetrics"]["correlation"]},
        },
        {
            "id": "vae-decoder", "variant": "overlapped-tiles-up-to-16384-tokens",
            "assetDigestAlgorithm": decoder_tiling["assetDigestAlgorithm"],
            "assetDigest": decoder_tiling["assetDigest"],
            "descriptorMatch": True, "finiteOutputs": True,
            "estimatedResidentBytes": int(
                decoder_tiling.get("estimatedResidentBytes", decoder_tiling.get("peakResidentBytes", 0))
            ),
            "parity": {"status": "passed", "metric": "correlation", "threshold": 0.9999, "worstObserved": decoder_tiling["target"]["coreAIToPublisherTiledMetrics"]["correlation"]},
        },
    ]
    components.append(
        parity_result(
            "denoiser", "dynamic-image-dynamic-prompt-bucket", denoiser["results"],
            denoiser, "peakSignalToNoiseRatio", 40.0,
        )
    )

    report_evidence = {
        "prompt": evidence(prompt_path), "denoiser": evidence(denoiser_path),
        "encoder": evidence(encoder_path), "decoder": evidence(decoder_path),
        "encoderTiling": evidence(encoder_tiling_path), "decoderTiling": evidence(decoder_tiling_path),
        "pipeline": evidence(pipeline_path),
    }
    gate_status = {gate: "passed" for gate in REQUIRED_GATES}
    gate_status["package-integrity"] = "blocked"
    gate_status["clean-environment"] = "blocked"
    gate_status["typed-pipeline-contract"] = "blocked"
    for gate in (
        "fresh-invocations",
        "specialization-residency-function",
        "cancellation-cleanup",
        "text-to-image-no-vae-encoder",
    ):
        gate_status[gate] = "blocked"
    gate_evidence = {
        "source-hashes": [f"source-lock.json:sha256:{sha256_file(Path(args.lock))}"],
        "tokenizer-chat-template": [report_evidence["prompt"]],
        "prompt-encoder-parity": [report_evidence["prompt"]],
        "denoiser-parity": [report_evidence["denoiser"]],
        "vae-encoder-parity": [report_evidence["encoder"], report_evidence["encoderTiling"]],
        "vae-decoder-parity": [report_evidence["decoder"], report_evidence["decoderTiling"]],
        "glue-unit-tests": [
            f"{glue_test_evidence['file']}:sha256:{glue_test_evidence['digest']};"
            f"tests:{glue_test_evidence['testCount']};"
            f"tools:{glue_test_evidence['toolDigest']}"
        ],
        "typed-pipeline-contract": [
            "pipeline schema 1.0 declares named but untyped ports; typed operation signatures are not implemented"
        ],
        "pipeline-parity": [report_evidence["pipeline"]],
        "repeatability": [report_evidence["pipeline"]],
        "text-to-image-no-vae-encoder": [
            "pipeline validator does not trace component loads and invocations"
        ],
        "resolution-matrix": [report_evidence["pipeline"]],
        "fresh-invocations": [
            "pipeline validator does not instrument independent model-instance creation and state reset"
        ],
        "specialization-residency-function": [
            "pipeline validator does not measure function-level specialization residency/cache behavior"
        ],
        "cancellation-cleanup": [
            "pipeline validator does not synchronize cancellation with confirmed native execution and resource release"
        ],
        "performance-recorded": [report_evidence["pipeline"]],
        "package-integrity": ["pending atomic assembly finalization"],
        "clean-environment": ["pending atomic assembly finalization"],
    }
    return {
        "schemaVersion": "1.0.0",
        "packageIdentifier": PACKAGE_ID,
        "complete": False,
        "decoderStrategy": pipeline.get("decoderStrategy", "overlapped-tiles"),
        "system": pipeline["system"],
        "gates": [
            {
                "id": gate,
                "status": gate_status[gate],
                "evidence": gate_evidence[gate],
                **(
                    {
                        "detail": "Structural graph validation does not prove tensor/parameter type compatibility across node edges."
                    }
                    if gate == "typed-pipeline-contract"
                    else {
                        "detail": runtime_evidence[
                            {
                                "fresh-invocations": "freshInvocations",
                                "specialization-residency-function": "specializationResidencyFunction",
                                "cancellation-cleanup": "cancellationCleanup",
                                "text-to-image-no-vae-encoder": "textToImageSkippedVAEEncoder",
                            }[gate]
                        ]["detail"]
                    }
                    if gate
                    in {
                        "fresh-invocations",
                        "specialization-residency-function",
                        "cancellation-cleanup",
                        "text-to-image-no-vae-encoder",
                    }
                    else {}
                ),
            }
            for gate in sorted(REQUIRED_GATES)
        ],
        "exports": export_reports,
        "components": components,
        "resolutionMatrix": [
            {
                "width": width, "height": height, "status": item["status"],
                "native": item["native"], "resampled": item["resampled"],
                "imageTokens": item["imageTokens"], "outputSHA256": item["outputSHA256"],
                "durationSeconds": item["durationSeconds"],
            }
            for (width, height), item in sorted(resolution_results.items())
        ],
        "performance": pipeline["performance"],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--publisher-reference", required=True)
    parser.add_argument("--apple-reference", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--prompt-report", required=True)
    parser.add_argument("--denoiser-report", required=True)
    parser.add_argument("--vae-encoder-report", required=True)
    parser.add_argument("--vae-decoder-report", required=True)
    parser.add_argument("--vae-encoder-tiling-report", required=True)
    parser.add_argument("--vae-decoder-tiling-report", required=True)
    parser.add_argument("--pipeline-report", required=True)
    parser.add_argument("--glue-test-log", required=True)
    parser.add_argument("--prompt-export-report", required=True)
    parser.add_argument("--denoiser-export-report", required=True)
    parser.add_argument("--vae-encoder-export-report", required=True)
    parser.add_argument("--vae-decoder-export-report", required=True)
    parser.add_argument("--output", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.output = str(outside_checkout(Path(args.output)))
        output = prepare_atomic_new_json(
            Path(args.output), "pre-assembly validation record"
        )
        for attribute in ("source", "publisher_reference", "apple_reference", "lock"):
            setattr(
                args,
                attribute,
                str(guarded_resolve(Path(getattr(args, attribute)))),
            )
        for attribute in (
            "prompt_report",
            "denoiser_report",
            "vae_encoder_report",
            "vae_decoder_report",
            "vae_encoder_tiling_report",
            "vae_decoder_tiling_report",
            "pipeline_report",
            "glue_test_log",
            "prompt_export_report",
            "denoiser_export_report",
            "vae_encoder_export_report",
            "vae_decoder_export_report",
        ):
            setattr(
                args,
                attribute,
                str(outside_checkout(Path(getattr(args, attribute)))),
            )
        record = make_record(args)
        validate_schema(record, load_json(VALIDATION_SCHEMA))
        write_atomic_new_json(output, record)
        print(f"wrote pre-assembly validation record: {output}")
    except (ContractError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
