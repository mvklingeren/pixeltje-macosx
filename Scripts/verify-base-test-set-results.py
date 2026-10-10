#!/usr/bin/env python3
"""Check the rendered Base Test Set outputs against independent oracles."""

from __future__ import annotations

import json
import math
import struct
import subprocess
import sys
import wave
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def command(*args: str) -> bytes:
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def png(path: Path) -> tuple[int, int, bytes]:
    with path.open("rb") as source:
        header = source.read(24)
    require(header[:8] == b"\x89PNG\r\n\x1a\n", f"Not a PNG: {path}")
    width, height = struct.unpack(">II", header[16:24])
    pixels = command("ffmpeg", "-v", "error", "-i", str(path),
                     "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1")
    require(len(pixels) == width * height * 4, f"Invalid PNG pixels: {path}")
    return width, height, pixels


def pixel(pixels: bytes, width: int, x: int, y: int) -> bytes:
    offset = (y * width + x) * 4
    return pixels[offset:offset + 4]


def verify_text(output: Path) -> None:
    actual = (output / "01-text-cleanup.txt").read_text()
    require(actual == "Pipeline Test Card | ready", f"Wrong text: {actual!r}")
    print("01 text: exact expected phrase")


def verify_resize(source: bytes, output: Path) -> None:
    width, height, pixels = png(output / "02-computed-image-resize.png")
    require((width, height) == (224, 160), "Resize dimensions differ")
    for y in range(height):
        for x in range(width):
            expected = pixel(source, 512, (x + 16) * 2, (y + 16) * 2)
            require(pixel(pixels, width, x, y) == expected,
                    f"Wrong resized pixel at ({x}, {y})")
    print("02 resize: 224 × 160 and every pixel matches half-scale crop")


def verify_masked(source: bytes, output: Path) -> None:
    width, height, pixels = png(output / "03-masked-image-edit.png")
    require((width, height) == (512, 384), "Masked edit dimensions differ")
    for x, y in [(0, 0), (40, 40), (511, 383), (400, 200)]:
        require(pixel(pixels, width, x, y) == pixel(source, width, x, y),
                f"Outside-mask pixel changed at ({x}, {y})")
    for x, y in [(200, 120), (250, 180), (300, 200)]:
        original = pixel(source, width, x, y)
        expected = bytes([255 - original[c] for c in range(3)] + [255])
        require(pixel(pixels, width, x, y) == expected,
                f"Inside-mask pixel was not inverted at ({x}, {y})")
    edge = pixel(pixels, width, 164, 104)
    original = pixel(source, width, 164, 104)
    inverted = bytes([255 - original[c] for c in range(3)] + [255])
    require(edge != original and edge != inverted, "Mask edge was not blended")
    print("03 masked edit: dimensions, unchanged outside, inverted inside, feathered edge")


def verify_expansion(source: bytes, output: Path) -> None:
    width, height, pixels = png(output / "04-canvas-expansion-preview.png")
    preview_width, preview_height, preview = png(
        output / "04-canvas-expansion-preview-preview-1.png")
    require((width, height) == (640, 448), "Expansion dimensions differ")
    require((preview_width, preview_height) == (640, 448),
            "Mask preview dimensions differ")
    for x, y in [(0, 0), (24, 100), (620, 200), (100, 430)]:
        require(pixel(pixels, width, x, y) == b"\xff\xff\xff\xff",
                f"Border guide is not white at ({x}, {y})")
        require(pixel(preview, width, x, y) == b"\xff\xff\xff\xff",
                f"Preview border is not white at ({x}, {y})")
    for x, y in [(100, 100), (200, 200), (500, 300)]:
        require(pixel(pixels, width, x, y) == pixel(source, 512, x - 48, y - 24),
                f"Source placement is wrong at ({x}, {y})")
        require(pixel(preview, width, x, y) == b"\x00\x00\x00\xff",
                f"Preview interior is not black at ({x}, {y})")
    print("04 expansion: 640 × 448, source placement, border, and mask preview")


def probe(path: Path) -> dict:
    return json.loads(command(
        "ffprobe", "-v", "error", "-show_entries",
        "format=duration:stream=codec_name,codec_type,width,height,r_frame_rate,nb_frames",
        "-of", "json", str(path)))


def raw_video(path: Path) -> bytes:
    return command("ffmpeg", "-v", "error", "-i", str(path),
                   "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "rgb24",
                   "pipe:1")


def spectral_amplitude(samples: tuple[int, ...], frequency: int,
                       sample_rate: int = 16000) -> float:
    cosine = sum(value * math.cos(2 * math.pi * frequency * i / sample_rate)
                 for i, value in enumerate(samples))
    sine = sum(value * math.sin(2 * math.pi * frequency * i / sample_rate)
               for i, value in enumerate(samples))
    return math.hypot(cosine, sine)


def verify_video(source: Path, output: Path) -> None:
    result = output / "05-video-resize-with-audio.mp4"
    info = probe(result)
    video = next(item for item in info["streams"] if item["codec_type"] == "video")
    audio = next(item for item in info["streams"] if item["codec_type"] == "audio")
    require(video["codec_name"] == "h264", "Video codec differs")
    require((video["width"], video["height"]) == (160, 90),
            "Video dimensions differ")
    require(video["r_frame_rate"] == "12/1" and int(video["nb_frames"]) == 24,
            "Video frame rate or count differs")
    require(audio["codec_name"] == "aac", "AAC audio is missing")
    require(abs(float(info["format"]["duration"]) - 2) < 0.02,
            "Video duration differs")

    source_frames = raw_video(source)
    output_frames = raw_video(result)
    require(len(source_frames) == 24 * 320 * 180 * 3, "Source frame count differs")
    require(len(output_frames) == 24 * 160 * 90 * 3, "Decoded output frame count differs")
    for frame in (0, 12, 23):
        source_frame = source_frames[frame * 320 * 180 * 3:(frame + 1) * 320 * 180 * 3]
        output_frame = output_frames[frame * 160 * 90 * 3:(frame + 1) * 160 * 90 * 3]
        error = 0
        for y in range(90):
            for x in range(160):
                src = (y * 2 * 320 + x * 2) * 3
                dst = (y * 160 + x) * 3
                error += sum(abs(source_frame[src + c] - output_frame[dst + c])
                             for c in range(3))
        require(error / (160 * 90 * 3) < 10,
                f"Frame {frame} does not match scaled source")
    require(output_frames[:160 * 90 * 3] != output_frames[12 * 160 * 90 * 3:
                                                       13 * 160 * 90 * 3],
            "Video motion was lost")

    pcm = command("ffmpeg", "-v", "error", "-i", str(result),
                  "-map", "0:a:0", "-f", "s16le", "-ac", "1", "-ar", "16000",
                  "pipe:1")
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    require(len(samples) >= 30000, "Audio duration is too short")
    first = samples[4000:12000]
    second = samples[20000:28000]
    require(spectral_amplitude(first, 440) > 20 * spectral_amplitude(first, 880),
            "First audio second does not contain 440 Hz tone")
    require(spectral_amplitude(second, 880) > 20 * spectral_amplitude(second, 440),
            "Second audio second does not contain 880 Hz tone")
    print("05 video: codec, geometry, 24 scaled frames, 2 seconds, AAC, and both tones")


def verify_decision(output: Path) -> None:
    default = (output / "06-json-status-decision.txt").read_text()
    override = (output / "06-json-status-decision-override.txt").read_text()
    require(default == "Dispatch approved", f"Wrong ready branch: {default!r}")
    require(override == "Dispatch paused", f"Wrong blocked branch: {override!r}")
    print("06 JSON decision: default and exposed override take exact opposite branches")


def verify_red_mask(source: bytes, output: Path) -> None:
    width, height, pixels = png(output / "07-red-channel-mask.png")
    require((width, height) == (231, 157), "Red mask crop dimensions differ")
    for y in range(height):
        for x in range(width):
            red = pixel(source, 512, x + 73, y + 54)[0]
            gray = 0 if red / 255 > 0.52 else 255
            require(pixel(pixels, width, x, y) == bytes((gray, gray, gray, 255)),
                    f"Wrong red mask pixel at ({x}, {y})")
    print("07 red mask: all 36,267 grayscale pixels match crop, threshold, inversion")


def verify_blends(source: bytes, output: Path) -> None:
    width, height, final = png(output / "08-two-factor-blend.png")
    preview_width, preview_height, preview = png(
        output / "08-two-factor-blend-preview-1.png")
    require((width, height) == (512, 384), "Final blend dimensions differ")
    require((preview_width, preview_height) == (512, 384),
            "Preview blend dimensions differ")
    for offset in range(0, len(source), 4):
        for channel in range(3):
            a = source[offset + channel]
            b = 255 - a
            preview_expected = math.floor(a * 0.75 + b * 0.25 + 0.5)
            final_expected = math.floor(preview_expected * 0.25
                                        + (preview_expected * b / 255) * 0.75 + 0.5)
            require(preview[offset + channel] == preview_expected,
                    f"Wrong preview blend at byte {offset + channel}")
            require(final[offset + channel] == final_expected,
                    f"Wrong final blend at byte {offset + channel}")
        require(preview[offset + 3] == final[offset + 3] == 255,
                f"Wrong blend alpha at byte {offset + 3}")
    print("08 blends: every preview and final pixel matches normal and multiply formulas")


def verify_batch(source: bytes, output: Path) -> None:
    for index, name, origin, invert in (
        (0, "09-two-crop-batch.png", (32, 40), False),
        (1, "09-two-crop-batch-override.png", (336, 208), True),
    ):
        width, height, pixels = png(output / name)
        require((width, height) == (128, 128), f"Batch {index} dimensions differ")
        for y in range(height):
            for x in range(width):
                source_pixel = pixel(source, 512, x + origin[0], y + origin[1])
                expected = bytes((255 - value if invert else value)
                                 for value in source_pixel[:3]) + b"\xff"
                require(pixel(pixels, width, x, y) == expected,
                        f"Wrong batch {index} pixel at ({x}, {y})")
    print("09 batch: all 16,384 pixels in both selected crops match")


def verify_audio(source: Path, output: Path) -> None:
    def wav(path: Path) -> bytes:
        with wave.open(str(path), "rb") as input_file:
            require((input_file.getnchannels(), input_file.getsampwidth(),
                     input_file.getframerate(), input_file.getnframes())
                    == (1, 2, 48000, 96000), f"Wrong WAV format or duration: {path}")
            return input_file.readframes(input_file.getnframes())

    source_pcm = wav(source)
    output_pcm = wav(output / "10-audio-passthrough.wav")
    require(output_pcm == source_pcm, "Audio passthrough changed PCM bytes")
    expected = bytearray()
    for index in range(96000):
        frequency = 440 if index < 48000 else 880
        value = round(2200 * math.sin(2 * math.pi * frequency * index / 48000))
        expected.extend(struct.pack("<h", value))
    require(output_pcm == expected, "Audio differs from deterministic 440/880 Hz samples")
    samples = struct.unpack("<96000h", output_pcm)
    require(spectral_amplitude(samples[12000:24000], 440, 48000)
            > 20 * spectral_amplitude(samples[12000:24000], 880, 48000),
            "First second is not dominated by 440 Hz")
    require(spectral_amplitude(samples[60000:72000], 880, 48000)
            > 20 * spectral_amplitude(samples[60000:72000], 440, 48000),
            "Second second is not dominated by 880 Hz")
    print("10 audio: 2.000-second WAV, 440/880 Hz tones, exact 192,000 PCM bytes")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify-base-test-set-results.py TEST_SET OUTPUT_DIR")
    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    expected = [
        "01-text-cleanup", "02-computed-image-resize", "03-masked-image-edit",
        "04-canvas-expansion-preview", "05-video-resize-with-audio",
        "06-json-status-decision", "07-red-channel-mask", "08-two-factor-blend",
        "09-two-crop-batch", "10-audio-passthrough",
    ]
    actual = sorted(path.name.removesuffix(".pixpipeline.json")
                    for path in source.glob("*.pixpipeline.json"))
    require(actual == expected, "The test-set workflow list has changed")
    width, height, source_pixels = png(source / "test-card.png")
    require((width, height) == (512, 384), "Source image dimensions differ")
    verify_text(output)
    verify_resize(source_pixels, output)
    verify_masked(source_pixels, output)
    verify_expansion(source_pixels, output)
    verify_video(source / "moving-test-card.mp4", output)
    verify_decision(output)
    verify_red_mask(source_pixels, output)
    verify_blends(source_pixels, output)
    verify_batch(source_pixels, output)
    verify_audio(source / "two-tone.wav", output)
    print("PASS: all ten executed pipeline outputs and both overrides match their expected results")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"FAIL: {error}") from error
