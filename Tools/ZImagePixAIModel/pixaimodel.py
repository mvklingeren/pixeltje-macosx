#!/usr/bin/env python3
"""Dependency-free source and package validator for Pixeltje AI model builds.

The JSON Schema files are the serialized format contracts. This module also
enforces constraints that JSON Schema cannot express: safe package paths,
directory-tree digests, inventory closure, descriptor/manifest agreement, and
the required Z-Image native-resolution and parity gates.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable
from urllib.parse import urlparse


SCHEMA_VERSION = "1.0.0"
HERE = Path(__file__).resolve().parent
SCHEMA_DIR = HERE / "schemas"
MANIFEST_SCHEMA = SCHEMA_DIR / "pixaimodel-manifest-1.0.schema.json"
PIPELINE_SCHEMA = SCHEMA_DIR / "pixaimodel-pipeline-1.0.schema.json"
VALIDATION_SCHEMA = SCHEMA_DIR / "pixaimodel-validation-1.0.schema.json"
PROVENANCE_SCHEMA = SCHEMA_DIR / "pixaimodel-provenance-1.0.schema.json"

FORBIDDEN_SUFFIXES = {
    ".ckpt", ".pt", ".pth", ".safetensors", ".mlmodel", ".mlpackage",
    ".mlmodelc", ".py", ".pyc", ".js", ".dylib", ".so", ".bundle",
}
ALLOWED_PIPELINE_OPERATIONS = {
    "chat-template", "tokenize", "seeded-noise", "core-ai",
    "tensor-reshape", "tensor-pack", "tensor-patchify", "tensor-unpatchify",
    "tensor-slice", "tensor-concatenate", "rope", "flow-match-euler-loop",
    "vae-affine", "normalize", "tiled-execution", "source-prepare",
    "mask-prepare", "masked-latent-compose", "preview-output", "final-output",
}
PIPELINE_COMPONENT_OPERATIONS = {
    "core-ai", "flow-match-euler-loop", "tiled-execution",
}
PIPELINE_RESOURCE_FIELDS = {
    "resource": "file",
    "resourceDirectory": "directory",
    "schedulerConfiguration": "file",
}
REQUIRED_PIPELINE_RESOURCES = {
    "chat-template": ("resource",),
    "tokenize": ("resourceDirectory",),
    "flow-match-euler-loop": ("schedulerConfiguration",),
}
REQUIRED_RESOLUTIONS = {
    (512, 512), (1024, 1024), (1280, 720), (720, 1280),
    (2048, 1152), (1152, 2048), (2048, 2048),
}
REQUIRED_GATES = {
    "source-hashes",
    "tokenizer-chat-template",
    "prompt-encoder-parity",
    "denoiser-parity",
    "vae-encoder-parity",
    "vae-decoder-parity",
    "glue-unit-tests",
    "typed-pipeline-contract",
    "pipeline-parity",
    "repeatability",
    "text-to-image-no-vae-encoder",
    "resolution-matrix",
    "fresh-invocations",
    "specialization-residency-function",
    "cancellation-cleanup",
    "performance-recorded",
    "package-integrity",
    "clean-environment",
}
UNIMPLEMENTED_REQUIRED_GATES = frozenset({
    "typed-pipeline-contract",
    "fresh-invocations",
    "specialization-residency-function",
    "cancellation-cleanup",
    "text-to-image-no-vae-encoder",
})
REQUIRED_COMPONENT_PARITY = {
    ("prompt-encoder", "fixed-512-tokens"): (
        "peakSignalToNoiseRatio",
        40.0,
    ),
    ("denoiser", "dynamic-image-dynamic-prompt-bucket"): (
        "peakSignalToNoiseRatio",
        40.0,
    ),
    ("vae-encoder", "direct-up-to-9216-tokens"): (
        "correlation",
        0.99999,
    ),
    ("vae-encoder", "overlapped-tiles-up-to-16384-tokens"): (
        "correlation",
        0.9999,
    ),
    ("vae-decoder", "direct-up-to-9216-tokens"): (
        "correlation",
        0.9999,
    ),
    ("vae-decoder", "overlapped-tiles-up-to-16384-tokens"): (
        "correlation",
        0.9999,
    ),
}
ZIMAGE_SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"
REQUIRED_EXPORT_CONTRACTS = {
    "prompt-encoder": ("fixed-512-tokens", "float16", "float16"),
    "denoiser": (
        "dynamic-image-dynamic-prompt-bucket",
        "bfloat16",
        "bfloat16-with-float32-timestep-and-rope",
    ),
    "vae-encoder": ("dynamic-512-2048", "float32", "float32"),
    "vae-decoder": ("dynamic-512-2048", "float32", "float32"),
}


class ContractError(RuntimeError):
    pass


def require_implemented_release_gates() -> None:
    """Refuse release claims for gates without implementation-owned evidence."""

    if UNIMPLEMENTED_REQUIRED_GATES:
        raise ContractError(
            "required release gates lack implementation-owned validation: "
            f"{sorted(UNIMPLEMENTED_REQUIRED_GATES)}"
        )


def _is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _guard_forbidden_source(path: Path) -> None:
    forbidden = Path.home() / "source" / "pixeltje"
    if _is_within(path, forbidden):
        raise ContractError(f"forbidden external source path: {path}")


def lexical_path(path: Path) -> Path:
    lexical = Path(os.path.abspath(os.path.expanduser(os.fspath(path))))
    _guard_forbidden_source(lexical)
    return lexical


def guarded_resolve(path: Path) -> Path:
    """Resolve a path only after rejecting the forbidden sibling lexically."""

    lexical = lexical_path(path)
    resolved = lexical.resolve(strict=False)
    _guard_forbidden_source(resolved)
    return resolved


def outside_checkout(path: Path) -> Path:
    """Require a durable artifact/evidence path outside this Git checkout."""

    lexical = lexical_path(path)
    checkout = HERE.parent.parent
    if lexical.is_symlink():
        raise ContractError(f"durable build path must not be a symlink: {lexical}")
    if _is_within(lexical, checkout):
        raise ContractError(f"durable build path must stay outside Git: {lexical}")
    resolved = guarded_resolve(lexical)
    if _is_within(resolved, checkout):
        raise ContractError(f"durable build path must stay outside Git: {resolved}")
    return resolved


def _glue_test_source_files() -> list[Path]:
    repository = HERE.parent.parent
    paths = list(HERE.glob("*.py"))
    paths.extend((HERE / "tests").glob("test_*.py"))
    paths.extend((HERE / "schemas").glob("*.json"))
    paths.extend((HERE / "pipelines").glob("*.json"))
    paths.append(repository / "Scripts" / "build-zimage-pixaimodel.sh")
    return sorted(set(paths), key=lambda path: path.relative_to(repository).as_posix())


def glue_test_tool_digest() -> str:
    repository = HERE.parent.parent
    digest = hashlib.sha256()
    for path in _glue_test_source_files():
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"glue test input is missing or unsafe: {path}")
        relative = path.relative_to(repository).as_posix()
        digest.update(
            b"F\0"
            + relative.encode("utf-8")
            + b"\0"
            + str(path.stat().st_size).encode("ascii")
            + b"\0"
            + sha256_file(path).encode("ascii")
            + b"\n"
        )
    return digest.hexdigest()


def expected_glue_test_count() -> int:
    count = 0
    for path in sorted((HERE / "tests").glob("test_*.py")):
        if path.is_symlink() or not path.is_file():
            raise ContractError(f"glue test source is missing or unsafe: {path}")
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        count += sum(
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
            for node in ast.walk(tree)
        )
    if count <= 0:
        raise ContractError("no glue/validator tests were discovered")
    return count


def verify_glue_test_log(path: Path) -> dict[str, Any]:
    path = outside_checkout(path)
    if not path.is_file() or path.is_symlink():
        raise ContractError(f"glue test log is not a regular file: {path}")
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ContractError(f"glue test log is unexpectedly large: {path}")
    try:
        contents = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise ContractError(f"glue test log is not UTF-8: {path}") from error
    matches = re.findall(r"^Ran ([1-9][0-9]*) tests? in [^\r\n]+$", contents, re.MULTILINE)
    expected_count = expected_glue_test_count()
    if len(matches) != 1 or int(matches[0]) != expected_count:
        raise ContractError(
            f"glue test log does not prove all {expected_count} current tests ran: {path}"
        )
    if "FAILED" in contents or re.search(
        r"(?:^|\n)OK(?: \([^\r\n]+\))?\s*\Z", contents
    ) is None:
        raise ContractError(f"glue test log does not end in a passing unittest result: {path}")
    return {
        "file": path.name,
        "digestAlgorithm": "sha256",
        "digest": sha256_file(path),
        "testCount": expected_count,
        "toolDigestAlgorithm": "sha256-file-set-v1",
        "toolDigest": glue_test_tool_digest(),
    }


def _no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _reject_nonfinite_json_constant(value: str) -> None:
    raise ContractError(f"non-finite JSON number is not permitted: {value}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_no_duplicate_object,
            parse_constant=_reject_nonfinite_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read JSON {path}: {error}") from error


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def write_canonical_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json_bytes(value))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tree_files(root: Path) -> Iterable[Path]:
    for directory, names, filenames in os.walk(root, followlinks=False):
        names.sort()
        filenames.sort()
        directory_path = Path(directory)
        for name in names:
            candidate = directory_path / name
            if candidate.is_symlink():
                raise ContractError(f"symlink is forbidden: {candidate}")
        for name in filenames:
            candidate = directory_path / name
            if candidate.is_symlink():
                raise ContractError(f"symlink is forbidden: {candidate}")
            yield candidate


def sha256_tree(path: Path) -> str:
    """Digest a directory without depending on metadata or traversal order.

    sha256-tree-v1 hashes a line for every regular file:
    ``F NUL relative-posix-path NUL decimal-size NUL file-sha256 LF``.
    Empty directories are intentionally not represented.
    """
    if not path.is_dir() or path.is_symlink():
        raise ContractError(f"tree digest target is not a real directory: {path}")
    digest = hashlib.sha256()
    files = sorted(_tree_files(path), key=lambda item: item.relative_to(path).as_posix())
    for child in files:
        mode = child.stat().st_mode
        if not stat.S_ISREG(mode):
            raise ContractError(f"non-regular package entry is forbidden: {child}")
        relative = child.relative_to(path).as_posix()
        line = f"F\0{relative}\0{child.stat().st_size}\0{sha256_file(child)}\n"
        digest.update(line.encode("utf-8"))
    return digest.hexdigest()


def _resolve_ref(reference: str, root_schema: dict[str, Any]) -> Any:
    if not reference.startswith("#/"):
        raise ContractError(f"only local JSON Schema references are supported: {reference}")
    value: Any = root_schema
    for segment in reference[2:].split("/"):
        segment = segment.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or segment not in value:
            raise ContractError(f"unresolved JSON Schema reference: {reference}")
        value = value[segment]
    return value


def _is_type(instance: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(instance, dict)
    if expected == "array":
        return isinstance(instance, list)
    if expected == "string":
        return isinstance(instance, str)
    if expected == "boolean":
        return isinstance(instance, bool)
    if expected == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool) and math.isfinite(instance)
    if expected == "null":
        return instance is None
    raise ContractError(f"validator does not implement JSON Schema type {expected!r}")


def validate_schema(instance: Any, schema: dict[str, Any], root_schema: dict[str, Any] | None = None, location: str = "$") -> None:
    root_schema = root_schema or schema
    if "$ref" in schema:
        validate_schema(instance, _resolve_ref(schema["$ref"], root_schema), root_schema, location)
        return
    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            try:
                validate_schema(instance, option, root_schema, location)
                matches += 1
            except ContractError:
                pass
        if matches != 1:
            raise ContractError(f"{location}: expected exactly one oneOf match, got {matches}")
        return
    if "const" in schema and instance != schema["const"]:
        raise ContractError(f"{location}: expected constant {schema['const']!r}, got {instance!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise ContractError(f"{location}: value {instance!r} is not in {schema['enum']!r}")
    expected_type = schema.get("type")
    if expected_type is not None and not _is_type(instance, expected_type):
        raise ContractError(f"{location}: expected {expected_type}, got {type(instance).__name__}")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in instance]
        if missing:
            raise ContractError(f"{location}: missing required keys {missing}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extras = sorted(set(instance) - set(properties))
            if extras:
                raise ContractError(f"{location}: unsupported keys {extras}")
        for key, child in instance.items():
            if key in properties:
                validate_schema(child, properties[key], root_schema, f"{location}.{key}")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            raise ContractError(f"{location}: too few items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise ContractError(f"{location}: too many items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
            if len(set(encoded)) != len(encoded):
                raise ContractError(f"{location}: items must be unique")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, child in enumerate(instance):
                validate_schema(child, item_schema, root_schema, f"{location}[{index}]")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise ContractError(f"{location}: string is too short")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            raise ContractError(f"{location}: {instance!r} does not match {schema['pattern']!r}")
        if schema.get("format") == "uri":
            parsed = urlparse(instance)
            if not parsed.scheme or (parsed.scheme in {"http", "https"} and not parsed.netloc):
                raise ContractError(f"{location}: invalid URI {instance!r}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise ContractError(f"{location}: {instance} is below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise ContractError(f"{location}: {instance} is above maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            raise ContractError(f"{location}: {instance} is not above {schema['exclusiveMinimum']}")
        if "multipleOf" in schema:
            quotient = instance / schema["multipleOf"]
            if not math.isclose(quotient, round(quotient), rel_tol=0, abs_tol=1e-9):
                raise ContractError(f"{location}: {instance} is not a multiple of {schema['multipleOf']}")


def validate_json_file(path: Path, schema_path: Path) -> Any:
    instance = load_json(path)
    schema = load_json(schema_path)
    validate_schema(instance, schema)
    return instance


def safe_relative_path(value: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ContractError(f"unsafe package path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ContractError(f"unsafe package path: {value!r}")
    return path


def package_path(root: Path, relative: str) -> Path:
    safe = safe_relative_path(relative)
    candidate = root.joinpath(*safe.parts)
    resolved_root = root.resolve()
    resolved = candidate.resolve(strict=False)
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise ContractError(f"package path escapes root: {relative!r}")
    return candidate


def _unique_ids(items: list[dict[str, Any]], label: str) -> None:
    values = [item["id"] for item in items]
    if len(values) != len(set(values)):
        raise ContractError(f"duplicate {label} IDs")


def validate_pipeline_contract(descriptor: dict[str, Any]) -> None:
    _unique_ids(descriptor["parameters"], "pipeline parameter")
    _unique_ids(descriptor["nodes"], "pipeline node")
    _unique_ids(descriptor["outputs"], "pipeline output")
    nodes = {item["id"]: item for item in descriptor["nodes"]}
    parameters = {item["id"] for item in descriptor["parameters"]}
    produced: set[str] = set()
    consumed_targets: set[str] = set()
    used_parameters: set[str] = set()
    dependencies: dict[str, set[str]] = {node_id: set() for node_id in nodes}
    dependents: dict[str, set[str]] = {node_id: set() for node_id in nodes}

    for node in nodes.values():
        if node["operation"] not in ALLOWED_PIPELINE_OPERATIONS:
            raise ContractError(f"pipeline node {node['id']} uses forbidden operation {node['operation']!r}")
        if len(node["inputs"]) != len(set(node["inputs"])):
            raise ContractError(f"pipeline node {node['id']} has duplicate input ports")
        if len(node["outputs"]) != len(set(node["outputs"])):
            raise ContractError(f"pipeline node {node['id']} has duplicate output ports")
        if node["operation"] in PIPELINE_COMPONENT_OPERATIONS:
            semantic_id = node["configuration"].get("componentID")
            if not isinstance(semantic_id, str) or not semantic_id:
                raise ContractError(f"component node {node['id']} lacks semantic componentID")
            if "artifact" in node["configuration"] or "filename" in node["configuration"]:
                raise ContractError(f"component node {node['id']} must not bind an artifact filename")
        if node["operation"] == "flow-match-euler-loop":
            scheduler = node["configuration"].get("scheduler")
            if not isinstance(scheduler, str) or not scheduler:
                raise ContractError(f"denoise loop {node['id']} lacks a semantic scheduler ID")
        for field in REQUIRED_PIPELINE_RESOURCES.get(node["operation"], ()):
            if field not in node["configuration"]:
                raise ContractError(
                    f"pipeline node {node['id']} lacks required resource field {field!r}"
                )
        for field in PIPELINE_RESOURCE_FIELDS:
            if field in node["configuration"]:
                try:
                    safe_relative_path(node["configuration"][field])
                except ContractError as error:
                    raise ContractError(
                        f"pipeline node {node['id']} has unsafe {field}: {error}"
                    ) from error
        forbidden_keys = {"code", "command", "script", "expression", "eval", "executable"}
        if forbidden_keys.intersection(node["configuration"]):
            raise ContractError(f"pipeline node {node['id']} contains executable configuration")
        for port in node["outputs"]:
            endpoint = f"node:{node['id']}.{port}"
            if endpoint in produced:
                raise ContractError(f"duplicate produced endpoint {endpoint}")
            produced.add(endpoint)

    for edge in descriptor["edges"]:
        source, target = edge["from"], edge["to"]
        if source.startswith("parameter:"):
            parameter_id = source.split(":", 1)[1]
            if parameter_id not in parameters:
                raise ContractError(f"edge references unknown parameter {parameter_id!r}")
            used_parameters.add(parameter_id)
        elif source not in produced:
            raise ContractError(f"edge references unknown node output {source!r}")
        target_match = re.fullmatch(r"node:([a-z0-9-]+)\.([a-z0-9-]+)", target)
        if target_match is None or target_match.group(1) not in nodes:
            raise ContractError(f"edge targets unknown node input {target!r}")
        if target_match.group(2) not in nodes[target_match.group(1)]["inputs"]:
            raise ContractError(f"edge targets undeclared input {target!r}")
        if target in consumed_targets:
            raise ContractError(f"more than one edge drives {target!r}")
        consumed_targets.add(target)
        if source.startswith("node:"):
            source_node = source.removeprefix("node:").split(".", 1)[0]
            target_node = target_match.group(1)
            dependencies[target_node].add(source_node)
            dependents[source_node].add(target_node)

    expected_targets = {
        f"node:{node['id']}.{port}"
        for node in nodes.values()
        for port in node["inputs"]
    }
    missing_targets = sorted(expected_targets - consumed_targets)
    if missing_targets:
        raise ContractError(f"pipeline node inputs lack edges: {missing_targets}")
    unused_parameters = sorted(parameters - used_parameters)
    if unused_parameters:
        raise ContractError(f"pipeline parameters are unused: {unused_parameters}")

    indegree = {node_id: len(required) for node_id, required in dependencies.items()}
    ready = sorted(node_id for node_id, count in indegree.items() if count == 0)
    visited: set[str] = set()
    while ready:
        node_id = ready.pop()
        visited.add(node_id)
        for dependent in dependents[node_id]:
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                ready.append(dependent)
    if len(visited) != len(nodes):
        cyclic = sorted(set(nodes) - visited)
        raise ContractError(f"pipeline graph contains a cycle involving {cyclic}")

    output_nodes: set[str] = set()
    for output in descriptor["outputs"]:
        if output["source"] not in produced:
            raise ContractError(f"pipeline output references unknown endpoint {output['source']!r}")
        output_nodes.add(output["source"].removeprefix("node:").split(".", 1)[0])

    reaches_output = set(output_nodes)
    pending = list(output_nodes)
    while pending:
        node_id = pending.pop()
        for dependency in dependencies[node_id]:
            if dependency not in reaches_output:
                reaches_output.add(dependency)
                pending.append(dependency)
    dead_nodes = sorted(set(nodes) - reaches_output)
    if dead_nodes:
        raise ContractError(f"pipeline nodes do not reach an output: {dead_nodes}")


def _pipeline_resource_references(
    descriptor: dict[str, Any],
) -> Iterable[tuple[dict[str, Any], str, str, str]]:
    for node in descriptor["nodes"]:
        configuration = node["configuration"]
        for field, kind in PIPELINE_RESOURCE_FIELDS.items():
            if field in configuration:
                yield node, field, configuration[field], kind


def _validate_pipeline_package_bindings(
    root: Path,
    descriptor: dict[str, Any],
    manifest: dict[str, Any],
) -> None:
    components = {component["id"]: component for component in manifest["components"]}
    used_component_roles: set[str] = set()
    role_requirements = {
        "core-ai": {"prompt-encoder"},
        "flow-match-euler-loop": {"denoiser"},
        "tiled-execution": {"vae-encoder", "vae-decoder"},
    }
    for node in descriptor["nodes"]:
        operation = node["operation"]
        if operation not in PIPELINE_COMPONENT_OPERATIONS:
            continue
        component_id = node["configuration"]["componentID"]
        component = components.get(component_id)
        if component is None:
            raise ContractError(
                f"pipeline node {node['id']} references absent component {component_id!r}"
            )
        used_component_roles.add(component["role"])
        allowed_roles = role_requirements.get(operation)
        if allowed_roles is not None and component["role"] not in allowed_roles:
            raise ContractError(
                f"pipeline node {node['id']} cannot use component role {component['role']!r}"
            )

    required_roles_by_mode = {
        "text-to-image": {"prompt-encoder", "denoiser", "vae-decoder"},
        "image-to-image": {
            "prompt-encoder", "denoiser", "vae-encoder", "vae-decoder",
        },
        "inpaint": {"prompt-encoder", "denoiser", "vae-encoder", "vae-decoder"},
        "outpaint": {"prompt-encoder", "denoiser", "vae-encoder", "vae-decoder"},
    }
    required_roles = set().union(
        *(required_roles_by_mode[mode] for mode in descriptor["modes"])
    )
    missing_roles = sorted(required_roles - used_component_roles)
    if missing_roles:
        raise ContractError(
            f"pipeline does not bind required component roles: {missing_roles}"
        )
    if (
        "text-to-image" in descriptor["modes"]
        and "vae-encoder" in used_component_roles
    ):
        raise ContractError("text-to-image pipeline must not bind a VAE encoder")

    inventory_entries = [
        (safe_relative_path(item["path"]), item["kind"])
        for item in manifest["inventory"]
    ]
    resources: dict[tuple[str, str], Path] = {}
    for node, field, relative, kind in _pipeline_resource_references(descriptor):
        safe = safe_relative_path(relative)
        target = package_path(root, relative)
        if target.is_symlink() or (
            kind == "file" and not target.is_file()
        ) or (
            kind == "directory" and not target.is_dir()
        ):
            raise ContractError(
                f"pipeline node {node['id']} references missing {kind} resource {relative!r}"
            )
        covered = any(
            inventory_path == safe
            or (inventory_kind == "directory" and inventory_path in safe.parents)
            for inventory_path, inventory_kind in inventory_entries
        )
        if not covered:
            raise ContractError(
                f"pipeline node {node['id']} resource is absent from inventory: {relative!r}"
            )
        resources[(node["id"], field)] = target

    schedulers = manifest["generation"]["schedulers"]
    scheduler_ids = [scheduler["id"] for scheduler in schedulers]
    if len(scheduler_ids) != len(set(scheduler_ids)):
        raise ContractError("manifest has duplicate scheduler IDs")
    scheduler_by_id = {scheduler["id"]: scheduler for scheduler in schedulers}
    default_scheduler = manifest["generation"]["defaults"]["scheduler"]
    if default_scheduler not in scheduler_by_id:
        raise ContractError(
            f"manifest default references absent scheduler {default_scheduler!r}"
        )
    pipeline_schedulers: set[str] = set()
    for node in descriptor["nodes"]:
        if node["operation"] != "flow-match-euler-loop":
            continue
        scheduler_id = node["configuration"]["scheduler"]
        pipeline_schedulers.add(scheduler_id)
        scheduler = scheduler_by_id.get(scheduler_id)
        if scheduler is None:
            raise ContractError(
                f"pipeline node {node['id']} references absent scheduler {scheduler_id!r}"
            )
        configuration = resources[(node["id"], "schedulerConfiguration")]
        actual_hash = sha256_file(configuration)
        if actual_hash != scheduler["configurationSHA256"]:
            raise ContractError(
                f"pipeline node {node['id']} scheduler configuration digest mismatch"
            )
    if default_scheduler not in pipeline_schedulers:
        raise ContractError(
            "pipeline denoise loop does not use the manifest default scheduler"
        )


def validate_pipeline_file(path: Path) -> dict[str, Any]:
    descriptor = validate_json_file(path, PIPELINE_SCHEMA)
    validate_pipeline_contract(descriptor)
    return descriptor


def _check_tensor_abi(component_id: str, variant: dict[str, Any]) -> None:
    dynamic_symbols: dict[str, tuple[int, int, int]] = {}
    for direction in ("inputs", "outputs"):
        tensors = variant[direction]
        names = [tensor["name"] for tensor in tensors]
        if len(names) != len(set(names)):
            raise ContractError(f"{component_id}/{variant['id']} has duplicate {direction} names")
        for tensor in tensors:
            if tensor["rank"] != len(tensor["dimensions"]):
                raise ContractError(f"{component_id}/{variant['id']} tensor {tensor['name']} rank disagrees with dimensions")
            for dimension in tensor["dimensions"]:
                if isinstance(dimension, dict):
                    if dimension["minimum"] > dimension["maximum"]:
                        raise ContractError(f"{component_id}/{variant['id']} has inverted dynamic dimension")
                    multiple = dimension.get("multipleOf", 1)
                    if dimension["minimum"] % multiple or dimension["maximum"] % multiple:
                        raise ContractError(f"{component_id}/{variant['id']} dynamic endpoints violate multipleOf")
                    symbol = dimension["symbol"]
                    contract = (dimension["minimum"], dimension["maximum"], multiple)
                    previous = dynamic_symbols.setdefault(symbol, contract)
                    if previous != contract:
                        raise ContractError(
                            f"{component_id}/{variant['id']} dynamic symbol {symbol!r} "
                            f"has inconsistent contracts: {previous} versus {contract}"
                        )


def _validate_validation_record(record: dict[str, Any], manifest: dict[str, Any]) -> None:
    if not record["complete"]:
        raise ContractError("validation record is explicitly incomplete")
    if record["packageIdentifier"] != manifest["package"]["identifier"]:
        raise ContractError("validation package identifier disagrees with manifest")
    gate_ids = [gate["id"] for gate in record["gates"]]
    if len(gate_ids) != len(set(gate_ids)):
        raise ContractError("validation record has duplicate gate IDs")
    gates = {gate["id"]: gate for gate in record["gates"]}
    missing = REQUIRED_GATES - set(gates)
    extra = set(gates) - REQUIRED_GATES
    if missing or extra:
        raise ContractError(
            "validation record gate IDs mismatch: "
            f"missing {sorted(missing)}, extra {sorted(extra)}"
        )
    require_implemented_release_gates()
    failed = sorted(gate_id for gate_id in REQUIRED_GATES if gates[gate_id]["status"] != "passed")
    if failed:
        raise ContractError(f"required validation gates did not pass: {failed}")

    resolution_keys = [
        (item["width"], item["height"]) for item in record["resolutionMatrix"]
    ]
    if len(resolution_keys) != len(set(resolution_keys)):
        raise ContractError("validation record has duplicate resolution rows")
    results = {
        (item["width"], item["height"]): item
        for item in record["resolutionMatrix"]
    }
    missing_shapes = REQUIRED_RESOLUTIONS - set(results)
    extra_shapes = set(results) - REQUIRED_RESOLUTIONS
    if missing_shapes or extra_shapes:
        raise ContractError(
            "resolution matrix shape mismatch: "
            f"missing {sorted(missing_shapes)}, extra {sorted(extra_shapes)}"
        )
    for shape in REQUIRED_RESOLUTIONS:
        result = results[shape]
        expected_tokens = (shape[0] // 16) * (shape[1] // 16)
        if result["status"] != "passed" or not result["native"] or result["resampled"]:
            raise ContractError(f"resolution {shape[0]}x{shape[1]} is not a passing native result")
        if result["imageTokens"] != expected_tokens:
            raise ContractError(f"resolution {shape[0]}x{shape[1]} reports the wrong image-token count")

    result_keys = [(item["id"], item["variant"]) for item in record["components"]]
    if len(result_keys) != len(set(result_keys)):
        raise ContractError("validation record has duplicate component variant results")
    component_results = {
        (item["id"], item["variant"]): item for item in record["components"]
    }
    manifest_keys = {
        (component["id"], variant["id"])
        for component in manifest["components"]
        for variant in component["variants"]
    }
    if manifest_keys != set(REQUIRED_COMPONENT_PARITY):
        raise ContractError(
            "manifest component variants disagree with the fixed Z-Image release contract"
        )
    extra_results = set(component_results) - manifest_keys
    if extra_results:
        raise ContractError(
            f"validation record has results for unshipped component variants: {sorted(extra_results)}"
        )
    for component in manifest["components"]:
        for variant in component["variants"]:
            key = (component["id"], variant["id"])
            if key not in component_results:
                raise ContractError(f"no validation result for component variant {key}")
            result = component_results[key]
            if not result["descriptorMatch"] or not result["finiteOutputs"] or result["parity"]["status"] != "passed":
                raise ContractError(f"component variant {key} did not pass descriptor/output/parity gates")
            expected_metric, minimum = REQUIRED_COMPONENT_PARITY[key]
            parity = result["parity"]
            if parity["metric"] != expected_metric:
                raise ContractError(
                    f"component variant {key} uses the wrong parity metric"
                )
            if (
                parity["threshold"] < minimum
                or parity["worstObserved"] < minimum
                or parity["worstObserved"] < parity["threshold"]
            ):
                raise ContractError(
                    f"component variant {key} is below its fixed parity gate"
                )
            if (
                result["assetDigestAlgorithm"] != variant["digestAlgorithm"]
                or result["assetDigest"] != variant["digest"]
            ):
                raise ContractError(
                    f"component variant {key} was validated against a different asset"
                )

    export_ids = [item["id"] for item in record["exports"]]
    if len(export_ids) != len(set(export_ids)):
        raise ContractError("validation record has duplicate conversion export IDs")
    exports = {item["id"]: item for item in record["exports"]}
    if set(exports) != set(REQUIRED_EXPORT_CONTRACTS):
        raise ContractError(
            "validation record conversion export IDs mismatch: "
            f"expected {sorted(REQUIRED_EXPORT_CONTRACTS)}, found {sorted(exports)}"
        )
    manifest_digests: dict[str, set[tuple[str, str]]] = {}
    for component in manifest["components"]:
        manifest_digests[component["id"]] = {
            (variant["digestAlgorithm"], variant["digest"])
            for variant in component["variants"]
        }
    source_locks: set[str] = set()
    converter_tools: set[str] = set()
    for component_id, expected_contract in REQUIRED_EXPORT_CONTRACTS.items():
        item = exports[component_id]
        actual_contract = (
            item["variant"], item["precision"], item["computationPrecision"]
        )
        if actual_contract != expected_contract:
            raise ContractError(
                f"conversion export {component_id} has the wrong release precision/variant contract"
            )
        if (
            item["converterMode"] != "release"
            or item["probe"] is not False
            or item["sourceRevision"] != ZIMAGE_SOURCE_REVISION
        ):
            raise ContractError(
                f"conversion export {component_id} is not a full pinned RELEASE export"
            )
        binding = (item["assetDigestAlgorithm"], item["assetDigest"])
        if manifest_digests.get(component_id) != {binding}:
            raise ContractError(
                f"conversion export {component_id} was produced for a different asset"
            )
        source_locks.add(item["sourceLockSHA256"])
        converter_tools.add(item["toolSHA256"])
    if len(source_locks) != 1 or len(converter_tools) != 1:
        raise ContractError(
            "conversion exports disagree on source-lock or converter-tool identity"
        )


def _inventory_coverage(root: Path, manifest: dict[str, Any]) -> None:
    inventory = manifest["inventory"]
    seen_paths: set[str] = set()
    directory_roots: list[PurePosixPath] = []
    for item in inventory:
        relative = safe_relative_path(item["path"])
        if item["path"] in seen_paths:
            raise ContractError(f"duplicate inventory path {item['path']!r}")
        seen_paths.add(item["path"])
        target = package_path(root, item["path"])
        if target.is_symlink():
            raise ContractError(f"inventory target is a symlink: {item['path']}")
        if item["kind"] == "file":
            if item["digestAlgorithm"] != "sha256" or not target.is_file():
                raise ContractError(f"inventory file is missing or uses the wrong digest algorithm: {item['path']}")
            actual = sha256_file(target)
        else:
            if item["digestAlgorithm"] != "sha256-tree-v1" or not target.is_dir():
                raise ContractError(f"inventory directory is missing or uses the wrong digest algorithm: {item['path']}")
            for parent in directory_roots:
                if parent == relative or parent in relative.parents or relative in parent.parents:
                    raise ContractError(f"overlapping inventory directories: {parent} and {relative}")
            directory_roots.append(relative)
            actual = sha256_tree(target)
        if actual != item["digest"]:
            raise ContractError(f"inventory digest mismatch for {item['path']}: expected {item['digest']}, got {actual}")

    manifest_path = root / "manifest.json"
    for child in _tree_files(root):
        relative = PurePosixPath(child.relative_to(root).as_posix())
        if child == manifest_path:
            continue
        covered = relative.as_posix() in seen_paths or any(parent in relative.parents for parent in directory_roots)
        if not covered:
            raise ContractError(f"package file is absent from manifest inventory: {relative}")


def validate_package(root: Path) -> dict[str, Any]:
    lexical_root = lexical_path(root)
    if lexical_root.is_symlink():
        raise ContractError(f"package must not be a symlink: {lexical_root}")
    root = guarded_resolve(lexical_root)
    if not root.is_dir() or root.suffix != ".pixaimodel":
        raise ContractError(f"package must be a real .pixaimodel directory: {root}")
    for child in _tree_files(root):
        lower = child.name.lower()
        if any(lower.endswith(suffix) for suffix in FORBIDDEN_SUFFIXES):
            raise ContractError(f"forbidden executable/training/runtime format in package: {child.relative_to(root)}")

    manifest = validate_json_file(root / "manifest.json", MANIFEST_SCHEMA)
    components = manifest["components"]
    pipelines = manifest["pipelines"]
    _unique_ids(components, "component")
    _unique_ids(pipelines, "pipeline")
    component_ids = {item["id"] for item in components}
    if {"prompt-encoder", "denoiser", "vae-decoder"} - component_ids:
        raise ContractError("text-to-image package lacks a required learned component")

    inventory = {item["path"]: item for item in manifest["inventory"]}
    for component in components:
        variant_ids = [item["id"] for item in component["variants"]]
        if len(variant_ids) != len(set(variant_ids)):
            raise ContractError(f"component {component['id']} has duplicate variant IDs")
        for variant in component["variants"]:
            _check_tensor_abi(component["id"], variant)
            entry = inventory.get(variant["artifact"])
            if entry is None or entry["kind"] != "directory":
                raise ContractError(f"component artifact is not a directory inventory item: {variant['artifact']}")
            if entry["digest"] != variant["digest"] or entry["digestAlgorithm"] != variant["digestAlgorithm"]:
                raise ContractError(f"component digest disagrees with inventory: {variant['artifact']}")

    pipeline_modes: set[str] = set()
    for pipeline in pipelines:
        path = package_path(root, pipeline["descriptor"])
        descriptor = validate_pipeline_file(path)
        actual_hash = sha256_file(path)
        if actual_hash != pipeline["descriptorSHA256"]:
            raise ContractError(f"pipeline descriptor hash mismatch: {pipeline['descriptor']}")
        for key in ("id", "version", "minimumRuntime", "modes"):
            manifest_key = "minimumRuntime" if key == "minimumRuntime" else key
            if descriptor[key] != pipeline[manifest_key]:
                raise ContractError(f"pipeline descriptor {key} disagrees with manifest")
        _validate_pipeline_package_bindings(root, descriptor, manifest)
        pipeline_modes.update(descriptor["modes"])
    if pipeline_modes != set(manifest["generation"]["modes"]):
        raise ContractError("manifest generation modes disagree with shipped pipelines")

    resolution = manifest["generation"]["resolution"]
    expected_resolution = (512, 2048, 512, 2048, 16, True, 16384, False)
    actual_resolution = (
        resolution["minimumWidth"], resolution["maximumWidth"], resolution["minimumHeight"],
        resolution["maximumHeight"], resolution["requiredMultiple"], resolution["independentAxes"],
        resolution["maximumImageTokens"], resolution["resamplingFallback"],
    )
    if actual_resolution != expected_resolution:
        raise ContractError(f"Z-Image resolution contract is not native independent 512...2048/16: {actual_resolution}")

    provenance_ref = manifest["records"]["provenance"]
    provenance_path = package_path(root, provenance_ref["path"])
    if sha256_file(provenance_path) != provenance_ref["sha256"]:
        raise ContractError("provenance record digest mismatch")
    provenance = validate_json_file(provenance_path, PROVENANCE_SCHEMA)
    if provenance["packageIdentifier"] != manifest["package"]["identifier"]:
        raise ContractError("provenance package identifier disagrees with manifest")

    validation_ref = manifest["records"]["validation"]
    validation_path = package_path(root, validation_ref["path"])
    if sha256_file(validation_path) != validation_ref["sha256"]:
        raise ContractError("validation record digest mismatch")
    validation = validate_json_file(validation_path, VALIDATION_SCHEMA)
    _validate_validation_record(validation, manifest)
    if provenance["conversionExports"] != validation["exports"]:
        raise ContractError(
            "provenance conversion exports disagree with the validation record"
        )

    for license_item in manifest["licenses"]:
        path = package_path(root, license_item["path"])
        if sha256_file(path) != license_item["sha256"]:
            raise ContractError(f"license digest mismatch: {license_item['path']}")
        if "noticePath" in license_item:
            notice = package_path(root, license_item["noticePath"])
            if sha256_file(notice) != license_item["noticeSHA256"]:
                raise ContractError(f"notice digest mismatch: {license_item['noticePath']}")

    _inventory_coverage(root, manifest)
    return manifest


def _git_head(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return result.stdout.strip()


def _require_clean_git_checkout(root: Path, label: str) -> None:
    """Reject staged, unstaged, untracked, or dirty-submodule checkout state."""
    result = subprocess.run(
        [
            "git",
            "--no-optional-locks",
            "-C",
            str(root),
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if not result.stdout:
        return
    entries = sorted(
        os.fsdecode(entry) for entry in result.stdout.split(b"\0") if entry
    )
    detail = ", ".join(repr(entry) for entry in entries)
    raise ContractError(
        f"{label} checkout is not clean; staged, unstaged, or untracked "
        f"content is forbidden: {detail}"
    )


def audit_git_checkout(root: Path, revision: str, label: str) -> Path:
    root = guarded_resolve(root)
    if _git_head(root) != revision:
        raise ContractError(f"{label} checkout is not at the locked revision")
    _require_clean_git_checkout(root, label)
    return root


def _lfs_pointer(path: Path) -> tuple[str, int] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) > 1024 or not data.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
        return None
    match = re.search(rb"oid sha256:([0-9a-f]{64})\nsize ([0-9]+)\n?", data)
    if match is None:
        return None
    return match.group(1).decode("ascii"), int(match.group(2))


def audit_source(source_root: Path, lock_path: Path, allow_lfs_pointers: bool) -> None:
    lock_path = guarded_resolve(lock_path)
    lock = load_json(lock_path)
    if lock.get("schemaVersion") != SCHEMA_VERSION:
        raise ContractError("unsupported source lock schema")
    model = lock["publisherModel"]
    source_root = audit_git_checkout(
        source_root, model["revision"], "publisher source"
    )
    for item in model["files"]:
        relative = safe_relative_path(item["path"])
        path = source_root.joinpath(*relative.parts)
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"missing locked source file: {item['path']}")
        pointer = _lfs_pointer(path)
        if pointer is not None:
            if item.get("storage") != "git-lfs" or pointer != (item["sha256"], item["size"]):
                raise ContractError(f"Git LFS pointer disagrees with source lock: {item['path']}")
            if not allow_lfs_pointers:
                raise ContractError(f"source weight is still a Git LFS pointer: {item['path']}")
            continue
        if "size" in item and path.stat().st_size != item["size"]:
            raise ContractError(f"source size mismatch for {item['path']}")
        actual = sha256_file(path)
        if actual != item["sha256"]:
            raise ContractError(f"source digest mismatch for {item['path']}: expected {item['sha256']}, got {actual}")


def audit_references(publisher_root: Path, apple_root: Path, lock_path: Path) -> None:
    lock_path = guarded_resolve(lock_path)
    lock = load_json(lock_path)
    publisher = lock["publisherReference"]
    tooling = lock["coreAITooling"]
    publisher_root = audit_git_checkout(
        publisher_root, publisher["revision"], "publisher reference"
    )
    apple_root = audit_git_checkout(
        apple_root, tooling["revision"], "Apple Core AI tooling"
    )
    checks = (
        (publisher_root / "LICENSE", publisher["licenseSHA256"], "publisher reference license"),
        (apple_root / "LICENSE", tooling["licenseSHA256"], "Apple tooling license"),
        (apple_root / "uv.lock", tooling["uvLockSHA256"], "Apple tooling uv.lock"),
    )
    for path, expected, label in checks:
        if not path.is_file() or path.is_symlink():
            raise ContractError(f"missing or unsafe {label}: {path}")
        actual = sha256_file(path)
        if actual != expected:
            raise ContractError(f"{label} digest mismatch: expected {expected}, got {actual}")


def command_validate_schemas(_: argparse.Namespace) -> None:
    for path in (MANIFEST_SCHEMA, PIPELINE_SCHEMA, VALIDATION_SCHEMA, PROVENANCE_SCHEMA):
        schema = load_json(path)
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise ContractError(f"unexpected JSON Schema dialect: {path}")
        if not isinstance(schema.get("$id"), str) or not schema["$id"].startswith("https://"):
            raise ContractError(f"schema has no stable HTTPS identity: {path}")
    print("schema documents: valid")


def command_validate_pipeline(args: argparse.Namespace) -> None:
    descriptor = validate_pipeline_file(Path(args.path))
    print(f"pipeline {descriptor['id']} {descriptor['version']}: valid")


def command_validate_package(args: argparse.Namespace) -> None:
    manifest = validate_package(Path(args.path))
    print(f"package {manifest['package']['identifier']} {manifest['package']['formatVersion']}: valid and complete")


def command_audit_source(args: argparse.Namespace) -> None:
    audit_source(Path(args.source), Path(args.lock), args.allow_lfs_pointers)
    state = "locked metadata and LFS pointers" if args.allow_lfs_pointers else "downloaded bytes"
    print(f"publisher source: verified {state}")


def command_audit_references(args: argparse.Namespace) -> None:
    audit_references(Path(args.publisher_reference), Path(args.apple_reference), Path(args.lock))
    print("publisher reference and Apple conversion tooling: verified revisions and license/lock bytes")


def command_digest(args: argparse.Namespace) -> None:
    path = Path(args.path)
    if path.is_dir():
        print(sha256_tree(path))
    else:
        print(sha256_file(path))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    schemas = subparsers.add_parser("validate-schemas")
    schemas.set_defaults(handler=command_validate_schemas)

    pipeline = subparsers.add_parser("validate-pipeline")
    pipeline.add_argument("path")
    pipeline.set_defaults(handler=command_validate_pipeline)

    package = subparsers.add_parser("validate-package")
    package.add_argument("path")
    package.set_defaults(handler=command_validate_package)

    source = subparsers.add_parser("audit-source")
    source.add_argument("--source", required=True)
    source.add_argument("--lock", default=str(HERE / "source-lock.json"))
    source.add_argument("--allow-lfs-pointers", action="store_true")
    source.set_defaults(handler=command_audit_source)

    references = subparsers.add_parser("audit-references")
    references.add_argument("--publisher-reference", required=True)
    references.add_argument("--apple-reference", required=True)
    references.add_argument("--lock", default=str(HERE / "source-lock.json"))
    references.set_defaults(handler=command_audit_references)

    digest = subparsers.add_parser("digest")
    digest.add_argument("path")
    digest.set_defaults(handler=command_digest)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.handler(args)
    except (ContractError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
