#!/usr/bin/env python3
"""Export and run the experimental Klein 9B + Real HD 2K Core AI variant.

Run with ~/coreai-models/.venv/bin/python. The user-supplied DoRA weights are
fused into a separate 1024px denoiser export; the original export stays intact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path,
                        default=home / "Downloads/flux-2-klein-9b-fp8.safetensors")
    parser.add_argument("--adapter", type=Path,
                        default=home / "Downloads/HighDetail.safetensors")
    parser.add_argument("--denoiser", type=Path,
                        default=home / "coreai-models/exports/FLUX.2-klein-9B-fp8-1024-real-hd-2k")
    parser.add_argument("--encoder", type=Path,
                        default=home / "coreai-models/exports/Qwen3-8B-FP8-flux2-encoder-experimental")
    parser.add_argument("--vae", type=Path,
                        default=home / "coreai-models/exports/FLUX.2-klein-4B/VAEDecoder.aimodel")
    parser.add_argument("--batch-norm", type=Path,
                        default=home / "coreai-models/exports/FLUX.2-klein-4B")
    parser.add_argument("--output", type=Path,
                        default=home / "coreai-models/outputs/FLUX.2-klein-9B-real-hd-2k-1024.png")
    parser.add_argument("--prompt", default="A red fox in a snowy forest, detailed photograph")
    parser.add_argument("--seed", type=int, default=47)
    parser.add_argument("--adapter-strength", type=float, default=1.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    scripts = Path(__file__).resolve().parent
    denoiser = args.denoiser.expanduser().resolve()
    adapter = args.adapter.expanduser().resolve()
    if not adapter.is_file():
        raise SystemExit(f"adapter is missing: {adapter}")

    if not denoiser.exists():
        subprocess.run([
            sys.executable, str(scripts / "export-flux2-klein-9b-fp8.py"),
            str(args.checkpoint.expanduser().resolve()), str(denoiser),
            "--adapter", str(adapter),
            "--adapter-strength", str(args.adapter_strength),
        ], check=True)

    manifest_path = denoiser / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"incomplete export at {denoiser}; inspect it before retrying")
    manifest = json.loads(manifest_path.read_text())
    recorded = manifest.get("adapter") or {}
    digest = hashlib.sha256()
    with adapter.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    if (manifest.get("image_size") != 1024 or
            manifest.get("source_sha256") !=
            "865ba09f5b4c3cbd3468a4bd3acb9fcb2f8740c54317482f0bcd4ed1d3655cee" or
            recorded.get("source_file") != adapter.name or
            recorded.get("sha256") != digest.hexdigest() or
            recorded.get("strength") != args.adapter_strength):
        raise SystemExit(f"export at {denoiser} does not match this 1024px adapter variant")
    if len(manifest.get("components", [])) != 34:
        raise SystemExit(f"expected 34 components in {denoiser}")
    for name in manifest.get("components", []):
        if not (denoiser / name).is_dir():
            raise SystemExit(f"missing component {name} in {denoiser}")

    subprocess.run([
        sys.executable, str(scripts / "smoke-flux2-klein-9b-image.py"),
        "--encoder", str(args.encoder.expanduser().resolve()),
        "--denoiser", str(denoiser),
        "--vae", str(args.vae.expanduser().resolve()),
        "--batch-norm", str(args.batch_norm.expanduser().resolve()),
        "--output", str(args.output.expanduser().resolve()),
        "--prompt", args.prompt,
        "--seed", str(args.seed),
    ], check=True)


if __name__ == "__main__":
    main()
