from __future__ import annotations

import argparse
import copy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from assemble import (  # noqa: E402
    assemble,
    component_manifest,
    copy_file,
    finalize_assembly_gates,
    verify_conversion_export_identities,
)
import make_validation_record as validation_builder  # noqa: E402
from make_validation_record import require_pipeline_asset_bindings  # noqa: E402
from pixaimodel import (  # noqa: E402
    ContractError,
    HERE,
    REQUIRED_EXPORT_CONTRACTS,
    REQUIRED_GATES,
    REQUIRED_RESOLUTIONS,
    UNIMPLEMENTED_REQUIRED_GATES,
    VALIDATION_SCHEMA,
    ZIMAGE_SOURCE_REVISION,
    _validate_validation_record,
    expected_glue_test_count,
    load_json,
    sha256_file,
    sha256_tree,
    validate_json_file,
    validate_schema,
    write_canonical_json,
)


COMPONENT_VARIANTS = {
    "prompt-encoder": ("fixed-512-tokens",),
    "denoiser": ("dynamic-image-dynamic-prompt-bucket",),
    "vae-encoder": (
        "direct-up-to-9216-tokens",
        "overlapped-tiles-up-to-16384-tokens",
    ),
    "vae-decoder": (
        "direct-up-to-9216-tokens",
        "overlapped-tiles-up-to-16384-tokens",
    ),
}
PARITY_CONTRACTS = {
    ("prompt-encoder", "fixed-512-tokens"): (
        "peakSignalToNoiseRatio",
        40.0,
    ),
    ("denoiser", "dynamic-image-dynamic-prompt-bucket"): (
        "peakSignalToNoiseRatio",
        40.0,
    ),
    ("vae-encoder", "direct-up-to-9216-tokens"): ("correlation", 0.99999),
    ("vae-encoder", "overlapped-tiles-up-to-16384-tokens"): (
        "correlation",
        0.9999,
    ),
    ("vae-decoder", "direct-up-to-9216-tokens"): ("correlation", 0.9999),
    ("vae-decoder", "overlapped-tiles-up-to-16384-tokens"): (
        "correlation",
        0.9999,
    ),
}


def make_component_assets(staging: Path) -> Path:
    components = staging / "Components"
    for component_id in COMPONENT_VARIANTS:
        asset = components / f"{component_id}.aimodel"
        asset.mkdir(parents=True)
        (asset / "payload").write_bytes(component_id.encode("ascii"))
    return components


def make_preassembly_validation(components: Path) -> dict:
    component_results = []
    for component_id, variants in COMPONENT_VARIANTS.items():
        digest = sha256_tree(components / f"{component_id}.aimodel")
        for variant in variants:
            metric, threshold = PARITY_CONTRACTS[(component_id, variant)]
            component_results.append({
                "id": component_id,
                "variant": variant,
                "assetDigestAlgorithm": "sha256-tree-v1",
                "assetDigest": digest,
                "descriptorMatch": True,
                "finiteOutputs": True,
                "estimatedResidentBytes": 1,
                "parity": {
                    "status": "passed",
                    "metric": metric,
                    "threshold": threshold,
                    "worstObserved": (
                        100.0 if metric == "peakSignalToNoiseRatio" else 1.0
                    ),
                },
            })
    exports = []
    for component_id, contract in REQUIRED_EXPORT_CONTRACTS.items():
        variant, precision, computation_precision = contract
        exports.append({
            "id": component_id,
            "variant": variant,
            "reportFile": f"{component_id}-export.json",
            "reportSHA256": "1" * 64,
            "assetDigestAlgorithm": "sha256-tree-v1",
            "assetDigest": sha256_tree(
                components / f"{component_id}.aimodel"
            ),
            "converterMode": "release",
            "probe": False,
            "precision": precision,
            "computationPrecision": computation_precision,
            "sourceRevision": ZIMAGE_SOURCE_REVISION,
            "sourceLockSHA256": "2" * 64,
            "toolSHA256": "3" * 64,
            "system": {"test": True},
        })
    return {
        "schemaVersion": "1.0.0",
        "packageIdentifier": "app.pixeltje.model.z-image-turbo",
        "complete": False,
        "decoderStrategy": "overlapped-tiles",
        "system": {
            "macOS": "27.0",
            "build": "test",
            "machine": "arm64",
            "coreAIRuntime": "test",
            "python": "test",
            "torch": "test",
            "coreAITorch": "test",
        },
        "gates": [
            {
                "id": gate,
                "status": (
                    "blocked"
                    if gate in {"package-integrity", "clean-environment"}
                    else "passed"
                ),
                "evidence": ["unit test"],
            }
            for gate in sorted(REQUIRED_GATES)
        ],
        "exports": exports,
        "components": component_results,
        "resolutionMatrix": [
            {
                "width": width,
                "height": height,
                "status": "passed",
                "native": True,
                "resampled": False,
                "imageTokens": (width // 16) * (height // 16),
            }
            for width, height in sorted(REQUIRED_RESOLUTIONS)
        ],
        "performance": {
            "peakResidentBytes": 1,
            "componentLoadSeconds": {},
            "firstSpecializationSeconds": {},
            "repeatInvocationSeconds": {},
            "denoiserStepSeconds": {},
        },
    }


def finalize_with_implemented_gate_fixture(validation: dict) -> dict:
    """Reach downstream validation branches without weakening production code."""

    with patch("pixaimodel.UNIMPLEMENTED_REQUIRED_GATES", frozenset()):
        return finalize_assembly_gates(validation)


def validate_with_implemented_gate_fixture(
    validation: dict, manifest: dict
) -> None:
    """Exercise record contracts below the intentional release blocker."""

    with patch("pixaimodel.UNIMPLEMENTED_REQUIRED_GATES", frozenset()):
        _validate_validation_record(validation, manifest)


def assembly_arguments(
    temporary: Path, staging: Path, validation_path: Path
) -> argparse.Namespace:
    return argparse.Namespace(
        staging=str(staging),
        output=str(temporary / "z-image-turbo.pixaimodel"),
        source=str(temporary / "unused-source"),
        publisher_reference=str(temporary / "unused-publisher"),
        apple_reference=str(temporary / "unused-apple"),
        validation=str(validation_path),
    )


class AssetDigestBindingTests(unittest.TestCase):
    def test_genuine_numerical_reports_aggregate_to_explicit_blocked_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            publisher = root / "publisher"
            apple = root / "apple"
            for directory in (source, publisher, apple):
                directory.mkdir()
            (publisher / "src" / "zimage").mkdir(parents=True)
            (publisher / "src" / "utils").mkdir(parents=True)
            (publisher / "src" / "zimage" / "transformer.py").write_text(
                "# fixture\n", encoding="utf-8"
            )
            (publisher / "src" / "utils" / "attention.py").write_text(
                "# fixture\n", encoding="utf-8"
            )
            lock_path = root / "source-lock.json"
            write_canonical_json(
                lock_path,
                {
                    "publisherReference": {
                        "repository": "https://example.invalid/publisher.git",
                        "revision": "4" * 40,
                        "licenseSHA256": "5" * 64,
                    }
                },
            )
            lock_digest = sha256_file(lock_path)
            publisher_identity = validation_builder.publisher_reference_identity(
                publisher, lock_path
            )
            execution = {
                "commandArguments": ["--fixture"],
                "startedUTC": "2026-09-11T10:00:00+00:00",
                "finishedUTC": "2026-09-11T10:00:01+00:00",
                "elapsedSeconds": 1.0,
            }
            packages = {
                "coreai-core": "1.0.0b2",
                "coreai-torch": "0.4.2",
                "torch": "2.9.0",
            }
            component_system = {
                "macOS": "27.0",
                "build": "test",
                "machine": "arm64",
                "python": "3.11.13",
                "packages": packages,
            }
            pipeline_system = {
                "macOS": "27.0",
                "build": "test",
                "machine": "arm64",
                "coreAIRuntime": packages["coreai-core"],
                "python": "3.11.13",
                "torch": packages["torch"],
                "coreAITorch": packages["coreai-torch"],
            }
            digests = {
                "prompt-encoder": "1" * 64,
                "denoiser": "2" * 64,
                "vae-encoder": "3" * 64,
                "vae-decoder": "4" * 64,
            }
            source_files = {
                component: [
                    {
                        "path": f"{component}/weights",
                        "sha256": digest,
                        "size": 1,
                    }
                ]
                for component, digest in digests.items()
            }
            component_tool = sha256_file(HERE / "validate_components.py")
            tiling_tool = sha256_file(HERE / "validate_vae_tiling.py")
            pipeline_tool = sha256_file(HERE / "validate_pipeline.py")
            exporter_tool = sha256_file(HERE / "export_components.py")

            def base_component(component: str, variant: str) -> dict:
                return {
                    "schemaVersion": "1.0.0",
                    "component": component,
                    "variant": variant,
                    "asset": f"{component}.aimodel",
                    "assetDigestAlgorithm": "sha256-tree-v1",
                    "assetDigest": digests[component],
                    "computePolicy": "gpu-preferred",
                    "sourceFiles": source_files[component],
                    "descriptorMatch": True,
                    "system": component_system,
                    "peakResidentBytes": 1,
                    "sourceLockSHA256": lock_digest,
                    "toolSHA256": component_tool,
                    **execution,
                }

            prompt = base_component("prompt-encoder", "fixed-512-tokens")
            prompt["results"] = [
                {
                    "status": "passed",
                    "finite": True,
                    "outputShape": [1, 512, 2560],
                    "repeatMaximumAbsoluteError": 0.0,
                    "metrics": {
                        "correlation": 1.0,
                        "peakSignalToNoiseRatio": 100.0,
                    },
                }
            ]
            prompt["status"] = "passed"

            encoder = base_component("vae-encoder", "dynamic-512-2048")
            decoder = base_component("vae-decoder", "dynamic-512-2048")
            encoder["results"] = []
            decoder["results"] = []
            for width, height in sorted(REQUIRED_RESOLUTIONS - {(2048, 2048)}):
                encoder["results"].append(
                    {
                        "width": width,
                        "height": height,
                        "status": "passed",
                        "finite": True,
                        "outputShape": [1, 16, height // 8, width // 8],
                        "repeatMaximumAbsoluteError": 0.0,
                        "metrics": {
                            "correlation": 1.0,
                            "peakSignalToNoiseRatio": 100.0,
                            "rootMeanSquaredError": 0.0,
                            "maximumAbsoluteError": 0.0,
                        },
                    }
                )
                decoder["results"].append(
                    {
                        "width": width,
                        "height": height,
                        "status": "passed",
                        "finite": True,
                        "outputShape": [1, 3, height, width],
                        "repeatMaximumAbsoluteError": 0.0,
                        "metrics": {
                            "correlation": 1.0,
                            "maximumAbsoluteError": 0.0,
                        },
                    }
                )
            encoder["status"] = decoder["status"] = "passed"

            denoiser = base_component(
                "denoiser", "dynamic-image-dynamic-prompt-bucket"
            )
            denoiser.update(
                precision="bfloat16",
                computationPrecision="bfloat16-with-float32-timestep-and-rope",
                attentionAccumulation="model-precision",
                adapterCheckSkipped=False,
                publisherReference=publisher_identity,
            )
            denoiser["results"] = []
            denoiser_cases = [
                (width, height, 32)
                for width, height in sorted(REQUIRED_RESOLUTIONS)
            ] + [(512, 512, 256), (512, 512, 512)]
            for width, height, bucket in denoiser_cases:
                tokens = (width // 16) * (height // 16)
                padded = ((tokens + 31) // 32) * 32
                denoiser["results"].append(
                    {
                        "width": width,
                        "height": height,
                        "promptBucket": bucket,
                        "status": "passed",
                        "finite": True,
                        "validImageTokens": tokens,
                        "outputShape": [1, padded, 64],
                        "repeatMaximumAbsoluteError": 0.0,
                        "adapterToPublisherMetrics": {
                            "correlation": 1.0,
                            "peakSignalToNoiseRatio": 100.0,
                        },
                        "coreAIToPublisherMetrics": {
                            "correlation": 1.0,
                            "peakSignalToNoiseRatio": 100.0,
                        },
                    }
                )
            denoiser["status"] = "passed"

            def tiled(component: str) -> dict:
                target_shape = (
                    [1, 16, 256, 256]
                    if component == "vae-encoder"
                    else [1, 3, 2048, 2048]
                )
                return {
                    **base_component(
                        component, "overlapped-tiles-1024-25-percent"
                    ),
                    "toolSHA256": tiling_tool,
                    "strategy": {
                        "tilePixels": 1024,
                        "overlapFactor": 0.25,
                        "native": True,
                        "resampled": False,
                    },
                    "comparison": {
                        "width": 1280,
                        "height": 1280,
                        "status": "passed",
                        "fullToTiledMetrics": {
                            "correlation": 1.0,
                            "peakSignalToNoiseRatio": 100.0,
                        },
                        "seamMetrics": {"seamToOverallRatio": 1.0},
                    },
                    "target": {
                        "width": 2048,
                        "height": 2048,
                        "status": "passed",
                        "finite": True,
                        "outputShape": target_shape,
                        "repeatMaximumAbsoluteError": 0.0,
                        "coreAIToPublisherTiledMetrics": {
                            "correlation": 1.0,
                            "maximumAbsoluteError": 0.0,
                        },
                        "seamMetrics": {"seamToOverallRatio": 1.0},
                    },
                    "status": "passed",
                }

            encoder_tiling = tiled("vae-encoder")
            decoder_tiling = tiled("vae-decoder")

            glue_log = root / "glue-tests.log"
            glue_log.write_text(
                f"Ran {expected_glue_test_count()} tests in 1.000s\n\nOK\n",
                encoding="utf-8",
            )
            glue_evidence = validation_builder.verify_glue_test_log(glue_log)
            runtime_details = {
                "freshInvocations": "resolution hashes are not lifecycle evidence",
                "specializationResidencyFunction": "residency was not measured",
                "cancellationCleanup": "native cancellation was not synchronized",
                "textToImageSkippedVAEEncoder": "component loads were not traced",
            }
            pipeline = {
                "schemaVersion": "1.0.0",
                "pipeline": "z-image-turbo-text-to-image",
                "status": "blocked",
                "parityStatus": "passed",
                "computePolicy": "gpu-preferred",
                "publisherReference": publisher_identity,
                "componentAssets": {
                    component: {
                        "assetDigestAlgorithm": "sha256-tree-v1",
                        "assetDigest": digests[component],
                    }
                    for component in (
                        "prompt-encoder", "denoiser", "vae-decoder"
                    )
                },
                "decoderStrategy": "overlapped-tiles",
                "system": pipeline_system,
                "glueTestEvidence": glue_evidence,
                "sourceLockSHA256": lock_digest,
                "toolSHA256": pipeline_tool,
                "runtimeChecks": {
                    key: False for key in runtime_details
                },
                "runtimeEvidence": {
                    key: {"status": "not-measured", "detail": detail}
                    for key, detail in runtime_details.items()
                },
                "results": [
                    {
                        "width": width,
                        "height": height,
                        "status": "passed",
                        "native": True,
                        "resampled": False,
                        "finite": True,
                        "outputShape": [1, 3, height, width],
                        "imageTokens": (width // 16) * (height // 16),
                        "repeatMaximumAbsoluteError": 0.0,
                        "metrics": {
                            "correlation": 1.0,
                            "peakSignalToNoiseRatio": 100.0,
                        },
                        "outputSHA256": "9" * 64,
                        "durationSeconds": 1.0,
                    }
                    for width, height in sorted(REQUIRED_RESOLUTIONS)
                ],
                "performance": {
                    "peakResidentBytes": 1,
                    "componentLoadSeconds": {},
                    "firstSpecializationSeconds": {},
                    "repeatInvocationSeconds": {},
                    "denoiserStepSeconds": {},
                },
                **execution,
            }

            reports = {
                "prompt": prompt,
                "denoiser": denoiser,
                "encoder": encoder,
                "decoder": decoder,
                "encoder_tiling": encoder_tiling,
                "decoder_tiling": decoder_tiling,
                "pipeline": pipeline,
            }
            report_paths = {}
            for name, report in reports.items():
                path = root / f"{name}.json"
                write_canonical_json(path, report)
                report_paths[name] = path

            export_paths = {}
            component_reports = {
                "prompt-encoder": prompt,
                "denoiser": denoiser,
                "vae-encoder": encoder,
                "vae-decoder": decoder,
            }
            for component, contract in validation_builder.EXPORT_CONTRACTS.items():
                variant, precision, computation_precision = contract
                component_report = component_reports[component]
                report = {
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
                    "attentionAccumulation": (
                        "model-precision" if component == "denoiser" else None
                    ),
                    "sourceRevision": validation_builder.SOURCE_REVISION,
                    "sourceFiles": component_report["sourceFiles"],
                    "artifact": component_report["asset"],
                    "digestAlgorithm": "sha256-tree-v1",
                    "digest": digests[component],
                    "sourceLockSHA256": lock_digest,
                    "toolSHA256": exporter_tool,
                    "system": component_system,
                    **execution,
                }
                path = root / f"{component}-export.json"
                write_canonical_json(path, report)
                export_paths[component] = path

            args = argparse.Namespace(
                source=str(source),
                publisher_reference=str(publisher),
                apple_reference=str(apple),
                lock=str(lock_path),
                prompt_report=str(report_paths["prompt"]),
                denoiser_report=str(report_paths["denoiser"]),
                vae_encoder_report=str(report_paths["encoder"]),
                vae_decoder_report=str(report_paths["decoder"]),
                vae_encoder_tiling_report=str(report_paths["encoder_tiling"]),
                vae_decoder_tiling_report=str(report_paths["decoder_tiling"]),
                pipeline_report=str(report_paths["pipeline"]),
                glue_test_log=str(glue_log),
                prompt_export_report=str(export_paths["prompt-encoder"]),
                denoiser_export_report=str(export_paths["denoiser"]),
                vae_encoder_export_report=str(export_paths["vae-encoder"]),
                vae_decoder_export_report=str(export_paths["vae-decoder"]),
            )
            with patch.object(validation_builder, "audit_source"), patch.object(
                validation_builder, "audit_references"
            ):
                validation = validation_builder.make_record(args)

            validate_schema(validation, load_json(VALIDATION_SCHEMA))
            self.assertFalse(validation["complete"])
            blocked = {
                gate["id"]
                for gate in validation["gates"]
                if gate["status"] == "blocked"
            }
            self.assertEqual(
                blocked,
                set(UNIMPLEMENTED_REQUIRED_GATES)
                | {"package-integrity", "clean-environment"},
            )
            with self.assertRaisesRegex(
                ContractError, "lack implementation-owned validation"
            ):
                finalize_assembly_gates(validation)

    def test_validation_schema_requires_component_asset_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            validation = make_preassembly_validation(components)
            path = temporary / "validation.json"
            write_canonical_json(path, validation)
            validate_json_file(path, VALIDATION_SCHEMA)

            del validation["components"][0]["assetDigest"]
            write_canonical_json(path, validation)
            with self.assertRaisesRegex(ContractError, "assetDigest"):
                validate_json_file(path, VALIDATION_SCHEMA)

    def test_package_record_rejects_forged_passed_unimplemented_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            components = make_component_assets(
                temporary / "z-image-turbo.pixaimodel.staging"
            )
            validation = make_preassembly_validation(components)
            validation["complete"] = True
            for gate in validation["gates"]:
                gate["status"] = "passed"
            manifest = {
                "package": {"identifier": validation["packageIdentifier"]},
            }

            with self.assertRaisesRegex(
                ContractError, "lack implementation-owned validation"
            ):
                _validate_validation_record(validation, manifest)

    def test_post_validation_component_swap_is_rejected_before_assembly_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            validation_path = temporary / "validation.preassembly.json"
            write_canonical_json(
                validation_path, make_preassembly_validation(components)
            )
            (components / "denoiser.aimodel" / "payload").write_bytes(
                b"post-validation replacement"
            )

            with self.assertRaisesRegex(ContractError, "digest mismatch"):
                assemble(assembly_arguments(temporary, staging, validation_path))

            self.assertFalse((staging / "validation.json").exists())
            self.assertFalse((temporary / "z-image-turbo.pixaimodel").exists())

    def test_debug_denoiser_cannot_be_mislabeled_for_release_assembly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            metadata = components / "denoiser.aimodel" / "metadata.json"
            write_canonical_json(
                metadata,
                {
                    "creatorDefinedMetadata": {
                        "pixeltjeProfiler": {
                            "component": "denoiser",
                            "converterMode": "debug",
                            "probe": True,
                            "variant": "tiny-probe",
                        }
                    }
                },
            )
            validation_path = temporary / "validation.preassembly.json"
            # The record deliberately lies about the tiny DEBUG asset's variant;
            # its digest still matches so the metadata rejection is independently
            # exercised.
            write_canonical_json(
                validation_path, make_preassembly_validation(components)
            )

            with self.assertRaisesRegex(ContractError, "DEBUG component"):
                assemble(assembly_arguments(temporary, staging, validation_path))

            self.assertFalse((staging / "validation.json").exists())
            self.assertFalse((temporary / "z-image-turbo.pixaimodel").exists())

    def test_extra_staged_component_is_rejected_before_assembly_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            validation_path = temporary / "validation.preassembly.json"
            write_canonical_json(
                validation_path, make_preassembly_validation(components)
            )
            stale = components / "stale-debug.aimodel"
            stale.mkdir()
            (stale / "payload").write_bytes(b"unreferenced")

            with self.assertRaisesRegex(ContractError, "entries mismatch"):
                assemble(assembly_arguments(temporary, staging, validation_path))

            self.assertFalse((staging / "validation.json").exists())

    def test_existing_generated_staging_target_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            validation_path = temporary / "validation.preassembly.json"
            write_canonical_json(
                validation_path, make_preassembly_validation(components)
            )
            sentinel = staging / "Resources" / "sentinel"
            sentinel.parent.mkdir()
            sentinel.write_bytes(b"preserve")

            with self.assertRaisesRegex(ContractError, "refusing to replace"):
                assemble(assembly_arguments(temporary, staging, validation_path))

            self.assertEqual(sentinel.read_bytes(), b"preserve")
            self.assertFalse((staging / "validation.json").exists())

    def test_copy_file_does_not_replace_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "source"
            destination = temporary / "destination"
            source.write_bytes(b"new")
            destination.write_bytes(b"preserve")

            with self.assertRaisesRegex(ContractError, "refusing to replace"):
                copy_file(source, destination)

            self.assertEqual(destination.read_bytes(), b"preserve")

    def test_package_validation_binds_results_to_manifest_variant_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components_root = make_component_assets(staging)
            validation = finalize_with_implemented_gate_fixture(
                make_preassembly_validation(components_root)
            )
            components = component_manifest(components_root, validation)
            manifest = {
                "package": {"identifier": validation["packageIdentifier"]},
                "components": components,
            }
            validate_with_implemented_gate_fixture(validation, manifest)

            changed = copy.deepcopy(validation)
            changed["components"][0]["assetDigest"] = "0" * 64
            with self.assertRaisesRegex(ContractError, "different asset"):
                validate_with_implemented_gate_fixture(changed, manifest)

            changed = copy.deepcopy(validation)
            changed["exports"][0]["assetDigest"] = "0" * 64
            with self.assertRaisesRegex(ContractError, "different asset"):
                validate_with_implemented_gate_fixture(changed, manifest)

    def test_package_validation_rejects_debug_export_mislabeled_as_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components_root = make_component_assets(staging)
            validation = finalize_with_implemented_gate_fixture(
                make_preassembly_validation(components_root)
            )
            manifest = {
                "package": {"identifier": validation["packageIdentifier"]},
                "components": component_manifest(components_root, validation),
            }

            forged = copy.deepcopy(validation)
            denoiser = next(
                item for item in forged["exports"] if item["id"] == "denoiser"
            )
            denoiser.update(converterMode="debug", probe=True)
            with self.assertRaisesRegex(ContractError, "full pinned RELEASE"):
                validate_with_implemented_gate_fixture(forged, manifest)

    def test_assembly_binds_exports_to_current_lock_and_converter(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components = make_component_assets(staging)
            validation = make_preassembly_validation(components)
            for item in validation["exports"]:
                item["sourceLockSHA256"] = sha256_file(
                    HERE / "source-lock.json"
                )
                item["toolSHA256"] = sha256_file(
                    HERE / "export_components.py"
                )
            verify_conversion_export_identities(validation)

            validation["exports"][0]["toolSHA256"] = "0" * 64
            with self.assertRaisesRegex(ContractError, "different exporter"):
                verify_conversion_export_identities(validation)

    def test_package_validation_rejects_forged_parity_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components_root = make_component_assets(staging)
            validation = finalize_with_implemented_gate_fixture(
                make_preassembly_validation(components_root)
            )
            manifest = {
                "package": {"identifier": validation["packageIdentifier"]},
                "components": component_manifest(components_root, validation),
            }

            forged = copy.deepcopy(validation)
            prompt = next(
                item for item in forged["components"]
                if item["id"] == "prompt-encoder"
            )
            prompt["parity"].update(
                metric="correlation", threshold=-1.0, worstObserved=0.0
            )
            with self.assertRaisesRegex(ContractError, "wrong parity metric"):
                validate_with_implemented_gate_fixture(forged, manifest)

            forged = copy.deepcopy(validation)
            prompt = next(
                item for item in forged["components"]
                if item["id"] == "prompt-encoder"
            )
            prompt["parity"].update(threshold=-1.0, worstObserved=0.0)
            with self.assertRaisesRegex(ContractError, "fixed parity gate"):
                validate_with_implemented_gate_fixture(forged, manifest)

    def test_package_validation_rejects_duplicate_gate_and_resolution_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            staging = temporary / "z-image-turbo.pixaimodel.staging"
            components_root = make_component_assets(staging)
            validation = finalize_with_implemented_gate_fixture(
                make_preassembly_validation(components_root)
            )
            manifest = {
                "package": {"identifier": validation["packageIdentifier"]},
                "components": component_manifest(components_root, validation),
            }

            duplicate_gate = copy.deepcopy(validation)
            duplicate_gate["gates"].append(copy.deepcopy(duplicate_gate["gates"][0]))
            with self.assertRaisesRegex(ContractError, "duplicate gate"):
                validate_with_implemented_gate_fixture(duplicate_gate, manifest)

            duplicate_resolution = copy.deepcopy(validation)
            duplicate_resolution["resolutionMatrix"].append(
                copy.deepcopy(duplicate_resolution["resolutionMatrix"][0])
            )
            with self.assertRaisesRegex(ContractError, "duplicate resolution"):
                validate_with_implemented_gate_fixture(duplicate_resolution, manifest)

    def test_pipeline_assets_must_match_component_reports(self) -> None:
        digest = "a" * 64
        reports = {
            component_id: (
                {
                    "assetDigestAlgorithm": "sha256-tree-v1",
                    "assetDigest": digest,
                },
                Path(f"{component_id}.json"),
            )
            for component_id in ("prompt-encoder", "denoiser", "vae-decoder")
        }
        pipeline = {
            "componentAssets": {
                component_id: {
                    "assetDigestAlgorithm": "sha256-tree-v1",
                    "assetDigest": digest,
                }
                for component_id in reports
            }
        }
        require_pipeline_asset_bindings(pipeline, reports, Path("pipeline.json"))

        pipeline["componentAssets"]["denoiser"]["assetDigest"] = "b" * 64
        with self.assertRaisesRegex(ContractError, "different denoiser asset"):
            require_pipeline_asset_bindings(
                pipeline, reports, Path("pipeline.json")
            )


if __name__ == "__main__":
    unittest.main()
