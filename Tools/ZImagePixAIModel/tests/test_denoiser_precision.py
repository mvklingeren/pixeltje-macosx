from __future__ import annotations

import argparse
import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from export_components import (  # noqa: E402
    DenoiserWrapper,
    _denoiser_inputs,
    _dynamic_shapes,
    make_rope,
)
from validate_components import parse_prompt_bucket, patchify_latents  # noqa: E402
import validate_components  # noqa: E402
from assemble import component_manifest  # noqa: E402
from pixaimodel import sha256_tree  # noqa: E402


class DenoiserPrecisionTests(unittest.TestCase):
    def test_coreai_only_report_records_finite_output_range(self) -> None:
        actual = torch.tensor([[[-2.5, 0.0, 3.75]]], dtype=torch.float32)

        class FakeModel:
            function_names = {"main"}

            @staticmethod
            def load_function(_name: str) -> object:
                return object()

        class FakeAIModel:
            @staticmethod
            async def load(_path: str, _options: object) -> FakeModel:
                return FakeModel()

        runtime = types.ModuleType("coreai.runtime")
        runtime.AIModel = FakeAIModel
        coreai = types.ModuleType("coreai")
        coreai.runtime = runtime
        arguments = argparse.Namespace(
            asset="diagnostic.aimodel",
            precision="bfloat16",
            shapes=[(512, 512)],
        )
        values = {"image_tokens": torch.zeros_like(actual)}

        with mock.patch.dict(
            sys.modules, {"coreai": coreai, "coreai.runtime": runtime}
        ), mock.patch.object(
            validate_components, "validation_specialization_options", return_value=object()
        ), mock.patch.object(
            validate_components, "specialization_record", return_value={}
        ), mock.patch.object(
            validate_components, "describe_function", return_value={"name": "main"}
        ), mock.patch.object(
            validate_components, "denoiser_case", return_value=(values, None, None)
        ), mock.patch.object(
            validate_components,
            "invoke",
            new=mock.AsyncMock(
                return_value=({"noise_prediction": actual.clone()}, 0.01)
            ),
        ), mock.patch.object(
            validate_components, "sha256_tree", return_value="a" * 64
        ), mock.patch.object(
            validate_components, "_system_record", return_value={}
        ):
            report = asyncio.run(
                validate_components.probe_denoiser_coreai(arguments)
            )

        summary = report["results"][0]["coreAIOutput"]
        self.assertEqual(summary["finiteMinimum"], -2.5)
        self.assertEqual(summary["finiteMaximum"], 3.75)
        self.assertEqual(summary["finiteCount"], actual.numel())
        self.assertEqual(summary["nanCount"], 0)
        self.assertEqual(len(summary["float32SHA256"]), 64)

    def test_rope_inputs_use_publisher_polar_rounding(self) -> None:
        _, _, _, cosine, sine = make_rope(32, 32, 17, 32, 32)

        prompt_positions = torch.zeros(32, 3, dtype=torch.int64)
        prompt_positions[:, 0] = torch.arange(1, 33)
        rows, columns = torch.meshgrid(
            torch.arange(32, dtype=torch.int64),
            torch.arange(32, dtype=torch.int64),
            indexing="ij",
        )
        image_positions = torch.stack(
            (torch.full_like(rows, 33), rows, columns), dim=-1
        ).reshape(-1, 3)
        positions = torch.cat((image_positions, prompt_positions), dim=0)
        frequencies = []
        for axis, dimension in enumerate((32, 48, 48)):
            inverse = 1.0 / (
                256.0
                ** (torch.arange(0, dimension, 2, dtype=torch.float64) / dimension)
            )
            frequencies.append(
                positions[:, axis : axis + 1].double() * inverse.unsqueeze(0)
            )
        angles = torch.cat(frequencies, dim=1).float()
        publisher = torch.polar(torch.ones_like(angles), angles).to(torch.complex64)

        torch.testing.assert_close(cosine, publisher.real, rtol=0.0, atol=0.0)
        torch.testing.assert_close(sine, publisher.imag, rtol=0.0, atol=0.0)
        self.assertTrue(cosine.is_contiguous())
        self.assertTrue(sine.is_contiguous())

    def test_rope_matches_float32_complex_publisher_operation(self) -> None:
        generator = torch.Generator().manual_seed(91)
        value = torch.randn(1, 7, 3, 8, generator=generator).to(torch.bfloat16)
        angles = torch.randn(1, 7, 4, generator=generator)
        cosine = angles.cos()
        sine = angles.sin()

        actual = DenoiserWrapper._apply_rope(value, cosine, sine)
        pairs = value.float().reshape(1, 7, 3, 4, 2)
        complex_value = torch.view_as_complex(pairs)
        frequencies = torch.complex(cosine, sine).unsqueeze(2)
        expected = (
            torch.view_as_real(complex_value * frequencies)
            .flatten(-2)
            .to(torch.bfloat16)
        )

        self.assertEqual(actual.dtype, torch.bfloat16)
        torch.testing.assert_close(actual, expected, rtol=0.0, atol=0.0)

    def test_denoiser_abi_keeps_publisher_precision_boundaries(self) -> None:
        for bucket in (32, 256, 512):
            values = _denoiser_inputs(
                torch.bfloat16, prompt_width=2560, prompt_bucket=bucket
            )

            self.assertEqual(values["image_tokens"].dtype, torch.bfloat16)
            self.assertEqual(values["prompt_embeddings"].dtype, torch.bfloat16)
            self.assertEqual(values["timestep"].dtype, torch.float32)
            for name in (
                "image_rope_cos",
                "image_rope_sin",
                "prompt_rope_cos",
                "prompt_rope_sin",
            ):
                self.assertEqual(values[name].dtype, torch.float32)
                self.assertTrue(values[name].is_contiguous())
            for name in (
                "prompt_embeddings",
                "prompt_padding_mask",
                "prompt_attention_mask",
                "prompt_rope_cos",
                "prompt_rope_sin",
            ):
                self.assertEqual(values[name].shape[1], bucket)
            for name in (
                "image_padding_mask",
                "prompt_padding_mask",
                "prompt_attention_mask",
            ):
                self.assertEqual(values[name].dtype, torch.bool)

    def test_denoiser_dynamic_shapes_share_grouped_axes(self) -> None:
        shapes = _dynamic_shapes("denoiser")
        assert shapes is not None
        image_tokens = shapes["image_tokens"][1]
        prompt_tokens = shapes["prompt_embeddings"][1]

        self.assertEqual((image_tokens.min, image_tokens.max), (1024, 16384))
        self.assertEqual((prompt_tokens.min, prompt_tokens.max), (32, 512))
        for name in (
            "image_padding_mask",
            "image_rope_cos",
            "image_rope_sin",
        ):
            self.assertIs(shapes[name][1], image_tokens)
        for name in (
            "prompt_padding_mask",
            "prompt_attention_mask",
            "prompt_rope_cos",
            "prompt_rope_sin",
        ):
            self.assertIs(shapes[name][1], prompt_tokens)
        self.assertIsNone(shapes["timestep"])

    def test_prompt_bucket_parser_rejects_non_abi_lengths(self) -> None:
        for value in ("32", "256", "512"):
            self.assertEqual(parse_prompt_bucket(value), int(value))
        for value in ("0", "31", "33", "544", "not-a-number"):
            with self.subTest(value=value), self.assertRaises(
                argparse.ArgumentTypeError
            ):
                parse_prompt_bucket(value)

    def test_manifest_denoiser_variant_declares_exact_dynamic_bfloat16_abi(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            components_root = Path(temporary) / "Components"
            for component in (
                "prompt-encoder",
                "denoiser",
                "vae-encoder",
                "vae-decoder",
            ):
                asset = components_root / f"{component}.aimodel"
                asset.mkdir(parents=True)
                (asset / "payload").write_bytes(component.encode("ascii"))
            variants = {
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
            validation = {"components": []}
            for component, component_variants in variants.items():
                digest = sha256_tree(components_root / f"{component}.aimodel")
                validation["components"].extend(
                    {
                        "id": component,
                        "variant": variant,
                        "assetDigestAlgorithm": "sha256-tree-v1",
                        "assetDigest": digest,
                        "estimatedResidentBytes": 1,
                    }
                    for variant in component_variants
                )
            components = component_manifest(components_root, validation)

        denoiser = next(item for item in components if item["id"] == "denoiser")
        variant = denoiser["variants"][0]
        self.assertEqual(variant["id"], "dynamic-image-dynamic-prompt-bucket")
        self.assertEqual(variant["functionName"], "main")
        self.assertEqual(variant["storageType"], "bfloat16")
        inputs = {item["name"]: item for item in variant["inputs"]}
        self.assertEqual(
            list(inputs),
            [
                "image_tokens",
                "image_padding_mask",
                "prompt_embeddings",
                "prompt_padding_mask",
                "prompt_attention_mask",
                "timestep",
                "image_rope_cos",
                "image_rope_sin",
                "prompt_rope_cos",
                "prompt_rope_sin",
            ],
        )
        self.assertEqual(inputs["image_tokens"]["scalarType"], "bfloat16")
        self.assertEqual(inputs["prompt_embeddings"]["scalarType"], "bfloat16")
        self.assertEqual(inputs["timestep"]["scalarType"], "float32")
        for name in ("image_rope_cos", "image_rope_sin", "prompt_rope_cos", "prompt_rope_sin"):
            self.assertEqual(inputs[name]["scalarType"], "float32")
        for name in ("image_padding_mask", "prompt_padding_mask", "prompt_attention_mask"):
            self.assertEqual(inputs[name]["scalarType"], "bool")
        image_axis = {"symbol": "image-tokens", "minimum": 1024, "maximum": 16384, "multipleOf": 32}
        prompt_axis = {"symbol": "prompt-tokens", "minimum": 32, "maximum": 512, "multipleOf": 32}
        for name in ("image_tokens", "image_padding_mask", "image_rope_cos", "image_rope_sin"):
            self.assertEqual(inputs[name]["dimensions"][1], image_axis)
        for name in ("prompt_embeddings", "prompt_padding_mask", "prompt_attention_mask", "prompt_rope_cos", "prompt_rope_sin"):
            self.assertEqual(inputs[name]["dimensions"][1], prompt_axis)
        self.assertEqual(
            variant["outputs"],
            [
                {
                    "name": "noise_prediction",
                    "scalarType": "bfloat16",
                    "rank": 3,
                    "dimensions": [1, image_axis, 64],
                    "layout": "BSC",
                    "semantic": "patchified raw transformer output",
                }
            ],
        )

    def test_rectangular_padded_tokens_have_a_distinct_valid_prefix(self) -> None:
        width, height = 1280, 720
        latent = torch.zeros(1, 16, height // 8, width // 8)
        tokens, padding = patchify_latents(latent)
        valid = (width // 16) * (height // 16)

        self.assertEqual(valid, 3600)
        self.assertEqual(tokens.shape[1], 3616)
        self.assertFalse(bool(padding[:, :valid].any()))
        self.assertTrue(bool(padding[:, valid:].all()))

    def test_manifest_schema_declares_bfloat16(self) -> None:
        schema_path = (
            Path(__file__).resolve().parents[1]
            / "schemas"
            / "pixaimodel-manifest-1.0.schema.json"
        )
        schema = json.loads(schema_path.read_text(encoding="utf-8"))

        self.assertIn("bfloat16", schema["$defs"]["tensor"]["properties"]["scalarType"]["enum"])
        self.assertIn("bfloat16", schema["$defs"]["variant"]["properties"]["storageType"]["enum"])


if __name__ == "__main__":
    unittest.main()
