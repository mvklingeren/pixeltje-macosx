#!/usr/bin/env python3
"""Offline Core AI export from the publisher's Stable Audio 3 Small SFX weights.

Run with a Python environment containing torch, transformers, safetensors,
coreai-torch, coreai-models, and the publisher's stable_audio_3 source on
PYTHONPATH. The output is user-owned and never bundled with Pixeltje.
"""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import torch
from coreai_models.diffusion.gpu import export_stateless
from safetensors import safe_open
from stable_audio_3.loading_utils import load_autoencoder
from stable_audio_3.models.conditioners import NumberConditioner
from stable_audio_3.models.diffusion import DiTWrapper
from transformers import AutoConfig, T5GemmaEncoderModel


SOURCE_REVISION = "05ca3857881c94a2b84026b1111c537d78f5f9f0"
MAIN_SHA256 = "ed9cf1b6172f1a8c2921a9560c21109ff3239524563ced9dce6dcdef41e2f515"
TEXT_SHA256 = "9b05ea5a4f211d023832f706fb2c0e83e4fc721b6da35ab69ceb0b55eb7800d3"


class TextEncoder(torch.nn.Module):
    def __init__(self, encoder, padding_embedding):
        super().__init__()
        self.encoder = encoder
        self.padding_embedding = torch.nn.Parameter(padding_embedding, requires_grad=False)

    def forward(self, input_ids, attention_mask):
        hidden = self.encoder(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        return torch.where(attention_mask.unsqueeze(-1).bool(), hidden,
                           self.padding_embedding.view(1, 1, 768))


class DurationEncoder(torch.nn.Module):
    def __init__(self, conditioner):
        super().__init__()
        self.conditioner = conditioner

    def forward(self, seconds):
        return self.conditioner.embedder(seconds.clamp(0, 384) / 384).unsqueeze(1)


class Denoiser(torch.nn.Module):
    def __init__(self, dit):
        super().__init__()
        self.dit = dit

    def forward(self, latents, sigma, conditioning, global_conditioning):
        local_add = torch.zeros((latents.shape[0], 257, latents.shape[-1]), dtype=latents.dtype)
        return self.dit(latents, sigma, cross_attn_cond=conditioning,
                        global_cond=global_conditioning, local_add_cond=local_add)


class AudioDecoder(torch.nn.Module):
    def __init__(self, autoencoder):
        super().__init__()
        self.autoencoder = autoencoder

    def forward(self, latents):
        return self.autoencoder.decode(latents)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export(module, inputs, input_names, output_name, target):
    module.eval().requires_grad_(False)
    with torch.no_grad():
        output = module(*inputs)
    print(target.name, "output", tuple(output.shape), flush=True)
    program = export_stateless(module, inputs, input_names, (output_name,))
    program.save_asset(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.checkpoint.resolve()
    output = args.output.resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    if sha256(source / "model.safetensors") != MAIN_SHA256:
        parser.error("main checkpoint differs from reviewed publisher revision")
    encoder_root = source / "t5gemma-b-b-ul2"
    if sha256(encoder_root / "model.safetensors") != TEXT_SHA256:
        parser.error("T5Gemma checkpoint differs from reviewed publisher revision")
    config = json.loads((source / "model_config.json").read_text())
    if config["sample_rate"] != 44100 or config["model"]["diffusion"]["diffusion_objective"] != "rf_denoiser":
        parser.error("model configuration is incompatible")
    output.mkdir(parents=True)

    text_config = AutoConfig.from_pretrained(encoder_root, local_files_only=True)
    text_config.is_encoder_decoder = False
    encoder = T5GemmaEncoderModel.from_pretrained(
        encoder_root, config=text_config, local_files_only=True)
    with safe_open(source / "model.safetensors", framework="pt", device="cpu") as weights:
        padding = weights.get_tensor("conditioner.conditioners.prompt.padding_embedding")
    export(TextEncoder(encoder, padding),
           (torch.zeros((1, 256), dtype=torch.int32),
            torch.ones((1, 256), dtype=torch.int32)),
           ("inputIDs", "attentionMask"), "embeddings", output / "TextEncoder.aimodel")
    del encoder

    number_config = config["model"]["conditioning"]["configs"][1]["config"]
    conditioner = NumberConditioner(output_dim=768, **number_config)
    prefix = "conditioner.conditioners.seconds_total."
    with safe_open(source / "model.safetensors", framework="pt", device="cpu") as weights:
        state = {name.removeprefix(prefix): weights.get_tensor(name)
                 for name in weights.keys() if name.startswith(prefix)}
    conditioner.load_state_dict(state, strict=True)
    export(DurationEncoder(conditioner), (torch.tensor([2.0], dtype=torch.float32),),
           ("seconds",), "embedding", output / "DurationEncoder.aimodel")
    del conditioner

    diffusion = config["model"]["diffusion"]
    dit = DiTWrapper(diffusion_objective=diffusion["diffusion_objective"],
                     **diffusion["config"])
    with safe_open(source / "model.safetensors", framework="pt", device="cpu") as weights:
        state = {name.removeprefix("model."): weights.get_tensor(name)
                 for name in weights.keys() if name.startswith("model.model.")}
    dit.load_state_dict(state, strict=True)
    export(Denoiser(dit),
           (torch.zeros((1, 256, 88), dtype=torch.float32),
            torch.tensor([0.5], dtype=torch.float32),
            torch.zeros((1, 257, 768), dtype=torch.float32),
            torch.zeros((1, 768), dtype=torch.float32)),
           ("latents", "sigma", "conditioning", "globalConditioning"),
           "velocity", output / "Denoiser.aimodel")
    del dit

    autoencoder = load_autoencoder(str(source / "model_config.json"),
                                   str(source / "model.safetensors"), device="cpu")
    # The publisher enables tiny stochastic decoder noise. Core AI export needs
    # a deterministic function; diffusion itself remains seeded in Swift.
    autoencoder.bottleneck.noise_regularize = False
    for module in autoencoder.modules():
        if hasattr(module, "mask_noise"):
            module.mask_noise = 0.0
    export(AudioDecoder(autoencoder),
           (torch.zeros((1, 256, 88), dtype=torch.float32),),
           ("latents",), "audio", output / "AudioDecoder.aimodel")
    del autoencoder

    tokenizer = output / "tokenizer"
    tokenizer.mkdir()
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        shutil.copy2(encoder_root / name, tokenizer / name)
    metadata = {
        "format": "pixeltje-stable-audio-3-small-sfx-coreai@1",
        "source": {
            "hf_model_id": "stabilityai/stable-audio-3-small-sfx",
            "revision": SOURCE_REVISION,
            "weights_sha256": MAIN_SHA256,
            "text_weights_sha256": TEXT_SHA256,
        },
        "sample_rate": 44100, "channels": 2, "latent_frames": 88,
        "latent_channels": 256, "duration_seconds": 2,
        "padding_seconds": 6, "token_length": 256,
        "assets": {
            "textEncoder": "TextEncoder.aimodel",
            "durationEncoder": "DurationEncoder.aimodel",
            "denoiser": "Denoiser.aimodel",
            "audioDecoder": "AudioDecoder.aimodel",
            "tokenizer": "tokenizer",
        },
        "decoder_noise": "disabled for deterministic Core AI export",
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Exported", output, flush=True)


if __name__ == "__main__":
    main()
