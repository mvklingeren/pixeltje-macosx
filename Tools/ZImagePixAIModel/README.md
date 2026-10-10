# Z-Image Turbo PixAIModel offline build

This directory is the independently authored, fail-closed offline conversion
workflow specified by
`Documentation/Architecture/ZImage-PixAIModel-Build-Handoff.md`. It does not
use the dormant application pipeline, a sibling Pixeltje checkout, ComfyUI
code, or repackaged model weights.

## Contents

- `source-lock.json` pins the publisher model, publisher reference, Apple
  conversion tooling, exact source files, and byte hashes.
- `schemas/` contains the versioned manifest, pipeline, provenance, and
  validation JSON Schemas.
- `pipelines/` contains only the text-to-image graph. Other modes are not
  claimed until independently validated.
- `pixaimodel.py` audits sources and validates schemas, descriptors, package
  paths, hashes, inventory closure, required gates, and the resolution matrix.
- `export_components.py` converts semantic components from the original
  publisher Diffusers snapshot.
- `validate_components.py` performs descriptor, parity, finite-output, and
  repeatability checks against the publisher implementation.
- `run_validation_subprocess.py` contains full denoiser validation in a bounded
  child and durably records signals, timeouts, logs, pre/post asset identity,
  and strict child-report binding even when Core AI aborts.
- `profile_coreai.py` accepts only a metadata-marked tiny denoiser exported
  with `--debug-export`, records public Core AI profiler events, and explicitly
  makes no CPU, GPU, or Neural Engine placement claim. DEBUG probes are
  diagnostic artifacts and must never be used as package assembly inputs. Run
  the profiler through `run_validation_subprocess.py` when durable timeout or
  native-abort evidence is required.
- `glue.py` is an offline parity oracle for typed host operations. It is not
  shipped in the package or linked by the application.
- `assemble.py` refuses incomplete validation and assembles only into an
  external `.pixaimodel` directory.

The conversion environment is the exact `uv.lock` at the pinned Apple
`coreai-models` revision. Do not substitute an unpinned Python environment.

## Safety properties

The source audit rejects missing bytes, Git LFS pointers, wrong revisions,
wrong sizes, and wrong SHA-256 values. Package validation rejects path escapes,
symlinks, undeclared files, hash mismatches, executable content, training
formats, filename-bound pipeline nodes, absent gates, non-native/resampled
resolution results, and incomplete component parity.

Pipeline validation now closes the structural graph and resource contract, but
schema 1.0 ports still have no declared types and host operations have no typed
signatures to prove edge compatibility. The `typed-pipeline-contract` gate is
therefore explicitly blocked, and assembly must refuse until that declarative
type contract and its validator exist.

`sha256-tree-v1` hashes each sorted regular file as:

```text
F NUL relative-posix-path NUL decimal-size NUL file-sha256 LF
```

File metadata and empty directories are intentionally excluded.

## Numerical gates

- Prompt-encoder validation retains the fixed 512-token conversion contract.
  The host trims that output to the active tokens, selects the smallest
  publisher prompt bucket in 32-token increments from 32 through 512, and
  passes only that bucket to the denoiser.
- The denoiser has independent dynamic image-token and prompt-token axes. Its
  learned path and output use BF16; timestep and separate image/prompt RoPE
  real/imaginary inputs use float32. RoPE construction and application preserve
  the pinned publisher's `torch.polar(...).to(complex64)` rounding and exact
  complex multiplication. A real-expanded equivalent or a fixed-512 masked
  prompt graph does not satisfy the strict adapter parity gate.
- Every full denoiser case must reach correlation `0.999` and PSNR `40 dB`
  against the pinned publisher, while the independently authored adapter must
  reach correlation `0.99999` and PSNR `60 dB`. Minimum, middle, and maximum
  prompt buckets are full-model gates; tiny-probe coverage does not substitute
  for them.
- VAE encoder: correlation `0.99999`, PSNR `80 dB`, RMSE at most `0.001`, and
  maximum absolute error at most `0.075`.
- VAE decoder: correlation `0.9999` and maximum absolute error at most `0.02`.
- Repeated Core AI invocations must be bit-identical for the same inputs on
  the recorded system configuration.

These thresholds are gates, not a license to hide systematic errors. Reports
retain all measured metrics and exact shapes.

## Build location

Weights, Python environments, conversion reports, `.aimodel` components, and
the final `.pixaimodel` must remain outside the repository. The current durable
build root is `$HOME/px-pipeline-temp`. The assembly tool rejects
a staging or output path inside this Git checkout and rejects
`~/source/pixeltje` explicitly.

Run the complete orchestration command documented in
`Documentation/Architecture/ZImage-PixAIModel-Build.md`. Never describe a
package as complete merely because conversion produced model directories;
`pixaimodel.py validate-package` is the final fail-closed gate.

No `.pixaimodel` has been assembled. The corrected full BF16 denoiser passes
publisher/adapter/Core AI parity and exact repeatability at 512×512 for the
representative minimum, middle, and maximum prompt buckets (32, 256, and 512
tokens), and at 1024×1024, 1280×720, and 720×1280 for the canonical 32-token
bucket. Core AI's preference
permits CPU, GPU, and ANE and does not expose realized placement; the BF16
asset emits ANE I/O rejection warnings, so GPU-preferred success is not
evidence of ANE execution.

All required upper-resolution publisher-parity cases were attempted on the
recorded reference host, but none reached its Core AI comparison. The pinned
publisher MPS reference fails at both 2048×1152 and 1152×2048 with its
high-watermark out-of-memory diagnostic and exact failed 4.78 GiB private-pool
allocation; 2048×2048 fails there with
`Invalid buffer size: 15.00 GiB`. These remain reference-host blockers, not
parity passes.

Separately, an isolated Core-AI-only run of the full corrected asset at
2048×1152 returns finite output twice with zero repeat error; its first/repeat
times are 59.553/30.053 seconds, peak residency is 13,059,932,160 bytes, and
the asset digest remains unchanged. Without publisher and adapter outputs this
is diagnostic execution evidence, not numerical-parity or supported-resolution
evidence. A tiny DEBUG BF16 probe requested `ane-preferred` execution and
returned 65,536 finite values while the public profiler captured 18 events,
no callback errors, and only the MPSGraph IDs `call.$MPSGraph`,
`call.!MPSGraph`, and `call.MPSGraph`. The public profiler cannot prove
realized device placement, so this result makes no claim that ANE ran.

The native resolution gate therefore remains incomplete, as do end-to-end
image parity, cancellation, specialization/cache, residency, aggregate
performance, typed pipeline compatibility, package integrity, and
clean-environment gates. Corrected
evidence is under
`$HOME/px-pipeline-temp/denoiser-bisection-20260911-v1`;
historical FP16 evidence remains preserved under
`$HOME/px-pipeline-temp`.
