"""Compare a Core AI VAE encoder with the original publisher implementation.

This checks numerical output on deterministic rectangular synthetic images.
It neither calculates nor verifies a package hash.
"""

import argparse
import asyncio

import numpy as np
import torch
import coreai.runtime as runtime


LATENT_SCALING = 0.3611
LATENT_SHIFT = 0.1159
SOURCE_MODEL = "Tongyi-MAI/Z-Image-Turbo"
SOURCE_REVISION = "f332072aa78be7aecdf3ee76d5c247082da564a6"


def correlation(first: torch.Tensor, second: torch.Tensor) -> float:
    first_values = first.flatten().double().numpy()
    second_values = second.flatten().double().numpy()
    return float(np.corrcoef(first_values, second_values)[0, 1])


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("encoder")
    parser.add_argument(
        "--shapes",
        nargs="+",
        default=("512x512", "1280x720", "720x1280", "2048x2048"),
        help="pixel WIDTHxHEIGHT shapes to test",
    )
    parser.add_argument(
        "--source",
        default=SOURCE_MODEL,
        help="publisher model id or a local snapshot directory",
    )
    parser.add_argument("--revision", default=SOURCE_REVISION)
    parser.add_argument("--local-files-only", action="store_true")
    args = parser.parse_args()

    from diffusers import AutoencoderKL

    vae = AutoencoderKL.from_pretrained(
        args.source,
        subfolder="vae",
        revision=args.revision if args.source == SOURCE_MODEL else None,
        local_files_only=args.local_files_only,
        torch_dtype=torch.float32,
    ).eval()

    model = await runtime.AIModel.load(
        args.encoder, runtime.SpecializationOptions.default()
    )
    function = model.load_function("main")
    for shape in args.shapes:
        try:
            width, height = (int(value) for value in shape.lower().split("x", 1))
        except ValueError as error:
            raise ValueError(f"invalid --shapes value: {shape!r}") from error
        for name, value in (("width", width), ("height", height)):
            if not 512 <= value <= 2048 or value % 16:
                raise ValueError(
                    f"{name} in {shape!r} must be a multiple of 16 from 512 through 2048"
                )

        horizontal_coordinate = torch.linspace(-1.0, 1.0, width, dtype=torch.float32)
        vertical_coordinate = torch.linspace(-1.0, 1.0, height, dtype=torch.float32)
        horizontal = horizontal_coordinate[None, None, None, :].expand(
            1, 1, height, width
        )
        vertical = vertical_coordinate[None, None, :, None].expand(
            1, 1, height, width
        )
        image = torch.cat(
            (horizontal, vertical, (horizontal + vertical) * 0.5), dim=1
        ).contiguous()

        with torch.no_grad():
            expected = (
                vae.encode(image).latent_dist.mode() - LATENT_SHIFT
            ) * LATENT_SCALING

        outputs = await function(inputs={"image": runtime.NDArray(image)})
        actual = torch.as_tensor(outputs["z"].numpy().astype(np.float32))
        expected_shape = (1, 16, height // 8, width // 8)
        if tuple(actual.shape) != expected_shape or not torch.isfinite(actual).all():
            raise RuntimeError(
                f"Core AI returned {tuple(actual.shape)} for {shape}; expected {expected_shape}"
            )

        coefficient = correlation(actual, expected)
        maximum_error = float((actual - expected).abs().max())
        mean_error = float((actual - expected).abs().mean())
        print(f"pixels={width}x{height}")
        print(f"shape={tuple(actual.shape)}")
        print(f"correlation={coefficient:.9f}")
        print(f"max_abs_error={maximum_error:.9g}")
        print(f"mean_abs_error={mean_error:.9g}")
        if coefficient < 0.9999 or maximum_error > 0.05:
            raise RuntimeError(
                f"Core AI encoder output for {shape} is outside the parity gate"
            )


if __name__ == "__main__":
    asyncio.run(main())
