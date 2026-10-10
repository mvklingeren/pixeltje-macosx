#!/usr/bin/env python3
"""Regenerate the deterministic media in Examples/BaseTestSet.

The PNG writer uses only the Python standard library. ffmpeg is needed to
encode the small H.264/AAC video from generated RGB frames and a generated tone.
"""

from __future__ import annotations

import math
import struct
import subprocess
import tempfile
import wave
import zlib
from pathlib import Path


OUTPUT = Path(__file__).resolve().parents[1] / "Examples" / "BaseTestSet"

GLYPHS = {
    "0": ("111", "101", "101", "101", "111"),
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"),
    "7": ("111", "001", "001", "001", "001"),
    "8": ("111", "101", "111", "101", "111"),
    "9": ("111", "101", "111", "001", "111"),
    "E": ("111", "100", "110", "100", "111"),
    "F": ("111", "100", "110", "100", "100"),
    "L": ("100", "100", "100", "100", "111"),
    "O": ("111", "101", "101", "101", "111"),
    "P": ("111", "101", "111", "100", "100"),
    "T": ("111", "010", "010", "010", "010"),
}


def rectangle(pixels: bytearray, width: int, height: int, x: int, y: int,
              rect_width: int, rect_height: int, color: tuple[int, int, int]) -> None:
    for row in range(max(0, y), min(height, y + rect_height)):
        for column in range(max(0, x), min(width, x + rect_width)):
            offset = (row * width + column) * 3
            pixels[offset:offset + 3] = bytes(color)


def label(pixels: bytearray, width: int, height: int, message: str,
          x: int, y: int, scale: int = 3) -> None:
    for index, char in enumerate(message):
        for row, glyph_row in enumerate(GLYPHS[char]):
            for column, value in enumerate(glyph_row):
                if value == "1":
                    rectangle(pixels, width, height,
                              x + index * 4 * scale + column * scale,
                              y + row * scale, scale, scale, (255, 255, 255))


def test_card(width: int, height: int) -> bytearray:
    colors = ((198, 61, 69), (56, 159, 105),
              (51, 99, 199), (222, 177, 52))
    pixels = bytearray(width * height * 3)
    for y in range(height):
        for x in range(width):
            quadrant = 2 * (y >= height // 2) + (x >= width // 2)
            red, green, blue = colors[quadrant]
            if height * 5 // 12 <= y < height * 7 // 12:
                shade = round(x * 255 / (width - 1))
                red = green = blue = shade
            if x % 32 == 0 or y % 32 == 0:
                red, green, blue = (32, 32, 32)
            if x < 3 or y < 3 or x >= width - 3 or y >= height - 3:
                red, green, blue = (255, 255, 255)
            if (x - width * 0.69) ** 2 + (y - height * 0.73) ** 2 < (height * 0.12) ** 2:
                red, green, blue = (224, 51, 198)
            offset = (y * width + x) * 3
            pixels[offset:offset + 3] = bytes((red, green, blue))
    label(pixels, width, height, "TOP", width // 2 - 18, 11)
    label(pixels, width, height, "LEFT", 11, height // 2 - 42)
    return pixels


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def write_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    stride = width * 3
    scanlines = b"".join(b"\x00" + pixels[y * stride:(y + 1) * stride]
                         for y in range(height))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(scanlines, level=9))
        + png_chunk(b"IEND", b""))


def write_tone(path: Path) -> None:
    sample_rate = 48000
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        samples = bytearray()
        for index in range(sample_rate * 2):
            frequency = 440 if index < sample_rate else 880
            value = round(2200 * math.sin(2 * math.pi * frequency * index / sample_rate))
            samples.extend(struct.pack("<h", value))
        output.writeframes(samples)


def write_video(path: Path) -> None:
    width, height, frame_rate, frame_count = 320, 180, 12, 24
    with tempfile.TemporaryDirectory(prefix="pixeltje-test-video-") as directory:
        tone = Path(directory) / "tone.wav"
        write_tone(tone)
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
            "-framerate", str(frame_rate), "-i", "pipe:0", "-i", str(tone),
            "-map", "0:v:0", "-map", "1:a:0", "-frames:v", str(frame_count),
            "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", str(path),
        ]
        process = subprocess.Popen(command, stdin=subprocess.PIPE)
        try:
            assert process.stdin is not None
            for frame in range(frame_count):
                pixels = test_card(width, height)
                square_x = 15 + frame * 10
                square_y = 64 + round(18 * math.sin(2 * math.pi * frame / frame_count))
                rectangle(pixels, width, height, square_x, square_y, 30, 30,
                          (255, 255, 255))
                rectangle(pixels, width, height, square_x + 3, square_y + 3, 24, 24,
                          (25, 25, 25))
                rectangle(pixels, width, height, 6, 6, 37, 21, (20, 20, 20))
                label(pixels, width, height, f"{frame:02d}", 10, 9, scale=3)
                process.stdin.write(pixels)
            process.stdin.close()
            if process.wait() != 0:
                raise RuntimeError("ffmpeg could not encode the test video")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_png(OUTPUT / "test-card.png", 512, 384, test_card(512, 384))
    write_video(OUTPUT / "moving-test-card.mp4")
    write_tone(OUTPUT / "two-tone.wav")


if __name__ == "__main__":
    main()
