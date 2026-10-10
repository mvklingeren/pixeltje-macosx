from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

_coreai_modules_before = frozenset(
    name for name in sys.modules if name == "coreai" or name.startswith("coreai.")
)

from pixaimodel import ContractError, canonical_json_bytes  # noqa: E402
import profile_coreai  # noqa: E402
from profile_coreai import (  # noqa: E402
    DEBUG_METADATA_KEY,
    ProfileEventRecorder,
    create_profiler,
    describe_function,
    load_debug_probe_metadata,
    output_record,
    specialization_options,
    summarize_backend_events,
    validate_export_report,
    validate_probe_descriptor,
    validate_probe_outputs,
)

_coreai_modules_after = frozenset(
    name for name in sys.modules if name == "coreai" or name.startswith("coreai.")
)


class FakeCompileIdentifiers:
    def __init__(self, identifier: int, delegate_id: int | None) -> None:
        self.id = identifier
        self.delegate_id = delegate_id


class FakeEvent:
    def __init__(
        self,
        event_id: str,
        *,
        timestamp: int = 10,
        phase: str = "complete",
        data: str = "",
        metadata: dict[str, str] | None = None,
        compile_ids: FakeCompileIdentifiers | None = None,
        forbid_compile_ids: bool = False,
    ) -> None:
        self.timestamp = timestamp
        self.event_id = event_id
        self.phase = phase
        self.data = data
        self.metadata = metadata or {}
        self._compile_ids = compile_ids
        self._forbid_compile_ids = forbid_compile_ids
        self.compile_ids_reads = 0

    @property
    def compile_ids(self) -> FakeCompileIdentifiers | None:
        self.compile_ids_reads += 1
        if self._forbid_compile_ids:
            raise AssertionError("compile_ids must not be read for this event")
        return self._compile_ids


class FakeRuntimeValue:
    def __init__(self, value: np.ndarray) -> None:
        self._value = value

    def numpy(self) -> np.ndarray:
        return self._value


class FakeProfiler:
    def __init__(self, **callbacks: object) -> None:
        self.callbacks = callbacks


class FakeRuntime:
    Profiler = FakeProfiler


class FakeArrayDescriptor:
    def __init__(self, shape: list[int | None], dtype: str) -> None:
        self.shape = shape
        self.dtype = dtype


class FakeFunctionDescriptor:
    name = "main"
    input_names = ["value"]
    output_names = ["result"]

    def input_descriptor(self, _name: str) -> FakeArrayDescriptor:
        return FakeArrayDescriptor([1, None, 64], "bfloat16")

    def output_descriptor(self, _name: str) -> FakeArrayDescriptor:
        return FakeArrayDescriptor([1, None, 64], "bfloat16")


class FakeFunction:
    desc = FakeFunctionDescriptor()


class FakeComputeKind:
    def __init__(self, name: str) -> None:
        self.name = name

    def __str__(self) -> str:
        return self.name


class FakeComputeUnitKind:
    @staticmethod
    def cpu() -> FakeComputeKind:
        return FakeComputeKind("CPU")

    @staticmethod
    def gpu() -> FakeComputeKind:
        return FakeComputeKind("GPU")

    @staticmethod
    def neural_engine() -> FakeComputeKind:
        return FakeComputeKind("Neural Engine")


class FakeOptions:
    def __init__(self, preferred: FakeComputeKind | None, cpu_only: bool) -> None:
        self.preferred_compute_unit_kind = preferred
        self.allowed_compute_unit_kinds = (
            [FakeComputeKind("CPU")]
            if cpu_only
            else [
                FakeComputeKind("CPU"),
                FakeComputeKind("GPU"),
                FakeComputeKind("Neural Engine"),
            ]
        )
        self.debug_enabled = False

    def with_debug(self, *, enabled: bool) -> FakeOptions:
        self.debug_enabled = enabled
        return self


class FakeSpecializationOptions:
    @classmethod
    def cpu_only(cls) -> FakeOptions:
        return FakeOptions(None, cpu_only=True)

    @classmethod
    def from_preferred_compute_unit_kind(
        cls, preferred: FakeComputeKind
    ) -> FakeOptions:
        return FakeOptions(preferred, cpu_only=False)


class FakeSpecializationRuntime:
    ComputeUnitKind = FakeComputeUnitKind
    SpecializationOptions = FakeSpecializationOptions


class ProfileCoreAITests(unittest.TestCase):
    def write_asset_metadata(
        self, root: Path, profiler_metadata: object | None
    ) -> Path:
        asset = root / "probe.aimodel"
        asset.mkdir()
        metadata: dict[str, object] = {"assetVersion": "2.0"}
        if profiler_metadata is not None:
            metadata[DEBUG_METADATA_KEY] = profiler_metadata
        (asset / "metadata.json").write_bytes(canonical_json_bytes(metadata))
        return asset

    def valid_debug_metadata(self) -> dict[str, object]:
        return {
            "schemaVersion": "1.0.0",
            "component": "denoiser",
            "variant": "tiny-probe",
            "probe": True,
            "converterMode": "debug",
            "precision": "bfloat16",
            "imageResolution": {"width": 512, "height": 512},
            "imageTokens": 1024,
            "promptBucket": 64,
            "promptWidth": 64,
        }

    def valid_descriptor(self) -> dict[str, object]:
        marker = self.valid_debug_metadata()
        ranks = {
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
        dtypes = {
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
        inputs = []
        for name, rank in ranks.items():
            shape = [1] * rank
            if name == "prompt_embeddings":
                shape[-1] = 64
            inputs.append(
                {"name": name, "rank": rank, "dtype": dtypes[name], "shape": shape}
            )
        return {
            "name": "main",
            "inputs": inputs,
            "outputs": [
                {
                    "name": "noise_prediction",
                    "rank": 3,
                    "dtype": marker["precision"],
                    "shape": [1, None, 64],
                }
            ],
        }

    def test_importing_profiler_helpers_does_not_import_coreai(self) -> None:
        self.assertEqual(_coreai_modules_after, _coreai_modules_before)

    def test_debug_metadata_key_and_valid_probe_contract(self) -> None:
        self.assertEqual(DEBUG_METADATA_KEY, "pixeltjeProfiler")
        with tempfile.TemporaryDirectory() as temporary:
            expected = self.valid_debug_metadata()
            asset = self.write_asset_metadata(Path(temporary), expected)

            self.assertEqual(load_debug_probe_metadata(asset), expected)

    def test_observed_creator_defined_metadata_layout_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "probe.aimodel"
            asset.mkdir()
            expected = self.valid_debug_metadata()
            (asset / "metadata.json").write_bytes(
                canonical_json_bytes(
                    {"creatorDefinedMetadata": {DEBUG_METADATA_KEY: expected}}
                )
            )

            self.assertEqual(load_debug_probe_metadata(asset), expected)

    def test_function_descriptor_uses_only_public_shape_and_dtype(self) -> None:
        description = describe_function(FakeFunction())

        self.assertEqual(description["inputs"][0]["shape"], [1, None, 64])
        self.assertEqual(description["inputs"][0]["rank"], 3)
        self.assertEqual(description["inputs"][0]["dtype"], "bfloat16")
        self.assertNotIn("storageKind", description["inputs"][0])

    def test_probe_descriptor_rejects_full_width_and_wrong_dtype(self) -> None:
        marker = self.valid_debug_metadata()
        descriptor = self.valid_descriptor()
        validate_probe_descriptor(descriptor, marker)

        for name, value in (("shape", [1, None, 2560]), ("dtype", "float16")):
            invalid = self.valid_descriptor()
            prompt = next(
                item
                for item in invalid["inputs"]  # type: ignore[index]
                if item["name"] == "prompt_embeddings"
            )
            prompt[name] = value
            with self.subTest(name=name), self.assertRaises(ContractError):
                validate_probe_descriptor(invalid, marker)

    def test_export_report_is_bound_to_debug_asset_digest(self) -> None:
        marker = self.valid_debug_metadata()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "probe.aimodel"
            asset.mkdir()
            path = root / "probe.export.json"
            report = {
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
                "digest": "expected-digest",
            }
            path.write_bytes(canonical_json_bytes(report))

            self.assertEqual(
                validate_export_report(
                    path,
                    asset=asset,
                    asset_digest="expected-digest",
                    marker=marker,
                ),
                report,
            )
            report["digest"] = "other-digest"
            path.write_bytes(canonical_json_bytes(report))
            with self.assertRaisesRegex(ContractError, "digest mismatch"):
                validate_export_report(
                    path,
                    asset=asset,
                    asset_digest="expected-digest",
                    marker=marker,
                )

    def test_debug_metadata_rejects_missing_or_non_probe_contracts(self) -> None:
        invalid_values: tuple[object | None, ...] = (
            None,
            "not-an-object",
            {**self.valid_debug_metadata(), "component": "vae-decoder"},
            {**self.valid_debug_metadata(), "variant": "full-denoiser"},
            {**self.valid_debug_metadata(), "probe": False},
            {**self.valid_debug_metadata(), "converterMode": "release"},
            {**self.valid_debug_metadata(), "precision": "complex64"},
            {
                **self.valid_debug_metadata(),
                "imageResolution": {"width": 1024, "height": 1024},
            },
            {**self.valid_debug_metadata(), "imageTokens": 4096},
            {**self.valid_debug_metadata(), "promptBucket": 32},
            {**self.valid_debug_metadata(), "promptWidth": 2560},
        )
        for value in invalid_values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                asset = self.write_asset_metadata(Path(temporary), value)
                with self.assertRaises(ContractError):
                    load_debug_probe_metadata(asset)

    def test_event_recorder_uses_public_fields_and_safe_compile_ids(self) -> None:
        recorder = ProfileEventRecorder()
        call = FakeEvent(
            "call.MPSGraph",
            metadata={"backend": "mps"},
            compile_ids=FakeCompileIdentifiers(23, None),
        )
        wait = FakeEvent(
            "Compute Stream Wait",
            metadata={"syncPoint": "3"},
            forbid_compile_ids=True,
        )
        begin = FakeEvent(
            "call.!MPSGraph",
            timestamp=20,
            phase="begin",
            compile_ids=FakeCompileIdentifiers(22, 7),
        )
        end = FakeEvent(
            "call.!MPSGraph",
            timestamp=30,
            phase="end",
            compile_ids=FakeCompileIdentifiers(22, 7),
        )

        recorder.on_log_event(call)
        recorder.on_log_event(wait)
        interval_id = recorder.on_log_event_begin(begin)
        recorder.on_log_event_end(end, interval_id)

        self.assertIsInstance(interval_id, int)
        self.assertEqual([item["sequence"] for item in recorder.events], [0, 1, 2, 3])
        self.assertEqual(
            [item["eventID"] for item in recorder.events],
            ["call.MPSGraph", "Compute Stream Wait", "call.!MPSGraph", "call.!MPSGraph"],
        )
        self.assertEqual(
            recorder.events[0]["compileIDs"],
            {"id": 23, "delegateID": None},
        )
        self.assertIsNone(recorder.events[1]["compileIDs"])
        self.assertEqual(wait.compile_ids_reads, 0)
        self.assertEqual(recorder.events[2]["intervalID"], interval_id)
        self.assertEqual(recorder.events[3]["intervalID"], interval_id)

    def test_profiler_populates_all_three_callbacks(self) -> None:
        recorder = ProfileEventRecorder()
        profiler = create_profiler(FakeRuntime, recorder)

        self.assertEqual(
            set(profiler.callbacks),
            {"on_log_event", "on_log_event_begin", "on_log_event_end"},
        )
        self.assertTrue(all(callable(value) for value in profiler.callbacks.values()))

    def test_backend_summary_uses_event_ids_not_ane_warning_text(self) -> None:
        events = [
            {
                "eventID": "warning",
                "data": "ANE I/O op can only do F16 MemRef <-> F32 Tensor cast",
                "metadata": {"message": "ANE specialization rejected"},
            },
            {"eventID": "call.MPSGraph", "data": "", "metadata": {}},
            {"eventID": "call.MPSGraph", "data": "duplicate", "metadata": {}},
        ]

        summary = summarize_backend_events(events)

        self.assertEqual(summary["eventIDs"], ["call.MPSGraph", "warning"])
        self.assertEqual(
            summary["backendEventIDs"],
            {"BNNS": [], "MPSGraph": ["call.MPSGraph"]},
        )
        self.assertEqual(summary["observedBackendFamilies"], ["MPSGraph"])
        self.assertIn("MPSGraph", summary["placementConclusion"])
        self.assertNotIn("Neural Engine execution", summary["placementConclusion"])

    def test_backend_summary_reports_mixed_bnns_and_mpsgraph_without_ane(self) -> None:
        events = [
            {"eventID": "bnns.matmul.execute", "data": "", "metadata": {}},
            {"eventID": "call.BNNS", "data": "", "metadata": {}},
            {"eventID": "call.!MPSGraph", "data": "", "metadata": {}},
            {"eventID": "call.$MPSGraph", "data": "", "metadata": {}},
        ]

        summary = summarize_backend_events(events)

        self.assertEqual(summary["observedBackendFamilies"], ["BNNS", "MPSGraph"])
        self.assertEqual(
            summary["backendEventIDs"],
            {
                "BNNS": ["bnns.matmul.execute", "call.BNNS"],
                "MPSGraph": ["call.!MPSGraph", "call.$MPSGraph"],
            },
        )
        self.assertNotIn("ANE", summary["observedBackendFamilies"])

    def test_output_record_summarizes_finite_values(self) -> None:
        value = np.array([[1.0, -2.0, 3.5]], dtype=np.float32)
        record = output_record(FakeRuntimeValue(value))

        self.assertEqual(record["shape"], [1, 3])
        self.assertEqual(record["dtype"], "float32")
        self.assertEqual(record["elementCount"], 3)
        self.assertEqual(record["finiteCount"], 3)
        self.assertEqual(record["nonFiniteCount"], 0)
        self.assertEqual(record["minimumFinite"], -2.0)
        self.assertEqual(record["maximumFinite"], 3.5)
        self.assertEqual(record["meanFinite"], 2.5 / 3.0)
        self.assertEqual(record["status"], "passed")

    def test_output_record_keeps_nonfinite_values_out_of_json_numbers(self) -> None:
        value = np.array([np.nan, np.inf, -np.inf, 4.0], dtype=np.float32)
        record = output_record(FakeRuntimeValue(value))

        self.assertEqual(record["finiteCount"], 1)
        self.assertEqual(record["nonFiniteCount"], 3)
        self.assertEqual(record["minimumFinite"], 4.0)
        self.assertEqual(record["maximumFinite"], 4.0)
        self.assertEqual(record["meanFinite"], 4.0)
        self.assertEqual(record["status"], "failed")
        json.dumps(record, allow_nan=False)

    def test_probe_output_contract_is_exact_and_fail_closed(self) -> None:
        marker = {**self.valid_debug_metadata(), "precision": "float32"}
        record = output_record(
            FakeRuntimeValue(np.zeros((1, 1024, 64), dtype=np.float32))
        )
        validate_probe_outputs({"noise_prediction": record}, marker)

        invalid_records = (
            {"noise_prediction": {**record, "dtype": "float16"}},
            {"noise_prediction": {**record, "shape": [1, 32, 64]}},
            {"noise_prediction": {**record, "elementCount": 0}},
            {
                "noise_prediction": record,
                "unexpected": record,
            },
        )
        for invalid in invalid_records:
            with self.subTest(invalid=invalid), self.assertRaises(ContractError):
                validate_probe_outputs(invalid, marker)

    def test_specialization_policy_mapping_always_enables_debug(self) -> None:
        expected = {
            "cpu-only": (None, ["CPU"]),
            "gpu-preferred": ("GPU", ["CPU", "GPU", "Neural Engine"]),
            "ane-preferred": (
                "Neural Engine",
                ["CPU", "GPU", "Neural Engine"],
            ),
        }
        for policy, (preferred, allowed) in expected.items():
            with self.subTest(policy=policy):
                options, record = specialization_options(
                    FakeSpecializationRuntime, policy
                )
                self.assertTrue(options.debug_enabled)
                self.assertEqual(record["preferredComputeUnit"], preferred)
                self.assertEqual(record["allowedComputeUnits"], allowed)
                self.assertTrue(record["debug"])
        with self.assertRaises(ContractError):
            specialization_options(FakeSpecializationRuntime, "automatic")

    def test_profile_failure_report_initializes_every_timing(self) -> None:
        coreai_module = types.ModuleType("coreai")
        coreai_module.__path__ = []  # type: ignore[attr-defined]
        runtime_module = types.ModuleType("coreai.runtime")
        coreai_module.runtime = runtime_module  # type: ignore[attr-defined]

        class FailingAIModel:
            @staticmethod
            async def load(_asset: str, _options: object) -> object:
                raise RuntimeError("synthetic load failure")

        runtime_module.AIModel = FailingAIModel  # type: ignore[attr-defined]
        marker = self.valid_debug_metadata()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = self.write_asset_metadata(root, marker)
            export_report = root / "probe.export.json"
            export_report.write_bytes(
                canonical_json_bytes({"converterMode": "debug"})
            )
            asset_digest = profile_coreai.sha256_tree(asset)
            with (
                mock.patch.dict(
                    sys.modules,
                    {"coreai": coreai_module, "coreai.runtime": runtime_module},
                ),
                mock.patch.object(
                    profile_coreai,
                    "specialization_options",
                    return_value=(object(), {"debug": True}),
                ),
                mock.patch.object(
                    profile_coreai, "create_profiler", return_value=object()
                ),
                mock.patch.object(
                    profile_coreai, "system_record", return_value={"test": True}
                ),
            ):
                report = asyncio.run(
                    profile_coreai.profile_asset(
                        asset=asset,
                        asset_digest=asset_digest,
                        export_report_path=export_report,
                        export_report={"converterMode": "debug"},
                        marker=marker,
                        compute_policy="gpu-preferred",
                    )
                )

        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["errors"][0]["stage"], "core-ai-profile")
        self.assertIsNone(report["timings"]["loadSeconds"])
        self.assertIsNone(report["timings"]["loadFunctionSeconds"])
        self.assertIsNone(report["timings"]["invokeSeconds"])
        self.assertGreaterEqual(report["timings"]["totalSeconds"], 0.0)
        self.assertTrue(report["results"])
        json.dumps(report, allow_nan=False)


if __name__ == "__main__":
    unittest.main()
