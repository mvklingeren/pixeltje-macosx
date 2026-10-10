#!/usr/bin/env python3
"""Assemble a fully validated Z-Image PixAIModel package outside Git."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from pixaimodel import (
    ContractError,
    HERE,
    PROVENANCE_SCHEMA,
    REQUIRED_GATES,
    VALIDATION_SCHEMA,
    _validate_validation_record,
    audit_references,
    audit_source,
    guarded_resolve,
    load_json,
    outside_checkout,
    package_path,
    require_implemented_release_gates,
    sha256_file,
    sha256_tree,
    validate_json_file,
    validate_package,
)
from run_validation_subprocess import prepare_atomic_new_json, write_atomic_new_json


PACKAGE_ID = "app.pixeltje.model.z-image-turbo"
SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"
ASSET_DIGEST_ALGORITHM = "sha256-tree-v1"
DEBUG_PROFILER_METADATA_KEY = "pixeltjeProfiler"
COMPONENT_ARTIFACTS = {
    "prompt-encoder": "Components/prompt-encoder.aimodel",
    "denoiser": "Components/denoiser.aimodel",
    "vae-encoder": "Components/vae-encoder.aimodel",
    "vae-decoder": "Components/vae-decoder.aimodel",
}
GENERATED_ASSEMBLY_TARGETS = (
    "validation.json",
    "manifest.json",
    "provenance.json",
    "Pipelines",
    "Resources",
    "Licenses",
)


def tensor(
    name: str,
    scalar_type: str,
    dimensions: list[Any],
    layout: str,
    semantic: str,
    value_range: dict[str, float] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "name": name,
        "scalarType": scalar_type,
        "rank": len(dimensions),
        "dimensions": dimensions,
        "layout": layout,
        "semantic": semantic,
    }
    if value_range is not None:
        result["valueRange"] = value_range
    return result


def dynamic(symbol: str, minimum: int, maximum: int, multiple_of: int | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"symbol": symbol, "minimum": minimum, "maximum": maximum}
    if multiple_of is not None:
        result["multipleOf"] = multiple_of
    return result


def variant(
    variant_id: str,
    artifact: str,
    function_name: str,
    digest: str,
    storage_type: str,
    inputs: list[dict[str, Any]],
    outputs: list[dict[str, Any]],
    capabilities: dict[str, Any],
    estimated_bytes: int,
) -> dict[str, Any]:
    return {
        "id": variant_id,
        "artifact": artifact,
        "functionName": function_name,
        "digest": digest,
        "digestAlgorithm": "sha256-tree-v1",
        "storageType": storage_type,
        "specialization": "required-on-first-load",
        "inputs": inputs,
        "outputs": outputs,
        "capabilities": capabilities,
        "estimatedResidentBytes": estimated_bytes,
    }


def validation_component_digests(validation: dict[str, Any]) -> dict[str, str]:
    components = validation.get("components")
    if not isinstance(components, list):
        raise ContractError("validation record lacks component results")
    digests: dict[str, str] = {}
    seen_variants: set[tuple[str, str]] = set()
    for item in components:
        if not isinstance(item, dict):
            raise ContractError("validation component result must be an object")
        component_id = item.get("id")
        variant_id = item.get("variant")
        if not isinstance(component_id, str) or not isinstance(variant_id, str):
            raise ContractError("validation component result lacks an ID or variant")
        key = (component_id, variant_id)
        if key in seen_variants:
            raise ContractError(f"duplicate validation result for component variant {key}")
        seen_variants.add(key)
        if component_id not in COMPONENT_ARTIFACTS:
            raise ContractError(f"unexpected validation component {component_id!r}")
        if item.get("assetDigestAlgorithm") != ASSET_DIGEST_ALGORITHM:
            raise ContractError(
                f"validation result for {key} uses the wrong asset digest algorithm"
            )
        digest = item.get("assetDigest")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ContractError(f"validation result for {key} lacks an asset digest")
        previous = digests.setdefault(component_id, digest)
        if previous != digest:
            raise ContractError(
                f"validation variants for {component_id!r} disagree on the tested asset digest"
            )
    missing = set(COMPONENT_ARTIFACTS) - set(digests)
    if missing:
        raise ContractError(
            f"validation record lacks tested asset digests for {sorted(missing)}"
        )
    return digests


def _contains_debug_profiler_marker(value: Any) -> bool:
    if isinstance(value, dict):
        return DEBUG_PROFILER_METADATA_KEY in value or any(
            _contains_debug_profiler_marker(item) for item in value.values()
        )
    if isinstance(value, list):
        return any(_contains_debug_profiler_marker(item) for item in value)
    return False


def verify_staged_component_digests(
    components_root: Path, validation: dict[str, Any]
) -> dict[str, str]:
    if not components_root.is_dir() or components_root.is_symlink():
        raise ContractError(f"missing or unsafe Components directory: {components_root}")
    expected_entries = {
        Path(relative).name for relative in COMPONENT_ARTIFACTS.values()
    }
    observed_entries = {item.name for item in components_root.iterdir()}
    if observed_entries != expected_entries:
        raise ContractError(
            "staged Components directory entries mismatch: "
            f"expected {sorted(expected_entries)}, found {sorted(observed_entries)}"
        )
    expected = validation_component_digests(validation)
    actual: dict[str, str] = {}
    for component_id, relative in COMPONENT_ARTIFACTS.items():
        asset = components_root.parent / relative
        if not asset.is_dir() or asset.is_symlink():
            raise ContractError(f"missing staged component: {asset}")
        metadata_path = asset / "metadata.json"
        if metadata_path.exists():
            if metadata_path.is_symlink() or not metadata_path.is_file():
                raise ContractError(f"unsafe Core AI metadata: {metadata_path}")
            metadata = load_json(metadata_path)
            if _contains_debug_profiler_marker(metadata):
                raise ContractError(
                    f"refusing profiler-enabled DEBUG component in release assembly: {asset}"
                )
        digest = sha256_tree(asset)
        actual[component_id] = digest
        if digest != expected[component_id]:
            raise ContractError(
                f"staged component digest mismatch for {component_id!r}: "
                f"validated {expected[component_id]}, found {digest}"
            )
    return actual


def component_manifest(
    components_root: Path,
    validation: dict[str, Any],
    verified_digests: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    paths = COMPONENT_ARTIFACTS
    digests = (
        verify_staged_component_digests(components_root, validation)
        if verified_digests is None
        else verified_digests
    )
    resident = {
        item.get("id"): int(item.get("estimatedResidentBytes", 0))
        for item in validation["components"]
    }
    prompt = {
        "id": "prompt-encoder",
        "role": "prompt-encoder",
        "revision": SOURCE_REVISION,
        "compatibilityGroup": "z-image-turbo-f332072a",
        "variants": [
            variant(
                "fixed-512-tokens", paths["prompt-encoder"], "main", digests["prompt-encoder"], "float16",
                [
                    tensor("input_ids", "int32", [1, 512], "BS", "Qwen tokenizer IDs padded to maximum length"),
                    tensor("attention_mask", "bool", [1, 512], "BS", "Qwen active-token mask"),
                ],
                [tensor("prompt_embeddings", "float16", [1, 512, 2560], "BSC", "Qwen3 penultimate hidden state including host-trimmable padding")],
                {"maximumPromptTokens": 512}, resident.get("prompt-encoder", 0),
            )
        ],
    }

    image_tokens = dynamic("image-tokens", 1024, 16384, 32)
    prompt_tokens = dynamic("prompt-tokens", 32, 512, 32)
    denoiser_variants = [
            variant(
                "dynamic-image-dynamic-prompt-bucket", paths["denoiser"], "main", digests["denoiser"], "bfloat16",
                [
                    tensor("image_tokens", "bfloat16", [1, image_tokens, 64], "BSC", "host-patchified 2x2 latent tokens"),
                    tensor("image_padding_mask", "bool", [1, image_tokens], "BS", "true for learned image pad token"),
                    tensor("prompt_embeddings", "bfloat16", [1, prompt_tokens, 2560], "BSC", "Qwen prompt embeddings padded to the publisher's selected 32-token bucket"),
                    tensor("prompt_padding_mask", "bool", [1, prompt_tokens], "BS", "true for learned caption pad token within the selected bucket"),
                    tensor("prompt_attention_mask", "bool", [1, prompt_tokens], "BS", "active selected publisher bucket"),
                    tensor("timestep", "float32", [1], "B", "normalized one-minus scheduler timestep"),
                    tensor("image_rope_cos", "float32", [1, image_tokens, 64], "BSC", "contiguous real cosine half of publisher complex64 image RoPE"),
                    tensor("image_rope_sin", "float32", [1, image_tokens, 64], "BSC", "contiguous imaginary sine half of publisher complex64 image RoPE"),
                    tensor("prompt_rope_cos", "float32", [1, prompt_tokens, 64], "BSC", "contiguous real cosine half of publisher complex64 prompt RoPE"),
                    tensor("prompt_rope_sin", "float32", [1, prompt_tokens, 64], "BSC", "contiguous imaginary sine half of publisher complex64 prompt RoPE"),
                ],
                [tensor("noise_prediction", "bfloat16", [1, image_tokens, 64], "BSC", "patchified raw transformer output")],
                {
                    "minimumWidth": 512, "maximumWidth": 2048,
                    "minimumHeight": 512, "maximumHeight": 2048,
                    "requiredMultiple": 16, "maximumImageTokens": 16384,
                    "maximumPromptTokens": 512,
                },
                resident.get("denoiser", 0),
            )
        ]
    denoiser = {
        "id": "denoiser", "role": "denoiser", "revision": SOURCE_REVISION,
        "compatibilityGroup": "z-image-turbo-f332072a", "variants": denoiser_variants,
    }

    pixel_height = dynamic("pixel-height", 512, 2048, 16)
    pixel_width = dynamic("pixel-width", 512, 2048, 16)
    latent_height = dynamic("latent-height", 64, 256, 2)
    latent_width = dynamic("latent-width", 64, 256, 2)
    common_resolution = {
        "minimumWidth": 512, "maximumWidth": 2048,
        "minimumHeight": 512, "maximumHeight": 2048,
        "requiredMultiple": 16,
    }
    direct_resolution = dict(common_resolution)
    direct_resolution.update({"maximumImageTokens": 9216, "executionStrategy": "direct"})
    tiled_resolution = dict(common_resolution)
    tiled_resolution.update(
        {
            "maximumImageTokens": 16384,
            "directMaximumImageTokens": 9216,
            "executionStrategy": "overlapped-tiles",
            "tilePixels": 1024,
            "tileOverlapFactor": 0.25,
        }
    )
    encoder = {
        "id": "vae-encoder", "role": "vae-encoder", "revision": SOURCE_REVISION,
        "compatibilityGroup": "z-image-turbo-f332072a",
        "variants": [
            variant(
                "direct-up-to-9216-tokens", paths["vae-encoder"], "main", digests["vae-encoder"], "float32",
                [tensor("image", "float32", [1, 3, pixel_height, pixel_width], "BCHW", "publisher-normalized RGB image", {"minimum": -1.0, "maximum": 1.0})],
                [tensor("latent", "float32", [1, 16, latent_height, latent_width], "BCHW", "posterior mode before host affine")],
                direct_resolution, resident.get("vae-encoder", 0),
            ),
            variant(
                "overlapped-tiles-up-to-16384-tokens", paths["vae-encoder"], "main", digests["vae-encoder"], "float32",
                [tensor("image", "float32", [1, 3, pixel_height, pixel_width], "BCHW", "publisher-normalized RGB image or native tile", {"minimum": -1.0, "maximum": 1.0})],
                [tensor("latent", "float32", [1, 16, latent_height, latent_width], "BCHW", "posterior mode before host affine")],
                tiled_resolution, resident.get("vae-encoder", 0),
            )
        ],
    }
    direct_decoder_capabilities = dict(direct_resolution)
    direct_decoder_capabilities["decoderStrategy"] = "dynamic"
    tiled_decoder_capabilities = dict(tiled_resolution)
    tiled_decoder_capabilities["decoderStrategy"] = "overlapped-tiles"
    decoder = {
        "id": "vae-decoder", "role": "vae-decoder", "revision": SOURCE_REVISION,
        "compatibilityGroup": "z-image-turbo-f332072a",
        "variants": [
            variant(
                "direct-up-to-9216-tokens", paths["vae-decoder"], "main", digests["vae-decoder"], "float32",
                [tensor("latent", "float32", [1, 16, latent_height, latent_width], "BCHW", "host inverse-affine latent")],
                [tensor("image", "float32", [1, 3, pixel_height, pixel_width], "BCHW", "decoded RGB before host normalization")],
                direct_decoder_capabilities, resident.get("vae-decoder", 0),
            ),
            variant(
                "overlapped-tiles-up-to-16384-tokens", paths["vae-decoder"], "main", digests["vae-decoder"], "float32",
                [tensor("latent", "float32", [1, 16, latent_height, latent_width], "BCHW", "host inverse-affine latent or native tile")],
                [tensor("image", "float32", [1, 3, pixel_height, pixel_width], "BCHW", "decoded RGB before host normalization")],
                tiled_decoder_capabilities, resident.get("vae-decoder", 0),
            )
        ],
    }
    return [prompt, denoiser, encoder, decoder]


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file() or source.is_symlink():
        raise ContractError(f"required assembly input is missing or unsafe: {source}")
    if destination.is_symlink() or destination.exists():
        raise ContractError(f"refusing to replace existing assembly output: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as input_handle, destination.open("xb") as output_handle:
        shutil.copyfileobj(input_handle, output_handle)


def verify_new_assembly_targets(staging: Path) -> None:
    for relative in GENERATED_ASSEMBLY_TARGETS:
        target = staging / relative
        if target.is_symlink() or target.exists():
            raise ContractError(
                f"refusing to replace existing assembly output: {target}"
            )


def ensure_outside_git(path: Path) -> None:
    repository = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], check=True,
            capture_output=True, text=True, cwd=HERE,
        ).stdout.strip()
    ).resolve()
    resolved = path.resolve(strict=False)
    if resolved == repository or repository in resolved.parents:
        raise ContractError(f"model package staging/output must stay outside Git: {resolved}")
    forbidden = (Path.home() / "source" / "pixeltje").resolve(strict=False)
    if resolved == forbidden or forbidden in resolved.parents:
        raise ContractError("build/package path must not use ~/source/pixeltje")


def inventory_for(staging: Path) -> list[dict[str, Any]]:
    component_directories = sorted((staging / "Components").glob("*.aimodel"))
    directory_entries = component_directories + [staging / "Resources" / "tokenizer"]
    entries: list[dict[str, Any]] = []
    covered = set()
    for directory in directory_entries:
        relative = directory.relative_to(staging).as_posix()
        entries.append(
            {"path": relative, "kind": "directory", "digest": sha256_tree(directory), "digestAlgorithm": "sha256-tree-v1", "mediaType": "application/vnd.apple.aimodel" if directory.suffix == ".aimodel" else "application/vnd.huggingface.tokenizer"}
        )
        for child in directory.rglob("*"):
            if child.is_file():
                covered.add(child)
    for path in sorted(staging.rglob("*"), key=lambda item: item.relative_to(staging).as_posix()):
        if not path.is_file() or path == staging / "manifest.json" or path in covered:
            continue
        relative = path.relative_to(staging).as_posix()
        entries.append(
            {"path": relative, "kind": "file", "digest": sha256_file(path), "digestAlgorithm": "sha256", "mediaType": "application/json" if path.suffix == ".json" else "text/plain"}
        )
    return sorted(entries, key=lambda item: item["path"])


def conversion_revision() -> str:
    repository = HERE.parent.parent
    inputs = [
        *HERE.glob("*.py"),
        *HERE.glob("*.json"),
        *HERE.glob("schemas/*.json"),
        *HERE.glob("pipelines/*.json"),
        *HERE.glob("tests/*.py"),
        repository / "Scripts" / "build-zimage-pixaimodel.sh",
    ]
    digest = hashlib.sha256()
    for path in sorted(inputs, key=lambda item: item.relative_to(repository).as_posix()):
        relative = path.relative_to(repository).as_posix()
        file_digest = sha256_file(path)
        digest.update(
            b"F\0"
            + relative.encode("utf-8")
            + b"\0"
            + str(path.stat().st_size).encode("ascii")
            + b"\0"
            + file_digest.encode("ascii")
            + b"\n"
        )
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], check=True, capture_output=True, text=True, cwd=HERE
    ).stdout.strip()
    return f"git:{head};conversion-inputs-sha256-v1:{digest.hexdigest()}"


def finalize_assembly_gates(validation: dict[str, Any]) -> dict[str, Any]:
    """Finalize only the two gates that assembly itself can establish.

    All numerical and runtime behavior gates must already have passed.  The
    output is validated twice below; any failure rolls the package back to its
    staging name and the build command fails.
    """
    result = json.loads(json.dumps(validation))
    gates = {gate["id"]: gate for gate in result["gates"]}
    missing = REQUIRED_GATES - set(gates)
    if missing:
        raise ContractError(f"validation record lacks required gates: {sorted(missing)}")
    require_implemented_release_gates()
    assembly_gates = {"package-integrity", "clean-environment"}
    for gate_id in REQUIRED_GATES - assembly_gates:
        if gates[gate_id]["status"] != "passed":
            raise ContractError(f"pre-assembly validation gate did not pass: {gate_id}")
    for gate_id in assembly_gates:
        if gates[gate_id]["status"] not in {"blocked", "passed"}:
            raise ContractError(f"invalid pre-assembly status for {gate_id}")
    gates["package-integrity"].update(
        status="passed",
        evidence=["assemble.py inventory closure, schema, digest, ABI, and forbidden-format validation"],
        detail="Finalized atomically; output is rolled back if validation fails.",
    )
    gates["clean-environment"].update(
        status="passed",
        evidence=["assemble.py sanitized-cwd /usr/bin/python3 package validation"],
        detail="Finalized atomically; output is rolled back if the clean subprocess fails.",
    )
    result["complete"] = True
    return result


def verify_conversion_export_identities(validation: dict[str, Any]) -> None:
    expected_lock = sha256_file(HERE / "source-lock.json")
    expected_tool = sha256_file(HERE / "export_components.py")
    for item in validation["exports"]:
        if item["sourceLockSHA256"] != expected_lock:
            raise ContractError(
                f"conversion export {item['id']} uses a different source lock"
            )
        if item["toolSHA256"] != expected_tool:
            raise ContractError(
                f"conversion export {item['id']} uses a different exporter"
            )


def assemble(args: argparse.Namespace) -> None:
    staging = outside_checkout(Path(args.staging))
    output = outside_checkout(Path(args.output))
    source = guarded_resolve(Path(args.source))
    publisher_reference = guarded_resolve(Path(args.publisher_reference))
    apple_reference = guarded_resolve(Path(args.apple_reference))
    validation_input = outside_checkout(Path(args.validation))
    ensure_outside_git(staging)
    ensure_outside_git(output)
    if not staging.name.endswith(".pixaimodel.staging"):
        raise ContractError("staging directory must end in .pixaimodel.staging")
    if output.suffix != ".pixaimodel":
        raise ContractError("output directory must end in .pixaimodel")
    if output.exists():
        raise ContractError(f"refusing to replace existing package: {output}")
    verify_new_assembly_targets(staging)
    preassembly_validation = validate_json_file(validation_input, VALIDATION_SCHEMA)
    staged_component_digests = verify_staged_component_digests(
        staging / "Components", preassembly_validation
    )
    verify_conversion_export_identities(preassembly_validation)
    validation = finalize_assembly_gates(preassembly_validation)
    components = component_manifest(
        staging / "Components", validation, staged_component_digests
    )
    _validate_validation_record(
        validation,
        {"package": {"identifier": PACKAGE_ID}, "components": components},
    )
    audit_source(source, HERE / "source-lock.json", allow_lfs_pointers=False)
    audit_references(
        publisher_reference, apple_reference, HERE / "source-lock.json"
    )
    write_atomic_new_json(staging / "validation.json", validation)
    copy_file(HERE / "pipelines" / "text-to-image.pipeline.json", staging / "Pipelines" / "text-to-image.pipeline.json")
    for name in ("merges.txt", "tokenizer.json", "tokenizer_config.json", "vocab.json"):
        copy_file(source / "tokenizer" / name, staging / "Resources" / "tokenizer" / name)
    copy_file(source / "scheduler" / "scheduler_config.json", staging / "Resources" / "scheduler" / "scheduler_config.json")
    glue = {
        "schemaVersion": "1.0.0", "family": "z-image", "latentScalingFactor": 0.3611,
        "latentShiftFactor": 0.1159, "spatialDownsample": 8, "patchHeight": 2,
        "patchWidth": 2, "imageTokenPixelWidth": 16, "imageTokenPixelHeight": 16,
        "sequenceMultiple": 32, "timestepScale": 1000.0, "ropeTheta": 256.0,
        "ropeAxesDimensions": [32, 48, 48], "ropeAxesLengths": [1536, 512, 512],
        "scheduler": {
            "numberOfTrainingTimesteps": 1000,
            "useDynamicShifting": False,
            "shift": 3.0,
            "sigmaMinimum": 0.0,
            "skipZeroDeltaStep": True,
        },
    }
    glue_path = prepare_atomic_new_json(
        staging / "Resources" / "glue" / "z-image-1.0.json",
        "assembly glue resource",
    )
    write_atomic_new_json(glue_path, glue)
    copy_file(publisher_reference / "LICENSE", staging / "Licenses" / "Apache-2.0.txt")
    copy_file(apple_reference / "LICENSE", staging / "Licenses" / "coreai-models-BSD-3-Clause.txt")
    notice = (
        "Z-Image-Turbo publisher model and reference implementation: Apache-2.0.\n"
        f"Publisher model revision: {SOURCE_REVISION}.\n"
        "Apple coreai-models conversion tooling: BSD-3-Clause.\n"
        "The package contains converted Core AI assets and data resources only; it contains no Python or source weights.\n"
    )
    notice_path = staging / "Licenses" / "NOTICE.txt"
    notice_path.parent.mkdir(parents=True, exist_ok=True)
    with notice_path.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write(notice)

    lock = load_json(HERE / "source-lock.json")
    component_artifacts = []
    for name, relative in COMPONENT_ARTIFACTS.items():
        component_artifacts.append(
            {
                "path": relative,
                "digest": staged_component_digests[name],
                "digestAlgorithm": ASSET_DIGEST_ALGORITHM,
            }
        )
    provenance = {
        "schemaVersion": "1.0.0",
        "packageIdentifier": PACKAGE_ID,
        "source": {
            "repository": lock["publisherModel"]["repository"],
            "revision": lock["publisherModel"]["revision"],
            "license": lock["publisherModel"]["license"],
        },
        "references": [
            {
                "repository": lock["publisherReference"]["repository"],
                "revision": lock["publisherReference"]["revision"],
                "license": lock["publisherReference"]["license"],
            },
            {
                "repository": lock["coreAITooling"]["repository"],
                "revision": lock["coreAITooling"]["revision"],
                "license": lock["coreAITooling"]["license"],
            },
        ],
        "toolchain": {
            "coreAIModelsRevision": lock["coreAITooling"]["revision"],
            "coreAIModelsUVLockSHA256": lock["coreAITooling"]["uvLockSHA256"],
            "conversionToolRevision": conversion_revision(),
        },
        "sourceFiles": [
            {key: item[key] for key in ("path", "sha256", "size") if key in item}
            for item in lock["publisherModel"]["files"]
        ],
        "conversionExports": validation["exports"],
        "outputArtifacts": component_artifacts,
    }
    write_atomic_new_json(staging / "provenance.json", provenance)
    validate_json_file(staging / "provenance.json", PROVENANCE_SCHEMA)

    pipeline_path = staging / "Pipelines" / "text-to-image.pipeline.json"
    scheduler_hash = sha256_file(staging / "Resources" / "scheduler" / "scheduler_config.json")
    tokenizer_config = load_json(staging / "Resources" / "tokenizer" / "tokenizer_config.json")
    chat_template_hash = __import__("hashlib").sha256(tokenizer_config["chat_template"].encode("utf-8")).hexdigest()
    manifest: dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "package": {"identifier": PACKAGE_ID, "displayName": "Z-Image Turbo", "modelFamily": "z-image", "variant": "turbo", "formatVersion": "1.0.0"},
        "publisher": {"name": "Tongyi-MAI", "modelRepository": lock["publisherModel"]["repository"], "revision": SOURCE_REVISION},
        "compatibility": {"minimumMacOS": "27.0", "minimumPipelineRuntime": "1.0.0", "artifactTypes": ["aimodel"]},
        "pipelines": [{"id": "z-image-turbo-text-to-image", "version": "1.0.0", "descriptor": "Pipelines/text-to-image.pipeline.json", "descriptorSHA256": sha256_file(pipeline_path), "modes": ["text-to-image"], "minimumRuntime": "1.0.0"}],
        "components": components,
        "generation": {
            "modes": ["text-to-image"],
            "schedulers": [{"id": "flow-match-euler-discrete", "implementation": "host", "configurationSHA256": scheduler_hash}],
            "resolution": {"minimumWidth": 512, "maximumWidth": 2048, "minimumHeight": 512, "maximumHeight": 2048, "requiredMultiple": 16, "independentAxes": True, "maximumImageTokens": 16384, "resamplingFallback": False, "decoderStrategy": validation.get("decoderStrategy", "dynamic")},
            "prompt": {"maximumTokens": 512, "tokenizerIdentity": "Qwen2Tokenizer@f332072a", "chatTemplateSHA256": chat_template_hash, "embeddingHiddenSize": 2560},
            "latent": {"channels": 16, "spatialDownsample": 8, "patchWidth": 2, "patchHeight": 2, "scalingFactor": 0.3611, "shiftFactor": 0.1159, "timestepScale": 1000.0, "ropeTheta": 256.0, "ropeAxesDimensions": [32, 48, 48], "ropeAxesLengths": [1536, 512, 512]},
            "defaults": {"width": 1024, "height": 1024, "transformerEvaluations": 8, "guidanceScale": 0.0, "seedMode": "fixed", "scheduler": "flow-match-euler-discrete"},
        },
        "color": {"sourceTensor": "publisher normalized RGB in [-1, 1]", "outputTensor": "host-normalized RGB in [0, 1]", "packageOutput": "Extended Linear Display P3"},
        "memory": {"estimatedPeakBytes": int(validation["performance"]["peakResidentBytes"]), "residencyGroups": [{"id": "prompt-stage", "componentIDs": ["prompt-encoder"], "simultaneouslyResident": False}, {"id": "denoise-stage", "componentIDs": ["denoiser"], "simultaneouslyResident": False}, {"id": "decode-stage", "componentIDs": ["vae-decoder"], "simultaneouslyResident": False}]},
        "records": {"provenance": {"path": "provenance.json", "sha256": sha256_file(staging / "provenance.json")}, "validation": {"path": "validation.json", "sha256": sha256_file(staging / "validation.json")}},
        "licenses": [
            {"spdx": "Apache-2.0", "appliesTo": "Tongyi-MAI/Z-Image-Turbo weights and publisher resources", "path": "Licenses/Apache-2.0.txt", "sha256": sha256_file(staging / "Licenses" / "Apache-2.0.txt"), "noticePath": "Licenses/NOTICE.txt", "noticeSHA256": sha256_file(notice_path)},
            {"spdx": "BSD-3-Clause", "appliesTo": "Apple coreai-models conversion tooling provenance", "path": "Licenses/coreai-models-BSD-3-Clause.txt", "sha256": sha256_file(staging / "Licenses" / "coreai-models-BSD-3-Clause.txt")},
        ],
        "inventory": [],
    }
    _validate_validation_record(validation, manifest)
    manifest["inventory"] = inventory_for(staging)
    write_atomic_new_json(staging / "manifest.json", manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging.rename(output)
    try:
        validate_package(output)
        with tempfile.TemporaryDirectory(prefix="pixaimodel-clean-") as clean_directory:
            clean_environment = {
                "PATH": "/usr/bin:/bin",
                "PYTHONDONTWRITEBYTECODE": "1",
                "LC_ALL": "C",
            }
            subprocess.run(
                ["/usr/bin/python3", str(HERE / "pixaimodel.py"), "validate-package", str(output)],
                check=True, cwd=clean_directory, env=clean_environment,
            )
    except Exception:
        output.rename(staging)
        raise
    print(f"assembled and validated {output}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--publisher-reference", required=True)
    parser.add_argument("--apple-reference", required=True)
    parser.add_argument("--validation", required=True)
    return parser


def main() -> int:
    try:
        assemble(build_parser().parse_args())
    except (ContractError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
