from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pixaimodel import (  # noqa: E402
    ContractError,
    PIPELINE_SCHEMA,
    REQUIRED_GATES,
    UNIMPLEMENTED_REQUIRED_GATES,
    _validate_pipeline_package_bindings,
    load_json,
    sha256_file,
    validate_pipeline_contract,
    validate_schema,
)
from assemble import finalize_assembly_gates  # noqa: E402


HERE = Path(__file__).resolve().parents[1]


class PipelineContractTests(unittest.TestCase):
    def descriptor(self) -> dict:
        return copy.deepcopy(
            load_json(HERE / "pipelines" / "text-to-image.pipeline.json")
        )

    def assert_contract_rejects(self, descriptor: dict, pattern: str) -> None:
        validate_schema(descriptor, load_json(PIPELINE_SCHEMA))
        with self.assertRaisesRegex(ContractError, pattern):
            validate_pipeline_contract(descriptor)

    def test_every_declared_node_input_requires_one_edge(self) -> None:
        descriptor = self.descriptor()
        descriptor["edges"] = [
            edge
            for edge in descriptor["edges"]
            if edge["to"] != "node:denoise.prompt-embeddings"
        ]
        self.assert_contract_rejects(descriptor, "inputs lack edges")

    def test_pipeline_graph_must_be_acyclic(self) -> None:
        descriptor = self.descriptor()
        descriptor["edges"] = [
            edge
            for edge in descriptor["edges"]
            if edge["to"] != "node:denoise.prompt-embeddings"
        ]
        descriptor["edges"].append(
            {
                "from": "node:denoise.denoised-latents",
                "to": "node:denoise.prompt-embeddings",
            }
        )
        self.assert_contract_rejects(descriptor, "contains a cycle")

    def test_every_node_must_reach_a_pipeline_output(self) -> None:
        descriptor = self.descriptor()
        descriptor["nodes"].append(
            {
                "id": "dead-node",
                "operation": "normalize",
                "inputs": [],
                "outputs": ["unused"],
                "configuration": {},
            }
        )
        self.assert_contract_rejects(descriptor, "do not reach an output")

    def test_resource_paths_must_be_safe_package_relative_paths(self) -> None:
        descriptor = self.descriptor()
        descriptor["nodes"][0]["configuration"]["resource"] = "../../outside.json"
        with self.assertRaises(ContractError):
            validate_schema(descriptor, load_json(PIPELINE_SCHEMA))
        with self.assertRaisesRegex(ContractError, "unsafe resource"):
            validate_pipeline_contract(descriptor)

    def test_forged_passed_unimplemented_gates_cannot_finalize_assembly(self) -> None:
        self.assertEqual(
            UNIMPLEMENTED_REQUIRED_GATES,
            {
                "typed-pipeline-contract",
                "fresh-invocations",
                "specialization-residency-function",
                "cancellation-cleanup",
                "text-to-image-no-vae-encoder",
            },
        )
        validation = {
            "gates": [
                {
                    "id": gate,
                    "status": (
                        "blocked"
                        if gate in {"package-integrity", "clean-environment"}
                        else "passed"
                    ),
                    "evidence": ["test evidence"],
                }
                for gate in sorted(REQUIRED_GATES)
            ]
        }
        typed_gate = next(
            gate
            for gate in validation["gates"]
            if gate["id"] == "typed-pipeline-contract"
        )
        self.assertEqual(typed_gate["status"], "passed")
        with self.assertRaisesRegex(
            ContractError, "lack implementation-owned validation"
        ):
            finalize_assembly_gates(validation)

    def package_fixture(self, root: Path) -> tuple[dict, dict]:
        tokenizer = root / "Resources" / "tokenizer"
        scheduler = root / "Resources" / "scheduler" / "scheduler_config.json"
        tokenizer.mkdir(parents=True)
        scheduler.parent.mkdir(parents=True)
        (tokenizer / "tokenizer_config.json").write_text("{}\n", encoding="utf-8")
        scheduler.write_text('{"shift":3.0}\n', encoding="utf-8")
        manifest = {
            "components": [
                {"id": "prompt-encoder", "role": "prompt-encoder"},
                {"id": "denoiser", "role": "denoiser"},
                {"id": "vae-encoder", "role": "vae-encoder"},
                {"id": "vae-decoder", "role": "vae-decoder"},
            ],
            "generation": {
                "schedulers": [
                    {
                        "id": "flow-match-euler-discrete",
                        "configurationSHA256": sha256_file(scheduler),
                    }
                ],
                "defaults": {"scheduler": "flow-match-euler-discrete"},
            },
            "inventory": [
                {"path": "Resources/tokenizer", "kind": "directory"},
                {
                    "path": "Resources/scheduler/scheduler_config.json",
                    "kind": "file",
                },
            ],
        }
        return self.descriptor(), manifest

    def test_package_binding_rejects_unknown_component_for_learned_nodes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, manifest = self.package_fixture(root)
            for node_id, missing_id in (
                ("denoise", "missing-denoiser"),
                ("decode-image", "missing-decoder"),
            ):
                with self.subTest(node_id=node_id):
                    descriptor = copy.deepcopy(original)
                    next(
                        node for node in descriptor["nodes"] if node["id"] == node_id
                    )["configuration"]["componentID"] = missing_id
                    with self.assertRaisesRegex(ContractError, "absent component"):
                        _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_package_binding_rejects_swapped_prompt_component(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            next(
                node for node in descriptor["nodes"] if node["id"] == "encode-prompt"
            )["configuration"]["componentID"] = "denoiser"
            with self.assertRaisesRegex(ContractError, "cannot use component role"):
                _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_text_to_image_rejects_swapped_tiled_encoder(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            next(
                node for node in descriptor["nodes"] if node["id"] == "decode-image"
            )["configuration"]["componentID"] = "vae-encoder"
            with self.assertRaisesRegex(ContractError, "required component roles"):
                _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_package_bindings_accept_locked_descriptor_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_package_binding_requires_resource_inventory_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            manifest["inventory"] = [
                item
                for item in manifest["inventory"]
                if item["path"] != "Resources/scheduler/scheduler_config.json"
            ]
            with self.assertRaisesRegex(ContractError, "absent from inventory"):
                _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_package_binding_requires_scheduler_digest_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            manifest["generation"]["schedulers"][0]["configurationSHA256"] = "0" * 64
            with self.assertRaisesRegex(ContractError, "digest mismatch"):
                _validate_pipeline_package_bindings(root, descriptor, manifest)

    def test_pipeline_scheduler_must_match_manifest_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            descriptor, manifest = self.package_fixture(root)
            manifest["generation"]["schedulers"].append(
                {
                    "id": "alternate-scheduler",
                    "configurationSHA256": manifest["generation"]["schedulers"][0][
                        "configurationSHA256"
                    ],
                }
            )
            manifest["generation"]["defaults"]["scheduler"] = "alternate-scheduler"
            with self.assertRaisesRegex(ContractError, "manifest default scheduler"):
                _validate_pipeline_package_bindings(root, descriptor, manifest)


if __name__ == "__main__":
    unittest.main()
