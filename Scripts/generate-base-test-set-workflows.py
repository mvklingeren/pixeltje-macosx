#!/usr/bin/env python3
"""Regenerate the ten editable Base Test Set Pixeltje pipeline examples."""

from __future__ import annotations

import json
from pathlib import Path


OUTPUT = Path(__file__).resolve().parents[1] / "Examples" / "BaseTestSet"


def integer(value: int) -> dict:
    return {"$type": "integer", "value": value}


def number(value: float) -> dict:
    return {"$type": "number", "value": value}


def exposed(parameter_id: str, label: str, value_type: str, node_id: str,
            parameter: str, default: object, minimum: float | None = None,
            maximum: float | None = None) -> dict:
    result = {
        "id": parameter_id, "label": label, "valueType": value_type,
        "target": {"nodeID": node_id, "parameter": parameter},
        "defaultValue": default,
    }
    if minimum is not None:
        result["minimum"] = minimum
    if maximum is not None:
        result["maximum"] = maximum
    return result


# A node is (id, kind, title, x, y, parameters). A link is
# (source id, output port, destination id, input port).
WORKFLOWS = [
    {
        "stem": "01-text-cleanup", "name": "Base Test Set 01 · Text Cleanup",
        "mode": "generic", "output": "output",
        "nodes": [
            ("source", "primitive.string.multiline", "Source text", 0, 120,
             {"value": "  pipeline   test CARD  "}),
            ("trim", "text.trim", "Trim spaces", 240, 120, {"mode": "Both"}),
            ("collapse", "text.regexReplace", "Collapse whitespace", 480, 120,
             {"pattern": r"\s+", "replacement": " ", "count": integer(0)}),
            ("case", "text.changeCase", "Title case", 720, 120,
             {"mode": "Title Case"}),
            ("contains", "text.contains", "Has Test", 960, 0,
             {"substring": "Test", "caseSensitive": True}),
            ("fallback", "primitive.string", "Fallback", 960, 360,
             {"value": "No test label"}),
            ("switch", "logic.ifElse", "Use title or fallback", 1200, 120, {}),
            ("suffix", "primitive.string", "Status suffix", 1200, 360,
             {"value": " | ready"}),
            ("join", "text.concatenate", "Append status", 1440, 120,
             {"delimiter": ""}),
            ("output", "output.text", "Text result", 1680, 120, {}),
        ],
        "links": [
            ("source", "value", "trim", "string"),
            ("trim", "value", "collapse", "string"),
            ("collapse", "value", "case", "string"),
            ("case", "value", "contains", "string"),
            ("contains", "result", "switch", "condition"),
            ("case", "value", "switch", "trueValue"),
            ("fallback", "value", "switch", "falseValue"),
            ("switch", "value", "join", "stringA"),
            ("suffix", "value", "join", "stringB"),
            ("join", "value", "output", "text"),
        ],
        "exposed": [exposed("source-text", "Source text", "string", "source",
                            "value", "  pipeline   test CARD  ")],
    },
    {
        "stem": "02-computed-image-resize",
        "name": "Base Test Set 02 · Computed Image Resize",
        "mode": "imageToImage", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 180,
             {"sourceName": "test-card.png"}),
            ("dimensions", "image.dimensions", "Read dimensions", 240, 40, {}),
            ("half-width", "math.expression", "Half width", 480, 0,
             {"expression": "a / 2"}),
            ("half-height", "math.expression", "Half height", 480, 200,
             {"expression": "a / 2"}),
            ("scale", "image.scale", "Scale to half size", 720, 180,
             {"upscaleMethod": "nearest-exact"}),
            ("crop", "image.crop", "Inset crop", 960, 180,
             {"x": integer(16), "y": integer(16), "width": integer(224),
              "height": integer(160)}),
            ("output", "output.image", "Image result", 1200, 180,
             {"filenamePrefix": "computed-resize"}),
        ],
        "links": [
            ("source", "image", "dimensions", "image"),
            ("dimensions", "width", "half-width", "a"),
            ("dimensions", "height", "half-height", "a"),
            ("source", "image", "scale", "image"),
            ("half-width", "integer", "scale", "width"),
            ("half-height", "integer", "scale", "height"),
            ("scale", "image", "crop", "image"),
            ("crop", "image", "output", "image"),
        ],
        "exposed": [exposed("crop-width", "Crop width", "integer", "crop",
                            "width", integer(224), 1, 256)],
    },
    {
        "stem": "03-masked-image-edit", "name": "Base Test Set 03 · Masked Image Edit",
        "mode": "inpainting", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 120,
             {"sourceName": "test-card.png"}),
            ("invert", "image.invert", "Inverted candidate", 240, 20, {}),
            ("empty-mask", "mask.solid", "Empty full-size mask", 0, 360,
             {"value": number(0), "width": integer(512), "height": integer(384)}),
            ("rectangle-mask", "mask.solid", "Solid rectangle", 0, 570,
             {"value": number(1), "width": integer(160), "height": integer(120)}),
            ("place-mask", "mask.composite", "Place rectangle", 240, 420,
             {"x": integer(176), "y": integer(104), "operation": "add"}),
            ("grow", "mask.grow", "Grow selection", 480, 420,
             {"expand": integer(12), "taperedCorners": True}),
            ("feather", "mask.feather", "Soften edge", 720, 420,
             {"left": integer(8), "top": integer(8), "right": integer(8),
              "bottom": integer(8)}),
            ("composite", "image.compositeMasked", "Masked replacement", 960, 180,
             {}),
            ("output", "output.image", "Image result", 1200, 180,
             {"filenamePrefix": "masked-edit"}),
        ],
        "links": [
            ("source", "image", "invert", "image"),
            ("empty-mask", "mask", "place-mask", "destination"),
            ("rectangle-mask", "mask", "place-mask", "source"),
            ("place-mask", "mask", "grow", "mask"),
            ("grow", "mask", "feather", "mask"),
            ("source", "image", "composite", "destination"),
            ("invert", "image", "composite", "source"),
            ("feather", "mask", "composite", "mask"),
            ("composite", "image", "output", "image"),
        ],
        "exposed": [exposed("mask-growth", "Mask growth", "integer", "grow",
                            "expand", integer(12), -32, 32)],
    },
    {
        "stem": "04-canvas-expansion-preview",
        "name": "Base Test Set 04 · Canvas Expansion Preview",
        "mode": "outpainting", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 180,
             {"sourceName": "test-card.png"}),
            ("pad", "image.padForOutpaint", "Expand canvas", 240, 180,
             {"left": integer(48), "top": integer(24), "right": integer(80),
              "bottom": integer(40), "feathering": integer(16)}),
            ("fill", "image.fillMasked", "Fill border", 480, 120,
             {"value": number(0.5)}),
            ("threshold", "mask.threshold", "Binary border", 480, 420,
             {"value": number(0.5)}),
            ("mask-image", "mask.toImage", "Show mask as image", 720, 420, {}),
            ("composite", "image.compositeMasked", "Overlay border guide", 960, 180,
             {}),
            ("preview", "output.preview", "Mask preview", 960, 420, {}),
            ("output", "output.image", "Image result", 1200, 180,
             {"filenamePrefix": "canvas-expansion"}),
        ],
        "links": [
            ("source", "image", "pad", "image"),
            ("pad", "image", "fill", "image"),
            ("pad", "mask", "fill", "mask"),
            ("pad", "mask", "threshold", "mask"),
            ("threshold", "mask", "mask-image", "mask"),
            ("fill", "image", "composite", "destination"),
            ("mask-image", "image", "composite", "source"),
            ("threshold", "mask", "composite", "mask"),
            ("mask-image", "image", "preview", "image"),
            ("composite", "image", "output", "image"),
        ],
        "exposed": [exposed("right-padding", "Right padding", "integer", "pad",
                            "right", integer(80), 0, 256)],
    },
    {
        "stem": "05-video-resize-with-audio",
        "name": "Base Test Set 05 · Video Resize with Audio",
        "mode": "generic", "output": "output",
        "nodes": [
            ("source", "input.video", "Moving test card", 0, 180,
             {"sourceName": "moving-test-card.mp4"}),
            ("components", "media.videoComponents", "Split video", 240, 180, {}),
            ("scale", "image.scaleBy", "Half-size frames", 480, 40,
             {"upscaleMethod": "nearest-exact", "scaleBy": number(0.5)}),
            ("audio-route", "utility.reroute", "Preserve audio", 480, 340, {}),
            ("create", "media.createVideo", "Reassemble", 720, 180,
             {"framesPerSecond": number(12), "bitDepth": "auto",
              "colorSpace": "sRGB", "codec": "h264"}),
            ("output", "output.video", "Video result", 960, 180,
             {"filenamePrefix": "resized-test-card", "format": "mp4",
              "codec": "h264"}),
        ],
        "links": [
            ("source", "video", "components", "video"),
            ("components", "images", "scale", "image"),
            ("components", "audio", "audio-route", "value"),
            ("audio-route", "value", "create", "audio"),
            ("scale", "image", "create", "images"),
            ("create", "video", "output", "video"),
        ],
        "exposed": [exposed("frame-scale", "Frame scale", "number", "scale",
                            "scaleBy", number(0.5), 0.25, 1.0)],
    },
    {
        "stem": "06-json-status-decision", "name": "Base Test Set 06 · JSON Status Decision",
        "mode": "generic", "output": "output",
        "nodes": [
            ("status", "primitive.string.multiline", "JSON status", 0, 120,
             {"value": '{"status":"ready"}'}),
            ("extract", "text.jsonExtract", "Extract status", 240, 120,
             {"key": "status"}),
            ("compare", "text.compare", "Is ready", 480, 120,
             {"stringB": "ready", "mode": "Equal", "caseSensitive": True}),
            ("yes", "primitive.string", "Approved", 480, 340,
             {"value": "Dispatch approved"}),
            ("no", "primitive.string", "Paused", 480, 500,
             {"value": "Dispatch paused"}),
            ("decision", "logic.ifElse", "Choose message", 720, 180, {}),
            ("output", "output.text", "Text result", 960, 180, {}),
        ],
        "links": [
            ("status", "value", "extract", "json"),
            ("extract", "value", "compare", "stringA"),
            ("compare", "result", "decision", "condition"),
            ("yes", "value", "decision", "trueValue"),
            ("no", "value", "decision", "falseValue"),
            ("decision", "value", "output", "text"),
        ],
        "exposed": [exposed("status-json", "Status JSON", "string", "status",
                            "value", '{"status":"ready"}')],
    },
    {
        "stem": "07-red-channel-mask", "name": "Base Test Set 07 · Red Channel Mask",
        "mode": "selection", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 160,
             {"sourceName": "test-card.png"}),
            ("channel", "mask.fromImage", "Red channel", 240, 160,
             {"channel": "red"}),
            ("crop", "mask.crop", "Crop mask", 480, 160,
             {"x": integer(73), "y": integer(54), "width": integer(231),
              "height": integer(157)}),
            ("threshold", "mask.threshold", "Binary mask", 720, 160,
             {"value": number(0.52)}),
            ("invert", "mask.invert", "Invert mask", 960, 160, {}),
            ("image", "mask.toImage", "Grayscale mask", 1200, 160, {}),
            ("output", "output.image", "Image result", 1440, 160, {}),
        ],
        "links": [
            ("source", "image", "channel", "image"),
            ("channel", "mask", "crop", "mask"),
            ("crop", "mask", "threshold", "mask"),
            ("threshold", "mask", "invert", "mask"),
            ("invert", "mask", "image", "mask"),
            ("image", "image", "output", "image"),
        ],
        "exposed": [],
    },
    {
        "stem": "08-two-factor-blend", "name": "Base Test Set 08 · Two Factor Blend",
        "mode": "imageToImage", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 160,
             {"sourceName": "test-card.png"}),
            ("invert", "image.invert", "Inverse", 240, 40, {}),
            ("preview-blend", "image.blend", "Quarter normal blend", 480, 0,
             {"blendFactor": number(0.25), "blendMode": "normal"}),
            ("preview", "output.preview", "Blend preview", 720, 0, {}),
            ("final-blend", "image.blend", "Three-quarter multiply blend", 480, 280,
             {"blendFactor": number(0.75), "blendMode": "multiply"}),
            ("output", "output.image", "Image result", 720, 280, {}),
        ],
        "links": [
            ("source", "image", "invert", "image"),
            ("source", "image", "preview-blend", "imageA"),
            ("invert", "image", "preview-blend", "imageB"),
            ("preview-blend", "image", "preview", "image"),
            ("preview-blend", "image", "final-blend", "imageA"),
            ("invert", "image", "final-blend", "imageB"),
            ("final-blend", "image", "output", "image"),
        ],
        "exposed": [],
    },
    {
        "stem": "09-two-crop-batch", "name": "Base Test Set 09 · Two Crop Batch",
        "mode": "imageToImage", "output": "output",
        "nodes": [
            ("source", "input.image", "Test card", 0, 200,
             {"sourceName": "test-card.png"}),
            ("left", "image.crop", "Upper-left crop", 240, 40,
             {"x": integer(32), "y": integer(40), "width": integer(128),
              "height": integer(128)}),
            ("right", "image.crop", "Lower-right crop", 240, 340,
             {"x": integer(336), "y": integer(208), "width": integer(128),
              "height": integer(128)}),
            ("invert", "image.invert", "Invert second crop", 480, 340, {}),
            ("batch", "image.batch", "Two crops", 720, 180, {}),
            ("select", "image.fromBatch", "Select crop", 960, 180,
             {"batchIndex": integer(0), "length": integer(1)}),
            ("output", "output.image", "Image result", 1200, 180, {}),
        ],
        "links": [
            ("source", "image", "left", "image"),
            ("source", "image", "right", "image"),
            ("right", "image", "invert", "image"),
            ("left", "image", "batch", "imageA"),
            ("invert", "image", "batch", "imageB"),
            ("batch", "image", "select", "image"),
            ("select", "image", "output", "image"),
        ],
        "exposed": [exposed("batch-index", "Batch index", "integer", "select",
                            "batchIndex", integer(0), 0, 1)],
    },
    {
        "stem": "10-audio-passthrough", "name": "Base Test Set 10 · Audio Passthrough",
        "mode": "generic", "output": "output",
        "nodes": [
            ("source", "input.audio", "Two-tone WAV", 0, 120,
             {"sourceName": "two-tone.wav"}),
            ("output", "output.audio", "Audio result", 240, 120,
             {"filenamePrefix": "two-tone"}),
        ],
        "links": [("source", "audio", "output", "audio")],
        "exposed": [],
    },
]


def write_workflow(spec: dict) -> None:
    nodes = [
        {"id": node_id, "kind": kind, "title": title,
         "executionState": "enabled", "parameters": parameters, "resources": {}}
        for node_id, kind, title, _, _, parameters in spec["nodes"]
    ]
    positions = {
        node_id: {"x": x, "y": y}
        for node_id, _, _, x, y, _ in spec["nodes"]
    }
    connections = [
        {"id": f"{source}.{output}->{target}.{input_port}",
         "output": {"nodeID": source, "port": output},
         "input": {"nodeID": target, "port": input_port}}
        for source, output, target, input_port in spec["links"]
    ]
    document = {
        "schemaVersion": 2,
        "id": f"org.pixeltje.examples.base-test-set.{spec['stem']}",
        "name": spec["name"],
        "mode": spec["mode"],
        "requirements": {"minimumEngineVersion": 1,
                         "familyABIs": []},
        "nodes": nodes,
        "connections": connections,
        "exposedParameters": spec["exposed"],
        "primaryOutputNodeIDs": [spec["output"]],
        "presentation": {
            "nodePositions": positions, "nodeSizes": {}, "groups": [],
            "viewportOrigin": {"x": 0, "y": 0}, "viewportScale": 0.8,
        },
    }
    path = OUTPUT / f"{spec['stem']}.pixpipeline.json"
    path.write_text(json.dumps(document, indent=2, sort_keys=True,
                               ensure_ascii=False) + "\n")


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for spec in WORKFLOWS:
        write_workflow(spec)


if __name__ == "__main__":
    main()
