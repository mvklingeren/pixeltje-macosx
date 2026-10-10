#!/usr/bin/env python3
"""Make the faster Plan-A SDXS workflow with a linked non-thinking Qwen3 package."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Examples/fantasy_scene_plan_a_sdxs_512_dreamshaper_qwen3_coreai.pixpipeline.json"
OUTPUT = ROOT / "Examples/fantasy_scene_plan_a_sdxs_512_dreamshaper_qwen3_no_think_coreai.pixpipeline.json"
PACKAGE = Path.home() / "coreai-models/exports/Qwen3-0.6B-no-think"
BUILT_LINKER = ROOT / ".build/out/Products/Debug/pixeltje-pipeline-link-text"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--package", type=Path, default=PACKAGE)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    package = args.package.expanduser().resolve(strict=True)
    if output.exists() and not args.replace:
        raise SystemExit(f"refusing to replace existing workflow: {output}")

    workflow = json.loads(source.read_text())
    workflow["id"] = "org.pixeltje.pipeline.fantasy-scene-plan-a-qwen3-no-think-sdxs-512-dreamshaper"
    workflow["name"] = "Plan-A Open Fantasy World — Qwen3 No Thinking and SDXS 512"
    writer = next(node for node in workflow["nodes"] if node["id"] == "characterWriter")
    writer["parameters"]["maxTokens"] = {"$type": "integer", "value": 256}

    # On later calls, the selected destination already carries the necessary
    # context. Repeating the complete previous image description makes this
    # small model reproduce the former camera framing.
    workflow["nodes"].append({
        "executionState": "enabled",
        "id": "removePreviousFraming",
        "kind": "text.regexReplace",
        "parameters": {
            "pattern": "Previous image prompt for visual continuity only[\\s\\S]*",
            "replacement": "Return valid JSON for a new close view with new imagePrompt and new visible region names and boxes.",
        },
        "resources": {},
        "title": "Keep Current View Brief",
    })
    connection = next(c for c in workflow["connections"] if
                      c["input"] == {"nodeID": "characterWriter", "port": "prompt"})
    connection["id"] = "nextView.prompt->removePreviousFraming.string"
    connection["input"] = {"nodeID": "removePreviousFraming", "port": "string"}
    workflow["connections"].append({
        "id": "removePreviousFraming.value->characterWriter.prompt",
        "output": {"nodeID": "removePreviousFraming", "port": "value"},
        "input": {"nodeID": "characterWriter", "port": "prompt"},
    })
    workflow["presentation"]["nodePositions"]["removePreviousFraming"] = {"x": 460, "y": 80}

    with tempfile.TemporaryDirectory(prefix="pixeltje-no-think-") as temporary:
        draft = Path(temporary) / "draft.pixpipeline.json"
        draft.write_text(json.dumps(workflow, indent=2, ensure_ascii=False) + "\n")
        linker = ([str(BUILT_LINKER)] if BUILT_LINKER.is_file() else
                  ["xcrun", "swift", "run", "pixeltje-pipeline-link-text"])
        command = linker + [
            "--workflow", str(draft), "--package", str(package),
            "--output", str(output), "--require-hf-model", "Qwen/Qwen3-0.6B",
        ]
        if args.replace:
            command.append("--force")
        environment = os.environ.copy()
        environment["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
        subprocess.run(command, cwd=ROOT, env=environment, check=True)


if __name__ == "__main__":
    main()
