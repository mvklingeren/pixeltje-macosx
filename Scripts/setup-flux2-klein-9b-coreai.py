#!/usr/bin/env python3
"""Download publisher checkpoints and build Pixeltje's FLUX.2 Klein 9B Core AI package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


APPLE_REVISION = "3f109efd54273391f9fd9f5f5b3d8c6e99836d55"
QWEN_REVISION = "220b46e3b2180893580a4454f21f22d3ebb187d3"
VAE_REVISION = "e7b7dc27f91deacad38e78976d1f2b499d76a294"
BASE_NAME = "FLUX.2-klein-9B-fp8-1024"
ADAPTED_NAME = "FLUX.2-klein-9B-fp8-1024-real-hd-2k"
EXPECTED_ADAPTER_SHA256 = "108c649190f0953852feb15dad3d8ef8821753814a386ae46006d6949f722616"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path | None = None,
        env: dict[str, str] | None = None, dry_run: bool = False) -> None:
    print("+ " + shlex.join(command), flush=True)
    if not dry_run:
        subprocess.run(command, cwd=cwd, env=env, check=True)


def require_tool(name: str) -> str:
    executable = shutil.which(name)
    if executable is None:
        raise RuntimeError(f"{name} is required. See the bundled Model-Setup-Guide.html")
    return executable


def ready_export(root: Path, component: str, *, manifest: bool = False) -> bool:
    return ((root / component / "main.mlirb").is_file()
            and (not manifest or (root / "manifest.json").is_file()))


def ready_package(root: Path, adapted: bool) -> bool:
    try:
        manifest = json.loads((root / "manifest.json").read_text())
        encoder = json.loads((root / "TextEncoder" / "manifest.json").read_text())
        adapter = manifest.get("adapter")
        denoiser_components = manifest.get("components", [])
        encoder_components = encoder.get("components", [])
        return (manifest.get("source_model") == "black-forest-labs/FLUX.2-klein-9b-fp8"
                and manifest.get("image_size") == 1024
                and len(denoiser_components) == 34
                and len(encoder_components) == 28
                and all(ready_export(root, name) for name in denoiser_components)
                and all(ready_export(root / "TextEncoder", name)
                        for name in encoder_components)
                and ready_export(root, "VAEDecoder.aimodel")
                and not any(path.is_symlink() for path in root.rglob("*"))
                and ((adapter or {}).get("sha256") == EXPECTED_ADAPTER_SHA256
                     if adapted else adapter is None))
    except (OSError, ValueError, AttributeError, TypeError):
        return False


def checkout_apple(workspace: Path, git: str, uv: str, dry_run: bool) -> Path:
    root = workspace / "coreai-models"
    if not (root / ".git").is_dir():
        if root.exists():
            raise RuntimeError(f"expected an empty checkout path: {root}")
        run([git, "clone", "https://github.com/apple/coreai-models.git", str(root)], dry_run=dry_run)
        run([git, "-C", str(root), "checkout", "--detach", APPLE_REVISION], dry_run=dry_run)
    if not dry_run:
        head = subprocess.check_output([git, "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        if head != APPLE_REVISION:
            raise RuntimeError(f"{root} is at {head}; expected {APPLE_REVISION}")
    run([uv, "sync", "--frozen", "--no-default-groups"], cwd=root, dry_run=dry_run)
    return root


def download_sources(workspace: Path, hf: str, dry_run: bool) -> tuple[Path, Path, Path]:
    checkpoints = workspace / "checkpoints"
    denoiser = checkpoints / "FLUX.2-klein-9b-fp8"
    encoder = checkpoints / "Qwen3-8B-FP8"
    vae = checkpoints / "FLUX.2-klein-4B-VAE"
    # The 9B repository is gated. Hugging Face authenticates the user's own
    # account and enforces their acceptance of the publisher's terms.
    run([hf, "download", "black-forest-labs/FLUX.2-klein-9b-fp8",
         "flux-2-klein-9b-fp8.safetensors", "LICENSE.md", "--local-dir", str(denoiser)],
        dry_run=dry_run)
    run([hf, "download", "Qwen/Qwen3-8B-FP8", "--revision", QWEN_REVISION,
         "config.json", "model.safetensors.index.json",
         "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
         "tokenizer.json", "tokenizer_config.json", "merges.txt", "vocab.json", "LICENSE",
         "--local-dir", str(encoder)], dry_run=dry_run)
    run([hf, "download", "black-forest-labs/FLUX.2-klein-4B", "--revision", VAE_REVISION,
         "vae/config.json", "vae/diffusion_pytorch_model.safetensors", "LICENSE.md",
         "--local-dir", str(vae)], dry_run=dry_run)
    return denoiser, encoder, vae


def export_if_needed(command: list[str], root: Path, component: str,
                     *, manifest: bool, env: dict[str, str], dry_run: bool) -> None:
    if ready_export(root, component, manifest=manifest):
        print(f"Using existing export: {root}", flush=True)
    elif root.exists():
        raise RuntimeError(f"incomplete export at {root}; move it aside before retrying")
    else:
        run(command, env=env, dry_run=dry_run)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path.home() / "Pixeltje Model Build",
                        help="scratch area for publisher weights, tools, and intermediate exports")
    parser.add_argument("--model-library", type=Path,
                        default=Path.home() / ".pixeltje" / "models",
                        help="destination for self-contained model packages")
    parser.add_argument("--variant", choices=("base", "real-hd-2k", "both"), default="base")
    parser.add_argument("--adapter", type=Path,
                        help="your downloaded Real HD 2K HighDetail.safetensors")
    parser.add_argument("--dry-run", action="store_true", help="print commands without running them")
    args = parser.parse_args()
    workspace = args.workspace.expanduser().resolve()
    library = args.model_library.expanduser().resolve()
    adapter = args.adapter.expanduser().resolve() if args.adapter else None
    if args.variant != "base" and adapter is None:
        parser.error("--adapter is required for the Real HD 2K variant")
    if adapter is not None and not args.dry_run and not adapter.is_file():
        parser.error(f"adapter does not exist: {adapter}")
    if args.variant != "base" and not args.dry_run and sha256(adapter) != EXPECTED_ADAPTER_SHA256:
        parser.error("adapter differs from the reviewed Real HD 2K HighDetail.safetensors; "
                     "this example requires the exact version named in the guide")
    if not args.dry_run and platform.machine() != "arm64":
        parser.error("Core AI export requires an Apple Silicon Mac")
    scripts = Path(__file__).resolve().parent
    if not args.dry_run:
        workspace.mkdir(parents=True, exist_ok=True)
        library.mkdir(parents=True, exist_ok=True)
    requested = (["base", "real-hd-2k"] if args.variant == "both" else [args.variant])
    pending = []
    for variant in requested:
        name = BASE_NAME if variant == "base" else ADAPTED_NAME
        destination = library / name
        if destination.exists():
            if not ready_package(destination, adapted=variant == "real-hd-2k"):
                raise RuntimeError(f"existing package is incomplete or incompatible: {destination}")
            print(f"Package already exists; select it in Pixeltje Pipeline: {destination}")
        else:
            pending.append((variant, name, destination))
    if not pending:
        return
    git, uv, hf = (require_tool(name) for name in ("git", "uv", "hf"))
    denoiser_source, encoder_source, vae_source = download_sources(workspace, hf, args.dry_run)
    apple = checkout_apple(workspace, git, uv, args.dry_run)
    python = str(apple / ".venv" / "bin" / "python")
    env = os.environ.copy()
    env["PYTHONPATH"] = str(apple / "python" / "src") + os.pathsep + env.get("PYTHONPATH", "")
    env["PIXELTJE_COREAI_COMPUTE"] = "gpu-preferred"
    exports = workspace / "exports"
    vae_export = exports / "FLUX.2-klein-VAE-1024"
    encoder_export = exports / "Qwen3-8B-FP8-flux2-encoder"
    export_if_needed([python, str(scripts / "export-flux2-klein-vae.py"),
                      str(vae_source), str(vae_export)], vae_export, "VAEDecoder.aimodel",
                     manifest=False, env=env, dry_run=args.dry_run)
    export_if_needed([python, str(scripts / "export-flux2-klein-9b-qwen3-fp8.py"),
                      str(encoder_source), str(encoder_export)], encoder_export,
                     "Layer26.aimodel", manifest=True, env=env, dry_run=args.dry_run)
    for variant, name, destination in pending:
        denoiser_export = exports / name
        command = [python, str(scripts / "export-flux2-klein-9b-fp8.py"),
                   str(denoiser_source / "flux-2-klein-9b-fp8.safetensors"),
                   str(denoiser_export)]
        if variant == "real-hd-2k":
            command += ["--adapter", str(adapter)]
        export_if_needed(command, denoiser_export, "Tail.aimodel", manifest=True,
                         env=env, dry_run=args.dry_run)
        run([sys.executable, str(scripts / "assemble-flux2-klein-9b-package.py"),
             str(denoiser_export), "--encoder", str(encoder_export),
             "--vae-root", str(vae_export), "--denoiser-license",
             str(denoiser_source / "LICENSE.md"), "--vae-license",
             str(vae_source / "LICENSE.md"), "--output", str(destination)],
            dry_run=args.dry_run)
    print("Open the matching bundled example and select its Model Package directory.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Model setup failed: {error}") from error
