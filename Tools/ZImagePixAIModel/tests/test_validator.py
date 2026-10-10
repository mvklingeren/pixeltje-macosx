from __future__ import annotations

import json
import asyncio
import sys
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pixaimodel import (  # noqa: E402
    ContractError,
    _check_tensor_abi,
    expected_glue_test_count,
    load_json,
    safe_relative_path,
    sha256_tree,
    validate_pipeline_contract,
    verify_glue_test_log,
)
from make_validation_record import (  # noqa: E402
    require_direct_component_result_contract,
    require_blocked_pipeline_lifecycle,
    require_execution_metadata,
    require_full_denoiser_contract,
    require_metric,
    require_pipeline_result_contract,
    require_vae_tiling_contract,
)
from validate_components import (  # noqa: E402
    prompt_descriptor_matches,
    vae_descriptor_matches,
)
import validate_components  # noqa: E402


class ValidatorTests(unittest.TestCase):
    def test_numerically_passing_pipeline_is_preserved_as_lifecycle_blocked(self) -> None:
        keys = {
            "freshInvocations",
            "specializationResidencyFunction",
            "cancellationCleanup",
            "textToImageSkippedVAEEncoder",
        }
        report = {
            "schemaVersion": "1.0.0",
            "pipeline": "z-image-turbo-text-to-image",
            "status": "blocked",
            "parityStatus": "passed",
            "runtimeChecks": {key: False for key in keys},
            "runtimeEvidence": {
                key: {"status": "not-measured", "detail": "not instrumented"}
                for key in keys
            },
        }
        evidence = require_blocked_pipeline_lifecycle(
            report, Path("pipeline.json")
        )
        self.assertEqual(set(evidence), keys)

        report["runtimeChecks"]["freshInvocations"] = True
        with self.assertRaisesRegex(ContractError, "honestly mark"):
            require_blocked_pipeline_lifecycle(report, Path("pipeline.json"))

    def test_glue_log_is_bound_to_current_complete_test_suite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "glue-tests.log"
            count = expected_glue_test_count()
            path.write_text(
                f"Ran {count} tests in 1.000s\n\nOK\n", encoding="utf-8"
            )
            evidence = verify_glue_test_log(path)
            self.assertEqual(evidence["testCount"], count)
            self.assertEqual(evidence["digestAlgorithm"], "sha256")

            path.write_text(
                f"Ran {count - 1} tests in 1.000s\n\nOK\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ContractError, "all .* current tests"):
                verify_glue_test_log(path)

    def test_component_runner_records_finite_elapsed_seconds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report_path = Path(temporary) / "component.json"
            arguments = Namespace(
                component="prompt-encoder", report=str(report_path)
            )
            with mock.patch.object(
                validate_components,
                "validate_prompt_encoder",
                new=mock.AsyncMock(return_value={"status": "passed"}),
            ), redirect_stdout(StringIO()):
                self.assertEqual(asyncio.run(validate_components.run(arguments)), 0)
            report = load_json(report_path)
            self.assertIsInstance(report["elapsedSeconds"], float)
            self.assertGreaterEqual(report["elapsedSeconds"], 0.0)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "duplicate.json"
            path.write_text('{"schemaVersion":"1.0.0","schemaVersion":"2.0.0"}', encoding="utf-8")
            with self.assertRaises(ContractError):
                load_json(path)

    def test_nonfinite_json_numbers_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for spelling in ("NaN", "Infinity", "-Infinity"):
                with self.subTest(spelling=spelling):
                    path = Path(temporary) / f"{spelling}.json"
                    path.write_text(f'{{"value":{spelling}}}', encoding="utf-8")
                    with self.assertRaises(ContractError):
                        load_json(path)

    def test_report_metric_rejects_overflowed_json_number(self) -> None:
        with self.assertRaisesRegex(ContractError, "lacks numeric correlation"):
            require_metric({"correlation": float("inf")}, "correlation", "test")

    def test_package_paths_cannot_escape(self) -> None:
        for value in ("../weights", "/tmp/weights", "Components/../weights", "Components\\weights"):
            with self.subTest(value=value), self.assertRaises(ContractError):
                safe_relative_path(value)

    def test_reused_dynamic_symbol_requires_one_contract(self) -> None:
        dynamic = {"symbol": "tokens", "minimum": 32, "maximum": 512, "multipleOf": 32}
        variant = {
            "id": "dynamic",
            "inputs": [
                {"name": "input", "rank": 2, "dimensions": [1, dynamic]},
            ],
            "outputs": [
                {
                    "name": "output",
                    "rank": 2,
                    "dimensions": [
                        1,
                        {"symbol": "tokens", "minimum": 32, "maximum": 256, "multipleOf": 32},
                    ],
                },
            ],
        }
        with self.assertRaises(ContractError):
            _check_tensor_abi("denoiser", variant)

    def test_full_denoiser_report_contract_is_fail_closed(self) -> None:
        report = {
            "variant": "dynamic-image-dynamic-prompt-bucket",
            "precision": "bfloat16",
            "computationPrecision": "bfloat16-with-float32-timestep-and-rope",
            "attentionAccumulation": "model-precision",
            "computePolicy": "gpu-preferred",
            "assetDigestAlgorithm": "sha256-tree-v1",
            "assetDigest": "a" * 64,
            "results": [
                {
                    "width": 512,
                    "height": 512,
                    "validImageTokens": 1024,
                    "outputShape": [1, 1024, 64],
                    "finite": True,
                    "status": "passed",
                    "adapterToPublisherMetrics": {
                        "correlation": 1.0,
                        "peakSignalToNoiseRatio": 999.0,
                    },
                    "coreAIToPublisherMetrics": {
                        "correlation": 0.999,
                        "peakSignalToNoiseRatio": 40.0,
                    },
                    "repeatMaximumAbsoluteError": 0.0,
                },
            ],
        }
        require_full_denoiser_contract(report, Path("report.json"))
        report["results"][0]["repeatMaximumAbsoluteError"] = 1.0
        with self.assertRaises(ContractError):
            require_full_denoiser_contract(report, Path("report.json"))
        report["results"][0]["repeatMaximumAbsoluteError"] = 0.0
        report["computePolicy"] = "cpu-only"
        with self.assertRaisesRegex(ContractError, "conversion contract"):
            require_full_denoiser_contract(report, Path("report.json"))

    def test_prompt_raw_result_contract_cannot_trust_status(self) -> None:
        result = {
            "status": "passed",
            "finite": True,
            "outputShape": [1, 512, 2560],
            "repeatMaximumAbsoluteError": 0.0,
            "metrics": {
                "correlation": 0.999,
                "peakSignalToNoiseRatio": 40.0,
            },
        }
        require_direct_component_result_contract(
            "prompt-encoder", result, Path("prompt.json")
        )
        result["metrics"]["correlation"] = True
        with self.assertRaisesRegex(ContractError, "numeric correlation"):
            require_direct_component_result_contract(
                "prompt-encoder", result, Path("prompt.json")
            )

    def test_vae_raw_result_contract_enforces_all_fixed_metrics_and_shape(self) -> None:
        result = {
            "width": 1280,
            "height": 720,
            "status": "passed",
            "finite": True,
            "outputShape": [1, 16, 90, 160],
            "repeatMaximumAbsoluteError": 0.0,
            "metrics": {
                "correlation": 0.99999,
                "peakSignalToNoiseRatio": 80.0,
                "rootMeanSquaredError": 0.001,
                "maximumAbsoluteError": 0.075,
            },
        }
        require_direct_component_result_contract(
            "vae-encoder", result, Path("encoder.json")
        )
        result["metrics"]["rootMeanSquaredError"] = 0.0011
        with self.assertRaisesRegex(ContractError, "below fixed parity"):
            require_direct_component_result_contract(
                "vae-encoder", result, Path("encoder.json")
            )

    def test_execution_metadata_is_fail_closed(self) -> None:
        report = {
            "commandArguments": ["--asset", "/external/model.aimodel"],
            "startedUTC": "2026-09-11T10:00:00+00:00",
            "finishedUTC": "2026-09-11T10:00:01+00:00",
            "elapsedSeconds": 1.0,
        }
        require_execution_metadata(report, Path("report.json"))
        report["elapsedSeconds"] = float("inf")
        with self.assertRaisesRegex(ContractError, "finite elapsed"):
            require_execution_metadata(report, Path("report.json"))

    def test_pipeline_release_thresholds_cannot_be_relaxed_in_report(self) -> None:
        result = {
            "status": "passed",
            "native": True,
            "resampled": False,
            "finite": True,
            "outputShape": [1, 3, 512, 512],
            "imageTokens": 1024,
            "repeatMaximumAbsoluteError": 0.0,
            "metrics": {
                "correlation": 0.98,
                "peakSignalToNoiseRatio": 29.0,
            },
        }
        with self.assertRaisesRegex(ContractError, "fixed release parity"):
            require_pipeline_result_contract(
                result, (512, 512), Path("pipeline.json")
            )

    def test_vae_tiling_release_thresholds_cannot_be_relaxed_in_report(self) -> None:
        report = {
            "strategy": {
                "tilePixels": 1024,
                "overlapFactor": 0.25,
                "native": True,
                "resampled": False,
            },
            "comparison": {
                "status": "passed",
                "width": 1280,
                "height": 1280,
                "fullToTiledMetrics": {
                    "correlation": 0.98,
                    "peakSignalToNoiseRatio": 29.0,
                },
                "seamMetrics": {"seamToOverallRatio": 1.0},
            },
            "target": {
                "width": 2048,
                "height": 2048,
                "status": "passed",
                "finite": True,
                "outputShape": [1, 3, 2048, 2048],
                "repeatMaximumAbsoluteError": 0.0,
                "coreAIToPublisherTiledMetrics": {
                    "correlation": 1.0,
                    "maximumAbsoluteError": 0.0,
                },
                "seamMetrics": {"seamToOverallRatio": 1.0},
            },
        }
        with self.assertRaisesRegex(ContractError, "below release gates"):
            require_vae_tiling_contract(
                report, "vae-decoder", Path("tiling.json")
            )

    def test_tree_digest_is_metadata_independent_and_content_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as first_root, tempfile.TemporaryDirectory() as second_root:
            first = Path(first_root)
            second = Path(second_root)
            for root in (first, second):
                (root / "nested").mkdir()
                (root / "a").write_bytes(b"one")
                (root / "nested" / "b").write_bytes(b"two")
            self.assertEqual(sha256_tree(first), sha256_tree(second))
            (second / "nested" / "b").write_bytes(b"changed")
            self.assertNotEqual(sha256_tree(first), sha256_tree(second))

    def test_prompt_descriptor_requires_exact_release_abi(self) -> None:
        descriptor = {
            "inputs": [
                {"name": "input_ids", "dtype": "int32", "rank": 2, "shape": [1, 512]},
                {"name": "attention_mask", "dtype": "bool", "rank": 2, "shape": [1, 512]},
            ],
            "outputs": [
                {
                    "name": "prompt_embeddings",
                    "dtype": "float16",
                    "rank": 3,
                    "shape": [1, 512, 2560],
                }
            ],
        }
        self.assertTrue(prompt_descriptor_matches(descriptor))
        descriptor["inputs"][0]["dtype"] = "int64"
        self.assertFalse(prompt_descriptor_matches(descriptor))
        descriptor["inputs"][0]["dtype"] = "int32"
        descriptor["outputs"][0]["shape"] = [1, 256, 2560]
        self.assertFalse(prompt_descriptor_matches(descriptor))

    def test_vae_descriptor_requires_channels_and_dynamic_spatial_axes(self) -> None:
        encoder = {
            "inputs": [
                {"name": "image", "dtype": "float32", "rank": 4, "shape": [1, 3, -1, -1]}
            ],
            "outputs": [
                {"name": "latent", "dtype": "float32", "rank": 4, "shape": [1, 16, -1, -1]}
            ],
        }
        self.assertTrue(vae_descriptor_matches("vae-encoder", encoder))
        encoder["outputs"][0]["shape"] = [1, -1, -1, -1]
        self.assertFalse(vae_descriptor_matches("vae-encoder", encoder))

        decoder = {
            "inputs": [
                {"name": "latent", "dtype": "float32", "rank": 4, "shape": [1, 16, -1, -1]}
            ],
            "outputs": [
                {"name": "image", "dtype": "float32", "rank": 4, "shape": [1, 3, -1, -1]}
            ],
        }
        self.assertTrue(vae_descriptor_matches("vae-decoder", decoder))
        decoder["inputs"][0]["shape"] = [1, 16, 64, 64]
        self.assertFalse(vae_descriptor_matches("vae-decoder", decoder))

    def test_pipeline_configuration_rejects_executable_content(self) -> None:
        descriptor = {
            "parameters": [],
            "nodes": [{"id": "bad", "operation": "normalize", "inputs": [], "outputs": ["value"], "configuration": {"script": "run()"}}],
            "edges": [],
            "outputs": [{"id": "value", "source": "node:bad.value", "semantic": "test"}],
        }
        with self.assertRaises(ContractError):
            validate_pipeline_contract(descriptor)


if __name__ == "__main__":
    unittest.main()
