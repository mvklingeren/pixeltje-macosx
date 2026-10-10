# Base Test Set

Ten portable `*.pixpipeline.json` documents exercise the built-in pipeline
vocabulary with no Core AI package, tokenizer, model resource, or network
service. Every graph selects one primary output. The shared node scheduler
executes these graphs in both the headless runner and the Pipeline app.

| Workflow | Graph behavior | Independent output check |
| --- | --- | --- |
| `01-text-cleanup` | Trim, regex, title case, contains, If/Else | Exact text `Pipeline Test Card \| ready` |
| `02-computed-image-resize` | Dimensions drive arithmetic, scale, crop | Every pixel of 224 × 160 PNG |
| `03-masked-image-edit` | Rectangle, grow, feather, masked inverse | Representative inside, outside, and edge pixels |
| `04-canvas-expansion-preview` | Pad, mask, preview, composite | Geometry, source placement, border, preview |
| `05-video-resize-with-audio` | Split video, scale frame batch, preserve audio | 24 H.264 frames, duration, two AAC tones |
| `06-json-status-decision` | Extract `status` from JSON, compare, If/Else | Exact opposite text from default and override |
| `07-red-channel-mask` | Red channel, crop, threshold, invert, grayscale | Every one of 231 × 157 pixels |
| `08-two-factor-blend` | Blend test card and inverse twice | Every preview and final RGB pixel |
| `09-two-crop-batch` | Batch distinct crops, invert second, select index | Every pixel of both 128 × 128 outputs |
| `10-audio-passthrough` | `input.audio` to `output.audio` | Duration, frequencies, exact PCM bytes |

`test-card.png` is an opaque 512 × 384 RGB calibration image. The same card
is used by workflows 02–04 and 07–09. `moving-test-card.mp4` is a 320 × 180,
24-frame H.264/AAC clip at 12 fps. `two-tone.wav` is two seconds of 48 kHz,
mono, signed 16-bit PCM: 440 Hz for the first second and 880 Hz for the second.
These are the only media assets. The workflow JSON stores filenames as source
hints, not embedded media or absolute paths.

## Exact formulas and coordinates

- 06 starts with `{"status":"ready"}` and yields `Dispatch approved`. The
  exposed `status-json` override `{"status":"blocked"}` yields `Dispatch paused`.
- 07 reads red byte `R` at source coordinate `(x + 73, y + 54)` for output
  `(x, y)`, with `0 ≤ x < 231` and `0 ≤ y < 157`. Threshold is strictly
  `R / 255 > 0.52`. The inverted output is grayscale `0` when true, `255`
  otherwise, with opaque alpha.
- 08 uses source channel `A` and its inverse `B = 255 − A`. Preview uses
  normal blend factor 0.25: `P = round(0.75 A + 0.25 B)`. Final blends the
  preview with the inverse in multiply mode at factor 0.75:
  `round(0.25 P + 0.75 P B / 255)`. Each stage rounds to the nearest byte;
  half values round upward. Both images remain 512 × 384.
- 09 index 0 is the 128 × 128 source crop at `(32, 40)`. Index 1 is the
  128 × 128 crop at `(336, 208)`, with each RGB channel inverted. The
  exposed `batch-index` parameter selects 0 by default and 1 in the
  override run.
- 10 has exactly 96,000 samples; sample `i` is the signed 16-bit value
  `round(2200 sin(2π f i / 48000))`, with `f = 440` before `i = 48000` and
  `f = 880` afterwards. The output PCM must match the source byte for byte.

Run the whole set, including the two override runs and independent output
verification, with:

```sh
sh Scripts/run-base-test-set.sh
```

The script uses the Xcode beta toolchain, creates an output directory under
the system temporary directory, prints each workflow's progress, and exits
nonzero on a graph or output mismatch. Pass an empty output directory as its
sole argument to keep the results there. The pipeline runtime uses AVFoundation
for video and does not launch `ffmpeg`. The independent result verifier still
needs `ffmpeg` and `ffprobe` for media checks.

Regenerate graph JSON and media with:

```sh
python3 Scripts/generate-base-test-set-workflows.py
python3 Scripts/generate-base-test-set-assets.py
```

The media generator needs `ffmpeg` with `libx264` and AAC encoders. A lighter
structure and input-media check is available with:

```sh
sh Scripts/validate-base-test-set.sh
```

That check does not execute graph nodes. The run script is the executable
fixture check.
