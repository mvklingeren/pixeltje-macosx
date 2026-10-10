#!/usr/bin/env python3
"""Clone the local Qwen3 Core AI package with its chat template in non-thinking mode.

The weights are copied by APFS clone and remain identical. Only the embedded
Qwen3 chat template changes. The original package is never modified.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


SOURCE = Path.home() / ".pixeltje/models/qwen3-coreai"
OUTPUT = Path.home() / "coreai-models/exports/Qwen3-0.6B-no-think"
SWITCH = """    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\\n\\n</think>\\n\\n' }}
    {%- endif %}"""
NO_THINK = """    {{- '<think>\\n\\n</think>\\n\\n' }}"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    if output.exists():
        raise SystemExit(f"refusing to replace existing package: {output}")
    metadata = json.loads((source / "metadata.json").read_text())
    if metadata.get("source", {}).get("hf_model_id") != "Qwen/Qwen3-0.6B":
        raise ValueError("source is not the Qwen3-0.6B Core AI package")
    if metadata.get("assets", {}).get("main") != "qwen3-coreai.aimodel":
        raise ValueError("unexpected Qwen3 Core AI asset")
    source_template = source / "tokenizer/chat_template.jinja"
    template = source_template.read_text()
    if template.count(SWITCH) != 1:
        raise ValueError("Qwen3 template has no unique thinking-mode switch")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.with_name(output.name + ".partial")
    if staging.exists():
        raise SystemExit(f"unfinished package already exists: {staging}")
    subprocess.run(["cp", "-cR", str(source), str(staging)], check=True)
    target = staging / "tokenizer/chat_template.jinja"
    target.write_text(template.replace(SWITCH, NO_THINK))
    staging.rename(output)
    print(f"Ready: {output}")


if __name__ == "__main__":
    main()
