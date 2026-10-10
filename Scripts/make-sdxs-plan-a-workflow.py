#!/usr/bin/env python3
"""Copy the Plan-A Klein workflow and link its image node to the SDXS export."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Examples/fantasy_scene_plan_a_flux2_klein_qwen3_coreai.pixpipeline.json"
OUTPUT = ROOT / "Examples/fantasy_scene_plan_a_sdxs_512_dreamshaper_qwen3_coreai.pixpipeline.json"
MODEL = Path.home() / "coreai-models/exports/SDXS-512-DreamShaper"
ASSETS = (
    ("textEncoder", "textEncoder", "TextEncoder.aimodel"),
    ("denoiser", "denoiser", "Unet.aimodel"),
    ("vaeDecoder", "vae", "VAEDecoder.aimodel"),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--package", type=Path, default=MODEL)
    parser.add_argument("--replace", action="store_true", help="replace the generated output")
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    package = args.package.expanduser().resolve(strict=True)
    if output.exists() and not args.replace:
        raise SystemExit(f"refusing to replace existing workflow: {output}")

    metadata_bytes = (package / "metadata.json").read_bytes()
    metadata = json.loads(metadata_bytes)
    if metadata["source"]["hf_model_id"] != "IDKiro/sdxs-512-dreamshaper":
        raise ValueError("package is not SDXS-512-DreamShaper")
    if metadata["source"]["revision"] != "76f720262bb051da75666b22c902a78c8e16c763":
        raise ValueError("package uses an unreviewed SDXS revision")
    identities = []
    hashes = {}
    for slot, _, filename in ASSETS:
        hash_bytes = (package / filename / "main.hash").read_bytes()
        if len(hash_bytes) != 32 or not (package / filename / "main.mlirb").is_file():
            raise ValueError(f"incomplete asset: {filename}")
        hashes[slot] = hash_bytes.hex()
        identities.append(f"{filename}:{hashes[slot]}")
    for filename in (
        "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
        "tokenizer/special_tokens_map.json", "tokenizer/vocab.json",
        "tokenizer/merges.txt",
    ):
        identities.append(f"{filename}:{sha256((package / filename).read_bytes())}")
    identities.append(f"metadata.json:{sha256(metadata_bytes)}")
    version = "sha256." + sha256("\n".join(identities).encode())

    workflow = json.loads(source.read_text())
    workflow["id"] = "org.pixeltje.pipeline.fantasy-scene-plan-a-qwen3-sdxs-512-dreamshaper"
    workflow["name"] = "Plan-A Open Fantasy World — Qwen3 and SDXS 512"
    nodes = [node for node in workflow["nodes"] if node["id"] == "generate"]
    if len(nodes) != 1 or nodes[0]["kind"] != "coreai.flux2KleinGenerate":
        raise ValueError("source workflow has no single Klein image node")
    node = nodes[0]
    node["kind"] = "coreai.sdxsGenerate"
    node["title"] = "SDXS 512 Generate"
    node["parameters"] = {
        "width": {"$type": "integer", "value": 512},
        "height": {"$type": "integer", "value": 512},
        "steps": {"$type": "integer", "value": 1},
        "guidance": {"$type": "number", "value": 0},
    }
    node["resources"] = {
        slot: {
            "state": "linked",
            "reference": {
                "kind": "coreAIModel",
                "packageID": "coreai.idkiro.sdxs-512-dreamshaper",
                "packageVersion": version,
                "contentHash": hashes[slot],
                "componentRole": role,
                "functionName": "main",
                "familyABI": "sdxs-512-dreamshaper-coreai@1",
            },
        }
        for slot, role, _ in ASSETS
    }
    output.write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + "\n")
    print(f"Ready: {output}")


if __name__ == "__main__":
    main()
