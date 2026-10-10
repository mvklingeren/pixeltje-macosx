#!/usr/bin/env python3
"""Export the FLUX.2 Klein 9B Qwen3-8B-FP8 encoder in Core AI pieces.

Only Qwen layers needed for FLUX.2 hidden states 9, 18, and 27 are exported.
Each piece runs in a fresh process to bound conversion memory on a 24 GB Mac.
Pixeltje Pipeline executes this encoder as part of the assembled Klein 9B package.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import shutil
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path


LAYER_COUNT = 27
TEXT_TOKENS = 512
HIDDEN_DIM = 4096
HEAD_DIM = 128
TOKENIZER_FILES = ("tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json")
EXPECTED_SHARD_SHA256 = {
    "model-00001-of-00002.safetensors": "83bb444edc7d4a1ed91ab67ad19620e2ed74724cdd62ede330fcaa7748c64404",
    "model-00002-of-00002.safetensors": "c59d27856ca358b24770802ea52f1785258830f61ff3ac72a4b3896fad648f9b",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path, help="Qwen/Qwen3-8B-FP8 snapshot directory")
    parser.add_argument("output", type=Path, help="new directory for Core AI assets")
    parser.add_argument("--component", choices=("embedding", "layer"), help=argparse.SUPPRESS)
    parser.add_argument("--index", type=int, default=0, help=argparse.SUPPRESS)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def component_name(kind: str, index: int) -> str:
    return "Embedding.aimodel" if kind == "embedding" else f"Layer{index:02d}.aimodel"


def export_component(checkpoint: Path, output: Path, kind: str, index: int) -> None:
    import torch
    from coreai_models.diffusion.gpu import export_stateless
    from coreai_opt.coreai_utils import CompressionGranularity, DType, quantize_weights
    from safetensors import safe_open
    from transformers import Qwen3Config
    from transformers.models.qwen3.modeling_qwen3 import Qwen3DecoderLayer

    weight_map = json.loads((checkpoint / "model.safetensors.index.json").read_text())["weight_map"]
    prefix = "model.embed_tokens." if kind == "embedding" else f"model.layers.{index}."
    source_names = [name for name in weight_map if name.startswith(prefix)
                    and not name.endswith(".weight_scale_inv")]
    if not source_names:
        raise ValueError(f"no checkpoint tensors for {prefix}")

    with ExitStack() as stack:
        shards = {filename: stack.enter_context(safe_open(checkpoint / filename,
                                                         framework="pt", device="cpu"))
                  for filename in {weight_map[name] for name in source_names}}
        state = {}
        for name in source_names:
            weights = shards[weight_map[name]]
            value = weights.get_tensor(name)
            if value.dtype == torch.float8_e4m3fn:
                scale_name = name.removesuffix(".weight") + ".weight_scale_inv"
                scale = shards[weight_map[scale_name]].get_tensor(scale_name)
                rows, cols = value.shape
                scale_rows, scale_cols = scale.shape
                if rows % scale_rows or cols % scale_cols:
                    raise ValueError(f"invalid FP8 scale grid for {name}")
                value = (value.to(torch.float32).reshape(
                    scale_rows, rows // scale_rows, scale_cols, cols // scale_cols)
                    * scale.to(torch.float32)[:, None, :, None]).reshape(rows, cols)
            state[name.removeprefix(prefix)] = value.to(torch.float16)

    if kind == "embedding":
        with torch.device("meta"):
            module = torch.nn.Embedding(151936, HIDDEN_DIM)
        module.load_state_dict(state, strict=True, assign=True)
        inputs = (torch.zeros((1, TEXT_TOKENS), dtype=torch.int32),)
        input_names = ("input_ids",)
        output_names = ("hidden_out",)
        wrapper = module
    else:
        config = Qwen3Config.from_pretrained(checkpoint)
        config.quantization_config = None
        config._attn_implementation = "sdpa"
        with torch.device("meta"):
            layer = Qwen3DecoderLayer(config, index)
        layer.load_state_dict(state, strict=True, assign=True)

        class LayerWrapper(torch.nn.Module):
            def __init__(self, inner: torch.nn.Module) -> None:
                super().__init__()
                self.inner = inner

            def forward(self, hidden, attention_mask, cos, sin):
                return self.inner(hidden, attention_mask=attention_mask,
                                  position_embeddings=(cos, sin))

        wrapper = LayerWrapper(layer)
        inputs = (
            torch.zeros((1, TEXT_TOKENS, HIDDEN_DIM), dtype=torch.float16),
            torch.zeros((1, 1, TEXT_TOKENS, TEXT_TOKENS), dtype=torch.float16),
            torch.ones((1, TEXT_TOKENS, HEAD_DIM), dtype=torch.float16),
            torch.zeros((1, TEXT_TOKENS, HEAD_DIM), dtype=torch.float16),
        )
        input_names = ("hidden", "attention_mask", "cos", "sin")
        output_names = ("hidden_out",)
    del state
    gc.collect()

    program = export_stateless(wrapper, inputs, input_names, output_names)
    if kind == "layer":
        # The publisher's 128x128 FP8 scales are restored above. Recompress
        # Core AI weights per 128 input columns and per output row.
        program = quantize_weights(
            program, dtype=DType.FP8_E4M3FN,
            granularity=CompressionGranularity.PER_BLOCK, block_size=128,
            weight_num_threshold=32768, in_place=True,
        )
    program.save_asset(output)
    print(f"exported {output.name}", flush=True)


def main() -> None:
    args = parse_args()
    checkpoint = args.checkpoint.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if args.component:
        export_component(checkpoint, output / component_name(args.component, args.index),
                         args.component, args.index)
        return

    if output.exists():
        raise SystemExit(f"output already exists: {output}")
    config = json.loads((checkpoint / "config.json").read_text())
    if (config.get("model_type") != "qwen3" or config.get("hidden_size") != HIDDEN_DIM
            or config.get("num_hidden_layers") != 36
            or config.get("quantization_config", {}).get("fmt") != "e4m3"
            or config.get("quantization_config", {}).get("weight_block_size") != [128, 128]):
        raise SystemExit("checkpoint does not match the reviewed Qwen3-8B-FP8 architecture")
    weight_map = json.loads((checkpoint / "model.safetensors.index.json").read_text())["weight_map"]
    shards = sorted(set(weight_map.values()))
    if len(shards) != 2 or any(not (checkpoint / file).is_file() for file in shards):
        raise SystemExit("both Qwen3-8B-FP8 safetensors shards are required")
    if any(not (checkpoint / file).is_file() for file in TOKENIZER_FILES):
        raise SystemExit("Qwen3-8B tokenizer files are required")

    source_hashes = {file: sha256(checkpoint / file) for file in shards}
    if source_hashes != EXPECTED_SHARD_SHA256:
        raise SystemExit("Qwen3-8B-FP8 shards differ from the reviewed publisher files")
    output.mkdir(parents=True)
    components = [("embedding", 0)] + [("layer", i) for i in range(LAYER_COUNT)]
    for ordinal, (kind, index) in enumerate(components, 1):
        print(f"[{ordinal}/{len(components)}] {component_name(kind, index)}", flush=True)
        subprocess.run([sys.executable, str(Path(__file__).resolve()), str(checkpoint), str(output),
                        "--component", kind, "--index", str(index)], check=True)

    tokenizer_dir = output / "tokenizer"
    tokenizer_dir.mkdir()
    for file in TOKENIZER_FILES:
        shutil.copy2(checkpoint / file, tokenizer_dir / file)
    shutil.copy2(checkpoint / "config.json", output / "config.json")
    shutil.copy2(checkpoint / "LICENSE", output / "LICENSE")
    manifest = {
        "format_version": 1,
        "status": "experimental-split-text-encoder",
        "source_model": "Qwen/Qwen3-8B-FP8",
        "source_sha256": source_hashes,
        "license": "Apache-2.0",
        "text_tokens": TEXT_TOKENS,
        "hidden_size": HIDDEN_DIM,
        "output_layers": [9, 18, 27],
        "output_shape": [1, TEXT_TOKENS, 3 * HIDDEN_DIM],
        "preferred_compute": "gpu",
        "storage": "FP16 embedding; FP8 E4M3FN decoder layer weights",
        "components": [component_name(kind, index) for kind, index in components],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"export complete: {output}", flush=True)


if __name__ == "__main__":
    main()
