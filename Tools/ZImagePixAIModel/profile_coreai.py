#!/usr/bin/env python3
"""Profile a DEBUG tiny-denoiser Core AI probe using public runtime APIs.

The public profiler reports runtime event identifiers and event metadata. It
does not expose authoritative per-operation CPU, GPU, or Neural Engine
placement, so this tool preserves the raw events and makes no stronger claim.
Production RELEASE assets and full denoisers are deliberately rejected before
Core AI is loaded.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import json
import math
import os
import platform
import resource
import subprocess
import sys
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from export_components import (
    DEBUG_METADATA_KEY,
    _denoiser_inputs,
    dtype_for_precision,
    profiler_probe_metadata,
)
from pixaimodel import ContractError, HERE, load_json, sha256_file, sha256_tree
from run_validation_subprocess import (
    guarded_resolve,
    outside_checkout,
    validate_evidence_paths,
    write_atomic_new_json,
)


DIAGNOSTIC = "core-ai-public-profiler"
FUNCTION_NAME = "main"


def _strict_json_value(value: Any) -> Any:
    """Convert callback values without ever emitting NaN or Infinity."""

    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): _strict_json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_strict_json_value(item) for item in value]
    return str(value)


def _metadata_marker(metadata: dict[str, Any]) -> Any:
    if DEBUG_METADATA_KEY in metadata:
        return metadata[DEBUG_METADATA_KEY]
    # Core AI metadata writers have used both a direct custom-key layout and a
    # named custom-metadata container. Accept either public serialized shape.
    for container_name in (
        "creatorDefinedMetadata",
        "customMetadata",
        "custom_metadata",
        "custom",
    ):
        container = metadata.get(container_name)
        if isinstance(container, dict) and DEBUG_METADATA_KEY in container:
            return container[DEBUG_METADATA_KEY]
    return None


def load_debug_probe_metadata(asset: Path) -> dict[str, Any]:
    metadata_path = asset / "metadata.json"
    if metadata_path.is_symlink() or not metadata_path.is_file():
        raise ContractError(f"Core AI metadata is missing or unsafe: {metadata_path}")
    metadata = load_json(metadata_path)
    if not isinstance(metadata, dict):
        raise ContractError("Core AI metadata must be a JSON object")
    marker = _metadata_marker(metadata)
    if not isinstance(marker, dict):
        raise ContractError(
            "asset is not a profiler-enabled DEBUG probe; missing "
            f"{DEBUG_METADATA_KEY!r} metadata"
        )

    precision = marker.get("precision")
    if precision not in {"float16", "bfloat16", "float32"}:
        raise ContractError(f"invalid DEBUG probe precision: {precision!r}")
    expected = profiler_probe_metadata(precision)
    for key, value in expected.items():
        if marker.get(key) != value:
            raise ContractError(
                f"invalid DEBUG probe metadata {key}: "
                f"expected {value!r}, found {marker.get(key)!r}"
            )
    return marker


def validate_export_report(
    path: Path,
    *,
    asset: Path,
    asset_digest: str,
    marker: dict[str, Any],
) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"DEBUG probe export report is missing or unsafe: {path}")
    report = load_json(path)
    if not isinstance(report, dict):
        raise ContractError("DEBUG probe export report must be a JSON object")
    expected = {
        "schemaVersion": "1.0.0",
        "component": "denoiser",
        "variant": "tiny-probe",
        "probe": True,
        "debugExport": True,
        "converterMode": "debug",
        "profilerProbe": marker,
        "precision": marker["precision"],
        "sourceRevision": None,
        "sourceFiles": [],
        "artifact": asset.name,
        "digestAlgorithm": "sha256-tree-v1",
        "digest": asset_digest,
    }
    for key, value in expected.items():
        if report.get(key) != value:
            raise ContractError(
                f"DEBUG probe export report {key} mismatch: "
                f"expected {value!r}, found {report.get(key)!r}"
            )
    return report


class ProfileEventRecorder:
    """Thread-safe adapter for all three public Core AI profiler callbacks."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._next_sequence = 0
        self._next_interval = 1
        self._events: list[dict[str, Any]] = []
        self._errors: list[dict[str, str]] = []

    def _property(self, event: Any, name: str, callback: str) -> Any:
        try:
            return getattr(event, name)
        except Exception as error:
            self._errors.append(
                {
                    "callback": callback,
                    "property": name,
                    "type": type(error).__name__,
                    "message": str(error),
                }
            )
            return None

    def _append(self, event: Any, callback: str, interval_id: int | None) -> None:
        event_id_value = self._property(event, "event_id", callback)
        event_id = None if event_id_value is None else str(event_id_value)
        compile_ids_record = None
        # coreai-core 1.0.0b2 terminates the process when compile_ids is read
        # from some non-call events (notably Compute Stream Wait). Restrict the
        # documented property read to backend call events, where it is valid.
        if event_id is not None and event_id.startswith("call."):
            compile_ids = self._property(event, "compile_ids", callback)
            if compile_ids is not None:
                identifier = self._property(compile_ids, "id", callback)
                delegate_id = self._property(compile_ids, "delegate_id", callback)
                compile_ids_record = {
                    "id": _strict_json_value(identifier),
                    "delegateID": _strict_json_value(delegate_id),
                }
        self._events.append(
            {
                "sequence": self._next_sequence,
                "callback": callback,
                "intervalID": interval_id,
                "timestamp": _strict_json_value(
                    self._property(event, "timestamp", callback)
                ),
                "eventID": event_id,
                "phase": _strict_json_value(self._property(event, "phase", callback)),
                "data": _strict_json_value(self._property(event, "data", callback)),
                "metadata": _strict_json_value(
                    self._property(event, "metadata", callback)
                ),
                "compileIDs": compile_ids_record,
            }
        )
        self._next_sequence += 1

    def on_log_event(self, event: Any) -> None:
        with self._lock:
            self._append(event, "single", None)

    def on_log_event_begin(self, event: Any) -> int:
        with self._lock:
            interval_id = self._next_interval
            self._next_interval += 1
            self._append(event, "begin", interval_id)
            return interval_id

    def on_log_event_end(self, event: Any, interval_id: int) -> None:
        with self._lock:
            self._append(event, "end", int(interval_id))

    @property
    def events(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(item) for item in self._events]

    @property
    def errors(self) -> list[dict[str, str]]:
        with self._lock:
            return [dict(item) for item in self._errors]


def create_profiler(runtime: Any, recorder: ProfileEventRecorder) -> Any:
    """Construct the pinned runtime profiler with every callback populated."""

    # coreai-core 1.0.0b2 documents each callback as optional, but its native
    # bridge calls all three unconditionally. Supplying all callbacks avoids a
    # NoneType exception at the Python boundary.
    return runtime.Profiler(
        on_log_event=recorder.on_log_event,
        on_log_event_begin=recorder.on_log_event_begin,
        on_log_event_end=recorder.on_log_event_end,
    )


def summarize_backend_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    event_ids = sorted(
        {
            event_id
            for event in events
            if isinstance((event_id := event.get("eventID")), str)
        }
    )
    bnns = [
        event_id
        for event_id in event_ids
        if event_id == "call.BNNS" or event_id.startswith("bnns.")
    ]
    mpsgraph_ids = {"call.$MPSGraph", "call.!MPSGraph", "call.MPSGraph"}
    mpsgraph = [event_id for event_id in event_ids if event_id in mpsgraph_ids]
    families = []
    if bnns:
        families.append("BNNS")
    if mpsgraph:
        families.append("MPSGraph")

    if families:
        observed = " and ".join(families)
        conclusion = (
            f"Public profiler event IDs identify {observed} backend regions. "
            "They do not report authoritative per-operation CPU, GPU, or "
            "Neural Engine placement."
        )
    else:
        conclusion = (
            "No recognized BNNS or MPSGraph backend event ID was observed. "
            "Requested compute preference and diagnostic text are not "
            "realized-placement evidence."
        )
    return {
        "eventIDs": event_ids,
        "backendEventIDs": {"BNNS": bnns, "MPSGraph": mpsgraph},
        "observedBackendFamilies": families,
        "placementConclusion": conclusion,
    }


def output_record(value: Any) -> dict[str, Any]:
    array = np.asarray(value.numpy())
    comparison = array.astype(np.float32, copy=False)
    finite = np.isfinite(comparison)
    finite_count = int(finite.sum())
    element_count = int(comparison.size)
    record: dict[str, Any] = {
        "dtype": str(getattr(value, "dtype", array.dtype)),
        "shape": [int(dimension) for dimension in array.shape],
        "elementCount": element_count,
        "finiteCount": finite_count,
        "nonFiniteCount": element_count - finite_count,
        "minimumFinite": None,
        "maximumFinite": None,
        "meanFinite": None,
        "status": (
            "passed"
            if element_count > 0 and finite_count == element_count
            else "failed"
        ),
    }
    if finite_count:
        finite_values = comparison[finite]
        record.update(
            {
                "minimumFinite": float(finite_values.min()),
                "maximumFinite": float(finite_values.max()),
                "meanFinite": float(finite_values.astype(np.float64).mean()),
            }
        )
    return record


def validate_probe_outputs(
    outputs: dict[str, dict[str, Any]], marker: dict[str, Any]
) -> None:
    if set(outputs) != {"noise_prediction"}:
        raise ContractError(
            "DEBUG probe output names mismatch: expected ['noise_prediction'], "
            f"found {sorted(outputs)}"
        )
    output = outputs["noise_prediction"]
    expected_shape = [1, marker["imageTokens"], 64]
    expected_elements = marker["imageTokens"] * 64
    expected = {
        "dtype": marker["precision"],
        "shape": expected_shape,
        "elementCount": expected_elements,
        "nonFiniteCount": 0,
        "status": "passed",
    }
    for key, value in expected.items():
        if output.get(key) != value:
            raise ContractError(
                f"DEBUG probe output {key} mismatch: "
                f"expected {value!r}, found {output.get(key)!r}"
            )
    if output["elementCount"] <= 0:
        raise ContractError("DEBUG probe output must not be empty")


def _descriptor_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return _strict_json_value(value)
    if isinstance(value, (list, tuple)):
        return [_descriptor_value(item) for item in value]
    return str(value)


def describe_function(function: Any) -> dict[str, Any]:
    description = function.desc

    def entries(names: Any, lookup: Any) -> list[dict[str, Any]]:
        values = []
        for name in names:
            item = lookup(name)
            shape = _descriptor_value(item.shape)
            values.append(
                {
                    "name": name,
                    "dtype": _descriptor_value(item.dtype),
                    "rank": len(shape),
                    "shape": shape,
                }
            )
        return values

    return {
        "name": description.name,
        "inputs": entries(description.input_names, description.input_descriptor),
        "outputs": entries(description.output_names, description.output_descriptor),
    }


def validate_probe_descriptor(
    descriptor: dict[str, Any], marker: dict[str, Any]
) -> None:
    expected_inputs = {
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
    observed_inputs = {
        item["name"]: item for item in descriptor.get("inputs", [])
    }
    if set(observed_inputs) != set(expected_inputs):
        raise ContractError(
            "DEBUG probe descriptor input mismatch: "
            f"expected {sorted(expected_inputs)}, found {sorted(observed_inputs)}"
        )
    for name, rank in expected_inputs.items():
        if observed_inputs[name].get("rank") != rank:
            raise ContractError(
                f"DEBUG probe input {name!r} rank mismatch: "
                f"expected {rank}, found {observed_inputs[name].get('rank')!r}"
            )
    expected_dtypes = {
        "image_tokens": marker["precision"],
        "image_padding_mask": "bool",
        "prompt_embeddings": marker["precision"],
        "prompt_padding_mask": "bool",
        "prompt_attention_mask": "bool",
        "timestep": "float32",
        "image_rope_cos": "float32",
        "image_rope_sin": "float32",
        "prompt_rope_cos": "float32",
        "prompt_rope_sin": "float32",
    }
    for name, dtype in expected_dtypes.items():
        if observed_inputs[name].get("dtype") != dtype:
            raise ContractError(
                f"DEBUG probe input {name!r} dtype mismatch: "
                f"expected {dtype}, found {observed_inputs[name].get('dtype')!r}"
            )
    prompt_shape = observed_inputs["prompt_embeddings"].get("shape")
    if (
        not isinstance(prompt_shape, list)
        or not prompt_shape
        or prompt_shape[-1] != marker["promptWidth"]
    ):
        raise ContractError(
            "DEBUG probe prompt width mismatch: "
            f"expected {marker['promptWidth']}, found {prompt_shape!r}"
        )
    outputs = descriptor.get("outputs")
    if (
        not isinstance(outputs, list)
        or len(outputs) != 1
        or outputs[0].get("name") != "noise_prediction"
        or outputs[0].get("rank") != 3
        or outputs[0].get("dtype") != marker["precision"]
    ):
        raise ContractError(f"DEBUG probe output descriptor mismatch: {outputs!r}")


def system_record() -> dict[str, Any]:
    try:
        macos = subprocess.run(
            ["sw_vers", "-productVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        build = subprocess.run(
            ["sw_vers", "-buildVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        macos, build = platform.mac_ver()[0] or "unknown", "unknown"
    packages = {}
    for name in ("coreai-core", "coreai-torch", "numpy", "torch"):
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


def specialization_options(runtime: Any, policy: str) -> tuple[Any, dict[str, Any]]:
    if policy == "cpu-only":
        options = runtime.SpecializationOptions.cpu_only()
    elif policy == "gpu-preferred":
        options = runtime.SpecializationOptions.from_preferred_compute_unit_kind(
            runtime.ComputeUnitKind.gpu()
        )
    elif policy == "ane-preferred":
        options = runtime.SpecializationOptions.from_preferred_compute_unit_kind(
            runtime.ComputeUnitKind.neural_engine()
        )
    else:
        raise ContractError(f"unsupported PIXELTJE_COREAI_COMPUTE policy: {policy}")
    options = options.with_debug(enabled=True)
    preferred = options.preferred_compute_unit_kind
    return options, {
        "allowedComputeUnits": [
            str(kind) for kind in options.allowed_compute_unit_kinds
        ],
        "preferredComputeUnit": None if preferred is None else str(preferred),
        "debug": True,
    }


def _input_record(value: Any) -> dict[str, Any]:
    return {
        "dtype": str(value.dtype).removeprefix("torch."),
        "shape": [int(dimension) for dimension in value.shape],
    }


def _peak_resident_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value * 1024 if sys.platform.startswith("linux") else value


def _error_record(stage: str, error: BaseException) -> dict[str, str]:
    return {
        "stage": stage,
        "type": type(error).__name__,
        "message": str(error),
    }


async def profile_asset(
    *,
    asset: Path,
    asset_digest: str,
    export_report_path: Path,
    export_report: dict[str, Any],
    marker: dict[str, Any],
    compute_policy: str,
) -> dict[str, Any]:
    started_utc = datetime.now(UTC).isoformat()
    started = time.perf_counter()
    recorder = ProfileEventRecorder()
    errors: list[dict[str, str]] = []
    descriptor = None
    input_descriptors = None
    output_records: dict[str, dict[str, Any]] = {}
    output_contract_valid = False
    specialization = None
    load_seconds = None
    load_function_seconds = None
    invoke_seconds = None
    asset_digest_after = None

    try:
        import coreai.runtime as runtime

        options, specialization = specialization_options(runtime, compute_policy)
        profiler = create_profiler(runtime, recorder)
        load_started = time.perf_counter()
        model = await runtime.AIModel.load(str(asset), options)
        load_seconds = time.perf_counter() - load_started
        if FUNCTION_NAME not in model.function_names:
            raise ContractError(
                f"DEBUG probe lacks {FUNCTION_NAME!r}: {model.function_names}"
            )
        load_function_started = time.perf_counter()
        function = model.load_function(FUNCTION_NAME, profiler=profiler)
        load_function_seconds = time.perf_counter() - load_function_started
        descriptor = describe_function(function)
        validate_probe_descriptor(descriptor, marker)

        inputs = _denoiser_inputs(
            dtype_for_precision(marker["precision"]),
            prompt_width=marker["promptWidth"],
            prompt_bucket=marker["promptBucket"],
        )
        input_descriptors = {
            name: _input_record(value) for name, value in inputs.items()
        }
        runtime_inputs = {
            name: runtime.NDArray(value.detach().cpu().contiguous())
            for name, value in inputs.items()
        }
        invoke_started = time.perf_counter()
        outputs = await function(inputs=runtime_inputs)
        invoke_seconds = time.perf_counter() - invoke_started
        output_records = {
            name: output_record(value) for name, value in outputs.items()
        }
        validate_probe_outputs(output_records, marker)
        output_contract_valid = True
    except Exception as error:
        errors.append(_error_record("core-ai-profile", error))

    try:
        asset_digest_after = sha256_tree(asset)
        if asset_digest_after != asset_digest:
            raise ContractError(
                "Core AI asset changed during profiling: "
                f"{asset_digest} -> {asset_digest_after}"
            )
    except Exception as error:
        errors.append(_error_record("asset-integrity", error))

    events = recorder.events
    callback_errors = recorder.errors
    event_summary = summarize_backend_events(events)
    event_result = {
        "name": "profiler-events",
        "eventCount": len(events),
        "callbackErrorCount": len(callback_errors),
        "status": (
            "passed" if events and not callback_errors else "failed"
        ),
    }
    output_result = {
        "name": "finite-output",
        "outputs": output_records,
        "status": (
            "passed"
            if output_contract_valid
            and output_records
            and all(item["status"] == "passed" for item in output_records.values())
            else "failed"
        ),
    }
    integrity_result = {
        "name": "asset-integrity",
        "digestBefore": asset_digest,
        "digestAfter": asset_digest_after,
        "status": (
            "passed" if asset_digest_after == asset_digest else "failed"
        ),
    }
    results = [event_result, output_result, integrity_result]
    status = (
        "passed"
        if not errors
        and not callback_errors
        and all(item["status"] == "passed" for item in results)
        else "failed"
    )
    return {
        "schemaVersion": "1.0.0",
        "diagnostic": DIAGNOSTIC,
        "component": "denoiser",
        "probeOnly": True,
        "status": status,
        "asset": str(asset),
        "assetDigestAlgorithm": "sha256-tree-v1",
        "assetDigest": asset_digest,
        "assetDigestAfter": asset_digest_after,
        "assetUnchanged": asset_digest_after == asset_digest,
        "exportReport": {
            "path": str(export_report_path),
            "sha256": sha256_file(export_report_path),
            "converterMode": export_report["converterMode"],
        },
        "computePolicy": compute_policy,
        "specialization": specialization,
        "functionName": FUNCTION_NAME,
        "descriptor": descriptor,
        "inputCase": {
            "kind": "tiny-denoiser-deterministic-inputs",
            "metadata": marker,
            "inputs": input_descriptors,
        },
        "outputs": output_records,
        "events": events,
        "callbackErrors": callback_errors,
        "callbackCounts": {
            name: sum(item["callback"] == name for item in events)
            for name in ("single", "begin", "end")
        },
        "observedBackendEvents": event_summary,
        "results": results,
        "errors": errors,
        "timings": {
            "loadSeconds": load_seconds,
            "loadFunctionSeconds": load_function_seconds,
            "invokeSeconds": invoke_seconds,
            "totalSeconds": time.perf_counter() - started,
        },
        "peakResidentBytes": _peak_resident_bytes(),
        "sourceLockSHA256": sha256_file(HERE / "source-lock.json"),
        "toolSHA256": sha256_file(Path(__file__).resolve()),
        "commandArguments": sys.argv[1:],
        "startedUTC": started_utc,
        "finishedUTC": datetime.now(UTC).isoformat(),
        "system": system_record(),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset", required=True, help="profiler-enabled DEBUG probe .aimodel")
    parser.add_argument(
        "--export-report",
        help="matching DEBUG export report; defaults beside the asset",
    )
    parser.add_argument("--report", required=True, help="new strict-JSON report outside Git")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        lexical_asset = Path(os.path.abspath(os.path.expanduser(args.asset)))
        if lexical_asset.is_symlink():
            raise ContractError(f"Core AI asset must not be a symlink: {lexical_asset}")
        asset = outside_checkout(lexical_asset)
        if asset.suffix != ".aimodel" or not asset.is_dir():
            raise ContractError(f"invalid Core AI DEBUG probe asset: {asset}")
        marker = load_debug_probe_metadata(asset)
        asset_digest = sha256_tree(asset)

        if args.export_report:
            export_report_path = outside_checkout(Path(args.export_report))
        else:
            export_report_path = asset.with_suffix(".export.json")
        export_report = validate_export_report(
            export_report_path,
            asset=asset,
            asset_digest=asset_digest,
            marker=marker,
        )

        report_path = outside_checkout(Path(args.report))
        validate_evidence_paths(asset, {"report": report_path})
        if report_path.exists():
            raise ContractError(f"refusing to replace existing report: {report_path}")
        report_path.parent.mkdir(parents=True, exist_ok=True)
        compute_policy = os.environ.get(
            "PIXELTJE_COREAI_COMPUTE", "gpu-preferred"
        )
        if compute_policy not in {"cpu-only", "gpu-preferred", "ane-preferred"}:
            raise ContractError(
                "PIXELTJE_COREAI_COMPUTE must be cpu-only, gpu-preferred, "
                f"or ane-preferred; found {compute_policy!r}"
            )
    except (ContractError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    report = asyncio.run(
        profile_asset(
            asset=asset,
            asset_digest=asset_digest,
            export_report_path=export_report_path,
            export_report=export_report,
            marker=marker,
            compute_policy=compute_policy,
        )
    )
    try:
        write_atomic_new_json(report_path, report)
    except (ContractError, OSError, ValueError) as error:
        print(f"error: cannot write profiler report: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, allow_nan=False, indent=2, sort_keys=True))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
