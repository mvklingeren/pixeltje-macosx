# Third-party notices

Pixeltje Mac is released under the [MIT License](LICENSE). This file lists the
material in or used by this repository that carries its own terms.

## Trademarks

ComfyUI is a trademark of Comfy Org. Pixeltje connects to a user-managed
ComfyUI server and is not affiliated with or endorsed by Comfy Org. See
[Comfy Org's trademark guidelines](https://comfy.org/brand/).

## Files under a different license

| File | Origin | License |
| --- | --- | --- |
| `Examples/Seascape.metal` | Metal adaptation of "Seascape" by Alexander Alekseev (TDM), 2014 | [CC BY-NC-SA 3.0 Unported](https://creativecommons.org/licenses/by-nc-sa/3.0/) |

This file is **not** covered by the MIT License. Its terms permit
non-commercial use only and require adaptations to be shared under the same
license. `Examples/shadertoy-seascape.pixpipeline.json` loads it by filename
and does not contain its source. Remove both files if you redistribute this
project under terms that conflict with that license.

## Adapted MIT-licensed source

| File | Origin |
| --- | --- |
| `Examples/SDFPrimitives.metal` | Adapted from Inigo Quilez's SDF primitives shader, © 2013 Inigo Quilez, MIT License |

The complete copyright and permission notice is retained at the top of the
file.

## Acknowledgements

`Examples/FlurryProgram.metal`, `Examples/FlarefunProgram.metal`, and the
shader in `Examples/shader-hearts.pixpipeline.json` are independently authored
reconstructions of the particle-and-feedback approach in Calum Robinson's
[Flurry](https://github.com/calumr/flurry) screen saver. They contain no Flurry
source.

## Swift package dependencies

SwiftPM fetches these packages at build time; their source is not included in
this repository. A binary distribution of Pixeltje includes code from them and
must reproduce their notices.

| Package | License |
| --- | --- |
| [apple/coreai-models](https://github.com/apple/coreai-models) | BSD 3-Clause |
| [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 |
| [huggingface/swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache 2.0 |
| [huggingface/swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [apple/swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | Apache 2.0 |
| [apple/swift-asn1](https://github.com/apple/swift-asn1) | Apache 2.0 |
| [mlc-ai/xgrammar](https://github.com/mlc-ai/xgrammar) | Apache 2.0 |
| [mattt/EventSource](https://github.com/mattt/EventSource) | MIT |
| [ibireme/yyjson](https://github.com/ibireme/yyjson) | MIT |

`coreai-models` and `swift-transformers` are direct dependencies; the others
are resolved transitively.

## Model weights

This repository contains no model weights. The setup and download scripts
fetch checkpoints from their original publishers on the user's request. Each
model is governed by its publisher's license, which can restrict commercial use;
review it before downloading or distributing a converted package.
