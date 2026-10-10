#!/usr/bin/env python3
"""Executable parity oracle for Z-Image's non-learned host operations.

This module is conversion/test tooling, not package payload or application
runtime code.  The shipped pipeline describes the same operations as data.
"""

from __future__ import annotations

import math

import numpy as np


LATENT_SCALING_FACTOR = 0.3611
LATENT_SHIFT_FACTOR = 0.1159
TRAINING_TIMESTEPS = 1000.0
FLOW_MATCH_SHIFT = 3.0


def patchify(latents: np.ndarray) -> tuple[np.ndarray, np.ndarray, int]:
    if latents.ndim != 4 or latents.shape[0] != 1 or latents.shape[1] != 16:
        raise ValueError("expected a 1x16xHxW latent")
    _, channels, height, width = latents.shape
    if height % 2 or width % 2:
        raise ValueError("latent height and width must be even")
    tokens = (
        latents.reshape(1, channels, height // 2, 2, width // 2, 2)
        .transpose(0, 2, 4, 3, 5, 1)
        .reshape(1, -1, 64)
    )
    count = tokens.shape[1]
    padded_count = math.ceil(count / 32) * 32
    padding_mask = np.arange(padded_count)[None, :] >= count
    if padded_count != count:
        tokens = np.concatenate(
            (tokens, np.repeat(tokens[:, -1:, :], padded_count - count, axis=1)),
            axis=1,
        )
    return np.ascontiguousarray(tokens), padding_mask, count


def unpatchify(tokens: np.ndarray, latent_height: int, latent_width: int) -> np.ndarray:
    if latent_height % 2 or latent_width % 2:
        raise ValueError("latent height and width must be even")
    count = (latent_height // 2) * (latent_width // 2)
    if tokens.ndim != 3 or tokens.shape[0] != 1 or tokens.shape[1] < count or tokens.shape[2] != 64:
        raise ValueError("token tensor does not satisfy the requested latent shape")
    return np.ascontiguousarray(
        tokens[:, :count]
        .reshape(1, latent_height // 2, latent_width // 2, 2, 2, 16)
        .transpose(0, 5, 1, 3, 2, 4)
        .reshape(1, 16, latent_height, latent_width)
    )


def encode_vae_affine(posterior_mode: np.ndarray) -> np.ndarray:
    return (posterior_mode - LATENT_SHIFT_FACTOR) * LATENT_SCALING_FACTOR


def decode_vae_affine(latents: np.ndarray) -> np.ndarray:
    return latents / LATENT_SCALING_FACTOR + LATENT_SHIFT_FACTOR


def normalized_timestep(scheduler_timestep: float) -> float:
    # The publisher scheduler and model boundary are float32. Keep both
    # arithmetic operations in that precision instead of evaluating in Python
    # double and rounding only once at the tensor constructor.
    value = (
        np.float32(TRAINING_TIMESTEPS) - np.float32(scheduler_timestep)
    ) / np.float32(TRAINING_TIMESTEPS)
    return float(value)


def flow_match_schedule(inference_steps: int) -> tuple[np.ndarray, np.ndarray]:
    if inference_steps < 2:
        raise ValueError("inference_steps must be at least two")
    base_sigmas = np.linspace(1.0, 0.0, inference_steps, dtype=np.float32)
    sigmas = FLOW_MATCH_SHIFT * base_sigmas / (
        1.0 + (FLOW_MATCH_SHIFT - 1.0) * base_sigmas
    )
    timesteps = sigmas * TRAINING_TIMESTEPS
    return timesteps.astype(np.float32), np.concatenate((sigmas, np.zeros(1, np.float32)))


def flow_match_euler_step(sample: np.ndarray, model_output: np.ndarray, sigma: float, sigma_next: float) -> np.ndarray:
    return sample.astype(np.float32) + (np.float32(sigma_next) - np.float32(sigma)) * model_output.astype(np.float32)


def meaningful_denoiser_evaluations(sigmas: np.ndarray) -> int:
    return sum(float(sigmas[index + 1] - sigmas[index]) != 0.0 for index in range(len(sigmas) - 1))
