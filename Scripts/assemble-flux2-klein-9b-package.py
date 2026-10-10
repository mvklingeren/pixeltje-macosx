#!/usr/bin/env python3
"""Assemble split Klein 9B exports into one Pipeline Editor package directory.

Pass --output for a self-contained, movable package. Without --output, the
legacy developer mode adds symlinks to the denoiser export.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import uuid
from pathlib import Path


def link(root: Path, name: str, target: Path) -> None:
    destination = root / name
    target = target.expanduser().resolve(strict=True)
    if destination.is_symlink():
        if destination.resolve() == target:
            print(f"ready: {destination} -> {target}")
            return
        raise RuntimeError(f"{destination} already points to another target")
    if destination.exists():
        raise RuntimeError(f"{destination} already exists; refusing to replace it")
    destination.symlink_to(target, target_is_directory=target.is_dir())
    print(f"linked: {destination} -> {target}")


def clone_or_copy(source: str, destination: str) -> str:
    """Use APFS clones when possible; fall back to an independent file copy."""
    result = subprocess.run(("/bin/cp", "-c", source, destination),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        shutil.copy2(source, destination)
    else:
        shutil.copystat(source, destination)
    return destination


def require_asset(root: Path, name: str) -> None:
    package = root / name
    if (not (package / "main.mlirb").is_file()
            or not (package / "main.hash").is_file()):
        raise RuntimeError(f"missing Core AI asset {package}")


def copy_package(denoiser: Path, encoder: Path, vae_root: Path,
                 output: Path, license_file: Path | None,
                 vae_license: Path | None) -> None:
    if output.exists() or output.is_symlink():
        raise RuntimeError(f"output already exists: {output}")
    if output == denoiser or denoiser in output.parents:
        raise RuntimeError("output must be outside the denoiser export")
    denoiser_manifest = json.loads((denoiser / "manifest.json").read_text())
    encoder_manifest = json.loads((encoder / "manifest.json").read_text())
    denoiser_components = denoiser_manifest["components"]
    encoder_components = encoder_manifest["components"]
    if len(denoiser_components) != 34 or len(encoder_components) != 28:
        raise RuntimeError("expected 34 denoiser and 28 encoder components")
    for name in denoiser_components:
        require_asset(denoiser, name)
    for name in encoder_components:
        require_asset(encoder, name)
    for name in ("tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "LICENSE"):
        if not (encoder / name).is_file():
            raise RuntimeError(f"encoder is missing {name}")
    if license_file is not None and not license_file.is_file():
        raise RuntimeError(f"missing publisher license: {license_file}")
    if vae_license is not None and not vae_license.is_file():
        raise RuntimeError(f"missing VAE publisher license: {vae_license}")

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    try:
        staging.mkdir()
        package_manifest = dict(denoiser_manifest)
        package_manifest.pop("missing_for_image_generation", None)
        package_manifest["assembly_status"] = "self-contained"
        (staging / "manifest.json").write_text(json.dumps(package_manifest, indent=2) + "\n")
        for name in denoiser_components:
            shutil.copytree(denoiser / name, staging / name, copy_function=clone_or_copy)
        text_encoder = staging / "TextEncoder"
        text_encoder.mkdir()
        for name in ("manifest.json", "config.json", "LICENSE"):
            clone_or_copy(str(encoder / name), str(text_encoder / name))
        shutil.copytree(encoder / "tokenizer", text_encoder / "tokenizer",
                        copy_function=clone_or_copy)
        for name in encoder_components:
            shutil.copytree(encoder / name, text_encoder / name,
                            copy_function=clone_or_copy)
        for name in ("VAEDecoder.aimodel", "vae_bn_mean.npy", "vae_bn_var.npy"):
            source = vae_root / name
            destination = staging / name
            if source.is_dir():
                shutil.copytree(source, destination, copy_function=clone_or_copy)
            else:
                clone_or_copy(str(source), str(destination))
        if license_file is not None:
            clone_or_copy(str(license_file), str(staging / "LICENSE.md"))
        if vae_license is not None:
            clone_or_copy(str(vae_license), str(staging / "VAE-LICENSE.md"))
        # All links must remain within the selected model directory.
        if any(path.is_symlink() for path in staging.rglob("*")):
            raise RuntimeError("assembled package contains a symbolic link")
        staging.rename(output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f"Select this Model Package directory in Pixeltje Pipeline: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("denoiser", type=Path)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--vae-root", type=Path, required=True)
    parser.add_argument("--output", type=Path,
                        help="new self-contained package directory (recommended for users)")
    parser.add_argument("--denoiser-license", type=Path,
                        help="publisher's FLUX 9B LICENSE.md to include with --output")
    parser.add_argument("--vae-license", type=Path,
                        help="publisher's 4B VAE LICENSE.md to include with --output")
    args = parser.parse_args()

    denoiser = args.denoiser.expanduser().resolve(strict=True)
    encoder = args.encoder.expanduser().resolve(strict=True)
    vae_root = args.vae_root.expanduser().resolve(strict=True)
    if not (denoiser / "Head.aimodel" / "main.mlirb").is_file():
        raise RuntimeError("denoiser is missing Head.aimodel")
    if not (encoder / "Embedding.aimodel" / "main.mlirb").is_file():
        raise RuntimeError("encoder is missing Embedding.aimodel")
    for name in ("VAEDecoder.aimodel", "vae_bn_mean.npy", "vae_bn_var.npy"):
        if not (vae_root / name).exists():
            raise RuntimeError(f"VAE is missing {name}")

    if args.output:
        copy_package(denoiser, encoder, vae_root, args.output.expanduser().resolve(),
                     args.denoiser_license.expanduser().resolve(strict=True)
                     if args.denoiser_license else None,
                     args.vae_license.expanduser().resolve(strict=True)
                     if args.vae_license else None)
    else:
        link(denoiser, "TextEncoder", encoder)
        for name in ("VAEDecoder.aimodel", "vae_bn_mean.npy", "vae_bn_var.npy"):
            link(denoiser, name, vae_root / name)
        print(f"Select this Model Package directory in Pixeltje Pipeline: {denoiser}")


if __name__ == "__main__":
    main()
