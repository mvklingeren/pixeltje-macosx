#!/usr/bin/env python3
"""Run one denoiser step through an experimental split Klein 9B package.

This uses random latent and text tensors to verify package wiring. It does not
produce an image or validate prompt/image quality. Run in the same Python
environment used for the export, on an M5 with macOS 27 Core AI support.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import resource
import time
from pathlib import Path

import numpy as np
from coreai.runtime import AIModel, ComputeUnitKind, NDArray, SpecializationOptions


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="directory made by export-flux2-klein-9b-fp8.py")
    return parser.parse_args()


async def run(package: Path) -> None:
    manifest = json.loads((package / "manifest.json").read_text())
    if manifest.get("status") != "experimental-denoiser-only":
        raise ValueError("expected an experimental split Klein 9B denoiser package")
    image_size = manifest.get("image_size")
    if image_size not in (512, 1024) or manifest.get("image_tokens") != (image_size // 16) ** 2:
        raise ValueError("unsupported image-token layout")
    if manifest.get("text_tokens") != 512:
        raise ValueError("unsupported text-token layout")
    image_tokens = manifest["image_tokens"]
    grid = image_size // 16
    for name in manifest["components"]:
        if not (package / name / "main.mlirb").is_file():
            raise FileNotFoundError(package / name)

    options = SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu())

    async def invoke(name: str, inputs: dict[str, NDArray]) -> dict[str, NDArray]:
        start = time.monotonic()
        model = await AIModel.load(package / name, options)
        function = model.load_function("main")
        result = await function(inputs)
        print(f"{name}: {time.monotonic() - start:.2f}s", flush=True)
        del function, model
        gc.collect()
        return result

    rng = np.random.default_rng(47)
    image = rng.standard_normal((1, image_tokens, 128), dtype=np.float32).astype(np.float16) * np.float16(0.1)
    text = rng.standard_normal((1, 512, 12288), dtype=np.float32).astype(np.float16) * np.float16(0.1)
    image_ids = np.zeros((image_tokens, 4), dtype=np.float32)
    image_ids[:, 1] = np.repeat(np.arange(grid), grid)
    image_ids[:, 2] = np.tile(np.arange(grid), grid)
    text_ids = np.zeros((512, 4), dtype=np.float32)
    text_ids[:, 3] = np.arange(512)

    head = await invoke("Head.aimodel", {
        "image": NDArray(image),
        "text": NDArray(text),
        "timestep": NDArray(np.array([0.5], dtype=np.float16)),
        "image_ids": NDArray(image_ids),
        "text_ids": NDArray(text_ids),
    })
    image_state = head["image_out"]
    text_state = head["text_out"]
    image_mod = head["image_mod"]
    text_mod = head["text_mod"]
    single_mod = head["single_mod"]
    temb = head["temb"]
    cos = head["cos"]
    sin = head["sin"]
    del head

    for kind, count in (("Double", 8), ("Single", 24)):
        for index in range(count):
            modulation = image_mod if kind == "Double" else single_mod
            result = await invoke(f"{kind}Block{index:02d}.aimodel", {
                "image": image_state,
                "text": text_state,
                "image_mod": modulation,
                "text_mod": text_mod if kind == "Double" else single_mod,
                "cos": cos,
                "sin": sin,
            })
            image_state = result["image_out"]
            text_state = result["text_out"]
            del result

    result = await invoke("Tail.aimodel", {"image": image_state, "temb": temb})
    output = result["output"].numpy()
    if output.shape != (1, image_tokens, 128) or not np.isfinite(output).all():
        raise RuntimeError("denoiser returned unexpected shape or non-finite values")
    output32 = output.astype(np.float32)
    print(f"output shape={output.shape}, mean={float(output32.mean()):.6f}, std={float(output32.std()):.6f}")
    print(f"peak process RSS={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30:.2f} GiB")


if __name__ == "__main__":
    asyncio.run(run(parse_args().package.expanduser().resolve()))
