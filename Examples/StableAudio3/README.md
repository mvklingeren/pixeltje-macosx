# Stable Audio 3 Small SFX gunshot

Open [`../stable-audio-3-small-sfx-gunshot.pixpipeline.json`](../stable-audio-3-small-sfx-gunshot.pixpipeline.json)
in the Pipeline Editor and run it. The Audio Diffusion Generate node produces
a two-second, stereo 44.1 kHz WAV from the saved gunshot prompt and seed.
The Audio Output node returns the file to the editor.

The graph links five local resources: text encoder, duration encoder,
denoiser, audio decoder, and tokenizer. They are expected in
`~/coreai-models/exports/Stable-Audio-3-Small-SFX`. If moved or regenerated,
select the new package directory in the editor to relink them. The weights are
never copied into the workflow or repository.

To render from the command line after building the package:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run pixeltje-pipeline-run-stable-audio-3 \
  Examples/stable-audio-3-small-sfx-gunshot.pixpipeline.json \
  "$HOME/coreai-models/exports/Stable-Audio-3-Small-SFX" \
  /private/tmp/gunshot.wav
```

The conversion script is [`../../Scripts/convert-stable-audio-3-small-sfx.py`](../../Scripts/convert-stable-audio-3-small-sfx.py).
It accepts `--checkpoint` for the original publisher snapshot and `--output`
for a new export directory. Use an isolated Python environment with PyTorch,
Transformers, safetensors, Apple's `coreai-torch` and `coreai-models`, and the
publisher's `stable_audio_3` source on `PYTHONPATH`. `--max-duration` sets the
longest effect the export can generate, 11 seconds by default; its denoiser and
decoder size each clip's latent canvas to the requested duration, so a
two-second effect still uses 88 frames. The bundled examples link an 11-second
export. The decoder's small inference noise is disabled for deterministic
Core AI export.
