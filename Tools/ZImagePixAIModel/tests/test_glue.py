from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from glue import (  # noqa: E402
    decode_vae_affine,
    encode_vae_affine,
    flow_match_euler_step,
    flow_match_schedule,
    meaningful_denoiser_evaluations,
    normalized_timestep,
    patchify,
    unpatchify,
)
from export_components import make_rope  # noqa: E402


class GlueTests(unittest.TestCase):
    def test_patchify_round_trip_across_required_shapes(self) -> None:
        rng = np.random.default_rng(19)
        for width, height in ((512, 512), (1280, 720), (720, 1280), (2048, 1152), (1152, 2048), (2048, 2048)):
            latent = rng.standard_normal((1, 16, height // 8, width // 8), dtype=np.float32)
            tokens, mask, count = patchify(latent)
            self.assertEqual(count, (width // 16) * (height // 16))
            self.assertEqual(tokens.shape[1] % 32, 0)
            self.assertEqual(int((~mask).sum()), count)
            np.testing.assert_array_equal(unpatchify(tokens, height // 8, width // 8), latent)

    def test_vae_affines_are_inverse(self) -> None:
        values = np.linspace(-4, 4, 4096, dtype=np.float32)
        np.testing.assert_allclose(decode_vae_affine(encode_vae_affine(values)), values, rtol=1e-6, atol=1e-6)

    def test_timestep_convention(self) -> None:
        self.assertEqual(normalized_timestep(1000), 0.0)
        self.assertEqual(normalized_timestep(500), 0.5)
        self.assertEqual(normalized_timestep(0), 1.0)

    def test_fixed_shift_schedule_matches_publisher_contract(self) -> None:
        timesteps, sigmas = flow_match_schedule(9)
        np.testing.assert_allclose(
            timesteps,
            np.array([1000, 954.5454, 900, 833.3333, 750, 642.8571, 500, 300, 0], np.float32),
            rtol=2e-6,
        )
        self.assertEqual(meaningful_denoiser_evaluations(sigmas), 8)
        sample = np.array([1.0, -2.0], np.float32)
        model = np.array([0.25, 0.5], np.float32)
        np.testing.assert_array_equal(flow_match_euler_step(sample, model, 0.5, 0.25), np.array([0.9375, -2.125], np.float32))

    def test_dynamic_prompt_buckets_have_bucket_sized_publisher_coordinates(self) -> None:
        for bucket in (32, 256, 512):
            valid = bucket - 7
            image_padding, prompt_padding, prompt_active, cosine, sine = make_rope(
                32, 32, valid, bucket, maximum_prompt_tokens=bucket,
            )
            self.assertEqual(tuple(prompt_padding.shape), (bucket,))
            self.assertEqual(tuple(prompt_active.shape), (bucket,))
            self.assertEqual(int((~prompt_padding).sum()), valid)
            self.assertEqual(int(prompt_active.sum()), bucket)
            self.assertEqual(tuple(cosine.shape), (1024 + bucket, 64))
            self.assertEqual(tuple(sine.shape), (1024 + bucket, 64))
            self.assertEqual(int(image_padding.sum()), 0)

            prompt_positions = torch.zeros(bucket, 3, dtype=torch.int64)
            prompt_positions[:, 0] = torch.arange(1, bucket + 1)
            rows, columns = torch.meshgrid(
                torch.arange(32, dtype=torch.int64),
                torch.arange(32, dtype=torch.int64),
                indexing="ij",
            )
            image_positions = torch.stack(
                (torch.full_like(rows, bucket + 1), rows, columns), dim=-1
            ).reshape(-1, 3)
            positions = torch.cat((image_positions, prompt_positions), dim=0)
            frequencies = []
            for axis, dimension in enumerate((32, 48, 48)):
                inverse = 1.0 / (
                    256.0
                    ** (
                        torch.arange(0, dimension, 2, dtype=torch.float64)
                        / dimension
                    )
                )
                frequencies.append(
                    positions[:, axis : axis + 1].double()
                    * inverse.unsqueeze(0)
                )
            angles = torch.cat(frequencies, dim=1).float()
            publisher = torch.polar(torch.ones_like(angles), angles).to(
                torch.complex64
            )
            torch.testing.assert_close(
                cosine, publisher.real, rtol=0.0, atol=0.0
            )
            torch.testing.assert_close(
                sine, publisher.imag, rtol=0.0, atol=0.0
            )


if __name__ == "__main__":
    unittest.main()
