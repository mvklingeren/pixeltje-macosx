# SAM 3.1 text selection and background swap

`select-by-text.pixpipeline.json` selects objects named by a text prompt in a
chosen image. Its native `coreai.sam31Select` node runs a linked Core AI
`.aimodel` and tokenizer, combines the detected object masks, and writes a
black-and-white selection image. White pixels are selected. The workflow stores
only package identities and hashes; it does not contain model weights.

`product-background-swap.pixpipeline.json` uses that same text selection to
place a subject on a second image. It grows and feathers the selection by a
small amount, scales the new background to the subject photo's dimensions,
then composites and saves the result. Both source images should be in the same
folder so the Pipeline Editor can resolve them during execution.

This is a **Pipeline Editor** example. Pixeltje Mac's document selection tool
already has a separate, built-in SAM 3.1 **ComfyUI** workflow that can apply a
selection to the open image. The Core AI example does not yet feed that
document selection tool.

## Run the example

On the maintainer's machine, the reviewed package is installed at
`~/.pixeltje/models/coreai.meta.sam3.1-image-selection`. Build and open the
workflow with the Xcode beta toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run PixeltjePipeline Examples/SAM3.1/select-by-text.pixpipeline.json
```

In the Pipeline Editor, choose an image on **Choose an image**, edit the text on
**What to select** (for example, `fox`), and run the graph. The final node
previews the black-and-white selection. The default `person` prompt is a
starting value and should be changed to fit the image. If a package was
rebuilt or moved, select its directory in the model-package picker; the editor
explicitly relinks its model and tokenizer hashes.

The same graph can be checked without the UI:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run pixeltje-pipeline-run-sam31 \
  --workflow Examples/SAM3.1/select-by-text.pixpipeline.json \
  --image /absolute/path/to/image.png --prompt 'fox' \
  --output /private/tmp/sam31-selection.png
```

Add `--model-package /absolute/path/to/package` to explicitly relink a
different local export for that run. The saved workflow keeps its original
link until you relink and save it in the Pipeline Editor.

## Run the background-swap example

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run PixeltjePipeline Examples/SAM3.1/product-background-swap.pixpipeline.json
```

Choose a subject photo and a new background from the same folder. Change
**Select subject by text** to a visible object in the photo, then run the
graph. The background is center-cropped to the subject photo's aspect ratio.
If the subject edge needs refinement, edit **Expand selection slightly** and
**Soften selection edge** in the inspector. The saved result is a flattened
image; the graph does not alter a Pixeltje Mac document.

## Build the Core AI package yourself

Use Meta's original `facebook/sam3.1` publisher assets. Access to that model
repository must be granted on Hugging Face. Download the original
`sam3.1_multiplex.pt`, `config.json`, `tokenizer.json`,
`tokenizer_config.json`, `special_tokens_map.json`, `vocab.json`, `merges.txt`,
and `LICENSE` into one source directory at revision
`daa63191845a41281374e725f4c9e51c7a824460`. The offline recipe accepts
that directory:

```sh
python3.11 Scripts/CoreAI/export-sam31.py \
  --source /absolute/path/to/original-sam3.1 \
  --output /absolute/path/to/empty-coreai-package
```

The conversion environment used here had PyTorch 2.9.0, Transformers 5.12.1,
and `coreai_torch` 0.4.2. The recipe checks the original checkpoint's SHA-256,
maps only the detector weights, preserves SAM 3.1's three image feature
levels, exports float16 Core AI inference at 1008 × 1008 with 32 text token
slots, and writes the tokenizer and metadata beside the `.aimodel`. It uses
key-name mappings derived from Hugging Face's Apache-2.0 converter; the
working export and feature-level fix are authored here. It does not require an
online, ready-made SAM 3.1 Core AI recipe. Neither the original weights nor
the `.aimodel` are checked into this repository.

The example on this machine links model `main.hash`
`e41c0a848dcd286d180386edb5a6a998650255f2d65eadd7327413c57da2962d`
and tokenizer SHA-256
`6d9109cc838977f3ca94a379eec36aecc7c807e1785cd729660ca2fc0171fb35`.
Another export can have a different Core AI package hash; relink it explicitly.

## Verification

The Core AI model matched the corresponding corrected PyTorch detector on a
natural image: all five output tensors exceeded 30 dB PSNR and 0.999 cosine
similarity, with a matching tokenizer and image preprocessing. Running this
workflow with a fox image and `fox` selected 245,658 of 1,048,576 pixels
(23.4%). A prompt with no confident match produces an empty selection.

Sources: [Meta SAM 3.1 release notes](https://github.com/facebookresearch/sam3/blob/main/RELEASE_SAM3p1.md),
[original model assets](https://huggingface.co/facebook/sam3.1),
[Apple Core AI segmentation runtime](https://github.com/apple/coreai-models/tree/main/swift/Sources/CoreAIImageSegmenter),
and [Hugging Face's checkpoint mapping](https://github.com/huggingface/transformers/blob/main/src/transformers/models/sam3_video/convert_sam3_video_to_hf.py).
