#!/usr/bin/env python3
"""Encode one prompt through the experimental split Qwen3-8B Core AI export."""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import resource
import time
from pathlib import Path

import numpy as np
import torch
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions
from transformers import AutoTokenizer, Qwen3Config
from transformers.models.qwen3.modeling_qwen3 import Qwen3RotaryEmbedding


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("prompt", nargs="?", default="A red fox in a snowy forest")
    return parser.parse_args()


async def run(package: Path, prompt: str) -> np.ndarray:
    manifest = json.loads((package / "manifest.json").read_text())
    if (manifest.get("status") != "experimental-split-text-encoder"
            or manifest.get("output_shape") != [1, 512, 12288]
            or manifest.get("output_layers") != [9, 18, 27]):
        raise ValueError("incompatible split Qwen3-8B encoder manifest")
    for name in manifest["components"]:
        if not (package / name / "main.mlirb").is_file():
            raise FileNotFoundError(package / name)

    tokenizer = AutoTokenizer.from_pretrained(package / "tokenizer", local_files_only=True)
    messages = [{"role": "user", "content": prompt}]
    text = tokenizer.apply_chat_template(messages, tokenize=False,
                                         add_generation_prompt=True, enable_thinking=False)
    encoded = tokenizer(text, return_tensors="np", padding="max_length",
                        truncation=True, max_length=512)
    token_ids = encoded["input_ids"].astype(np.int32)
    key_padding = encoded["attention_mask"][0] == 0
    causal = np.triu(np.ones((512, 512), dtype=bool), k=1)
    attention_mask = np.where(causal | key_padding[None, :], -65504.0, 0.0)
    attention_mask = attention_mask[None, None].astype(np.float16)

    config = Qwen3Config.from_pretrained(package)
    rotary = Qwen3RotaryEmbedding(config)
    with torch.no_grad():
        hidden_dummy = torch.zeros((1, 512, 4096), dtype=torch.float16)
        position_ids = torch.arange(512, dtype=torch.long).unsqueeze(0)
        cos, sin = rotary(hidden_dummy, position_ids)
    cos_array = NDArray(cos.numpy())
    sin_array = NDArray(sin.numpy())
    mask_array = NDArray(attention_mask)
    options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())

    async def invoke(name: str, inputs: dict[str, NDArray]) -> NDArray:
        start = time.monotonic()
        model = await AIModel.load(package / name, options)
        function = model.load_function("main")
        result = await function(inputs)
        print(f"{name}: {time.monotonic() - start:.2f}s", flush=True)
        del function, model
        gc.collect()
        return result["hidden_out"]

    hidden = await invoke("Embedding.aimodel", {"input_ids": NDArray(token_ids)})
    outputs = []
    for index in range(27):
        hidden = await invoke(f"Layer{index:02d}.aimodel", {
            "hidden": hidden,
            "attention_mask": mask_array,
            "cos": cos_array,
            "sin": sin_array,
        })
        if index + 1 in (9, 18, 27):
            outputs.append(hidden.numpy().astype(np.float32))
    combined = np.concatenate(outputs, axis=-1)
    if combined.shape != (1, 512, 12288) or not np.isfinite(combined).all():
        raise RuntimeError("Qwen3-8B encoder returned invalid hidden states")
    print(f"output shape={combined.shape}, mean={combined.mean():.6f}, "
          f"std={combined.std():.6f}")
    print(f"peak process RSS={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30:.2f} GiB")
    return combined


if __name__ == "__main__":
    args = parse_args()
    asyncio.run(run(args.package.expanduser().resolve(), args.prompt))
