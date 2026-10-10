#!/usr/bin/env python3
"""Offline export of Meta's original SAM 3.1 image detector to Core AI.

Requires PyTorch, Transformers with Sam3Model, and coreai-torch. Model weights
must come from the original facebook/sam3.1 publisher, not a converted bundle.
"""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import coreai_torch
import torch
from coreai_torch import get_decomp_table
from sam31_key_mapping import map_detector_key
from transformers import AutoTokenizer, Sam3Config, Sam3Model

SOURCE_SHA256 = "0567debeec80ba4ac6369540c6c248025283cb3ff2b92827509e57e2b3541cb6"
SOURCE_REVISION = "daa63191845a41281374e725f4c9e51c7a824460"
ASSET_NAME = "sam31_detector_float16.aimodel"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def split_qkv(weights: dict[str, torch.Tensor]) -> None:
    for key in list(weights):
        if ".attention.qkv." in key:
            tensor = weights.pop(key)
            for name, part in zip(("q", "k", "v"), tensor.chunk(3, dim=0)):
                weights[key.replace(".qkv.", f".{name}_proj.")] = part
        elif ".in_proj_" in key:
            tensor = weights.pop(key)
            prefix, suffix = key.rsplit("in_proj_", 1)
            assert suffix in ("weight", "bias")
            for name, part in zip(("q", "k", "v"), tensor.chunk(3, dim=0)):
                weights[f"{prefix}{name}_proj.{suffix}"] = part


class ImageDetector(torch.nn.Module):
    def __init__(self, model: Sam3Model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values: torch.Tensor, input_ids: torch.Tensor):
        vision = self.model.vision_encoder(pixel_values)
        # SAM 3.1 has three FPN levels. Transformers' SAM 3 image forward
        # drops its last level because SAM 3 has four. Append a disposable
        # level so its existing forward consumes all three trained levels.
        vision.fpn_hidden_states = vision.fpn_hidden_states + (vision.fpn_hidden_states[-1],)
        vision.fpn_position_encoding = vision.fpn_position_encoding + (
            vision.fpn_position_encoding[-1],
        )
        result = self.model(vision_embeds=vision, input_ids=input_ids)
        return (
            result.pred_masks,
            result.pred_boxes,
            result.pred_logits,
            result.presence_logits,
            result.semantic_seg,
        )


def export(source: Path, output: Path) -> None:
    checkpoint = source / "sam3.1_multiplex.pt"
    if sha256_file(checkpoint) != SOURCE_SHA256:
        raise ValueError("Original SAM 3.1 checkpoint SHA-256 does not match the reviewed source.")
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"Output directory must be empty: {output}")
    config_data = json.loads((source / "config.json").read_text())
    config = Sam3Config.from_dict(config_data["detector_config"])
    config.vision_config.scale_factors = [4.0, 2.0, 1.0]
    original = torch.load(checkpoint, map_location="cpu", weights_only=True, mmap=True)
    weights = {
        map_detector_key(key): value
        for key, value in original.items()
        if key.startswith("detector.")
    }
    split_qkv(weights)
    weights["text_encoder.text_projection.weight"] = weights[
        "text_encoder.text_projection.weight"
    ].T
    weights["vision_encoder.backbone.embeddings.position_embeddings"] = weights[
        "vision_encoder.backbone.embeddings.position_embeddings"
    ][:, 1:, :]
    model = Sam3Model(config)
    expected = model.state_dict()
    missing = sorted(set(expected) - set(weights))
    bad_shapes = [
        key for key in expected.keys() & weights.keys()
        if expected[key].shape != weights[key].shape
    ]
    unused = set(weights) - set(expected)
    def allowed_unused(key: str) -> bool:
        return (
            key.startswith("backbone.vision_backbone.interactive_convs.")
            or key.startswith("backbone.vision_backbone.propagation_convs.")
            or key.startswith("geometry_encoder.points_")
            or key.startswith("vision_encoder.backbone.layers.")
            and key.endswith(".rotary_emb.rope_embeddings")
        )
    if missing or bad_shapes or len(unused) != 74 or not all(map(allowed_unused, unused)):
        raise ValueError(
            f"Unexpected source architecture: {len(missing)} missing, "
            f"{len(bad_shapes)} wrong shapes, {len(unused)} unused tensors."
        )
    model.load_state_dict({key: weights[key] for key in expected}, strict=True)
    detector = ImageDetector(model.eval().to(torch.float16)).eval()
    tokenizer = AutoTokenizer.from_pretrained(str(source), local_files_only=True)
    tokens = tokenizer(
        "object", max_length=32, padding="max_length", truncation=True, return_tensors="pt"
    )
    example = {
        "pixel_values": torch.randn(1, 3, 1008, 1008, dtype=torch.float16),
        "input_ids": tokens["input_ids"].to(torch.int32),
    }
    with torch.autocast(device_type="cpu", dtype=torch.float16):
        program = torch.export.export(detector, args=(), kwargs=example)
    program = program.run_decompositions(get_decomp_table())
    converter = coreai_torch.TorchConverter(mode=coreai_torch.TorchConverter.Mode.RELEASE)
    converter.add_exported_program(
        exported_program=program,
        input_names=["pixel_values", "input_ids"],
        output_names=[
            "pred_masks", "pred_boxes", "pred_logits", "presence_logits", "semantic_seg"
        ],
    )
    coreai_program = converter.to_coreai()
    coreai_program.optimize()
    output.mkdir(parents=True, exist_ok=True)
    coreai_program.save_asset(
        output / ASSET_NAME,
        {"source": "facebook/sam3.1", "component": "image detector"},
    )
    (output / "tokenizer").mkdir()
    for name in (
        "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        "vocab.json", "merges.txt",
    ):
        shutil.copy2(source / name, output / "tokenizer" / name)
    shutil.copy2(source / "LICENSE", output / "LICENSE")
    metadata = {
        "metadata_version": "0.2",
        "kind": "segmenter",
        "name": "sam31_detector_float16",
        "assets": {"main": ASSET_NAME},
        "source": "facebook/sam3.1",
        "source_revision": SOURCE_REVISION,
        "source_sha256": SOURCE_SHA256,
        "conversion": "SAM 3.1 three-level image detector, coreai_torch 0.4.2, float16, 32 tokens",
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Core AI model:", output / ASSET_NAME)
    print("Model identity:", (output / ASSET_NAME / "main.hash").read_bytes().hex())
    print("Tokenizer SHA-256:", sha256_file(output / "tokenizer/tokenizer.json"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True,
                        help="Directory holding original publisher checkpoint, config, tokenizer, and LICENSE")
    parser.add_argument("--output", type=Path, required=True,
                        help="Empty output directory for the linked Core AI package")
    args = parser.parse_args()
    export(args.source, args.output)
