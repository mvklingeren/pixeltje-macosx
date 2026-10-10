#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
coreai_root="$project_root/.build/checkouts/coreai-models"
exporter="$coreai_root/.venv/bin/coreai.llm.export"
hf_cli="$coreai_root/.venv/bin/hf"
model_library=${PIXELTJE_MODEL_LIBRARY:-$HOME/.pixeltje/models}
package_root="$model_library/gemma-3-12b-instruct-coreai"
linked_workflow="$HOME/.pixeltje/pipelines/gemma-3-12b-instruct-linked.pixpipeline.json"
agent_config="$HOME/.pixeltje/pipeline-agent.json"
activate_agent=false

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
  echo "Usage: $0 [--activate-agent]"
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--activate-agent" ) ]]; then
  echo "Usage: $0 [--activate-agent]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  activate_agent=true
fi
if [[ ! -x "$exporter" || ! -x "$hf_cli" ]]; then
  echo "The pinned coreai-models Python environment is missing at $coreai_root/.venv" >&2
  exit 1
fi

mkdir -p "$model_library"
if [[ ! -e "$package_root" ]]; then
  echo "Checking access to google/gemma-3-12b-it…"
  if ! "$hf_cli" download google/gemma-3-12b-it config.json >/dev/null; then
    echo "Hugging Face denied the model files. Accept the Gemma terms for the account used by 'hf auth whoami', then retry." >&2
    exit 1
  fi
  echo "Exporting Gemma 3 12B Instruct (4-bit, 8192-token context) to $package_root…"
  (
    cd "$coreai_root"
    "$exporter" gemma3-12b-it \
      --compression 4bit \
      --compute-precision bfloat16 \
      --max-context-length 8192 \
      --output-dir "$model_library" \
      --output-name gemma-3-12b-instruct-coreai
  )
else
  echo "Using the existing package at $package_root"
  if [[ ! -f "$package_root/metadata.json" ]]; then
    echo "The existing package is incomplete. Move it aside before retrying: $package_root" >&2
    exit 1
  fi
fi

python3 - "$package_root/metadata.json" <<'PY'
import json
import sys
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text())
if metadata.get("source", {}).get("hf_model_id") != "google/gemma-3-12b-it":
    raise SystemExit("The package is not Gemma 3 12B Instruct.")
if metadata.get("compression") != "4bit":
    raise SystemExit("The package does not use the required 4-bit compression.")
if metadata.get("language", {}).get("max_context_length") != 8192:
    raise SystemExit("The package does not declare the selected 8192-token context.")
PY

python3 - "$package_root/tokenizer" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

tokenizer_dir = Path(sys.argv[1])
config_path = tokenizer_dir / "tokenizer_config.json"
tokens_path = tokenizer_dir / "tokenizer.json"
config = json.loads(config_path.read_text())
tokens = json.loads(tokens_path.read_text())
turn_end = "<end_of_turn>"
if not any(
    token.get("content") == turn_end and token.get("special") is True
    for token in tokens.get("added_tokens", [])
):
    raise SystemExit("The Gemma tokenizer has no special end-of-turn token.")
if config.get("end_of_turn") != turn_end:
    config["end_of_turn"] = turn_end
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=tokenizer_dir, delete=False
    ) as temporary:
        json.dump(config, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary_path = temporary.name
    os.replace(temporary_path, config_path)
    print("Registered Gemma's end-of-turn token for Core AI generation.")
PY

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift build --package-path "$project_root" --product pixeltje-pipeline-link-text
linker=$(DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift build --package-path "$project_root" --show-bin-path)/pixeltje-pipeline-link-text
"$linker" \
  --workflow "$project_root/Examples/gemma-3-12b-instruct-coreai.pixpipeline.json" \
  --package "$package_root" \
  --require-hf-model google/gemma-3-12b-it \
  --output "$linked_workflow" \
  --force

if $activate_agent; then
  python3 - "$agent_config" "$package_root" "$linked_workflow" <<'PY'
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path

config_path, package_root, linked_workflow = map(Path, sys.argv[1:])
config_path.parent.mkdir(parents=True, exist_ok=True)
config = json.loads(config_path.read_text()) if config_path.exists() else {}
if config_path.exists():
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = config_path.with_name(f"{config_path.name}.backup-{stamp}")
    shutil.copy2(config_path, backup)
    print(f"Saved previous agent configuration to {backup}")

config["agentPackage"] = str(package_root)
config["agentPipeline"] = str(linked_workflow)
config["modelWorkflowCalls"] = False
config["temperature"] = 0.7
config.setdefault("maximumResponseTokens", 1024)
config.setdefault("systemPrompt", "You are a helpful assistant. Answer clearly and accurately.")
for workflow in config.get("workflows") or []:
    if workflow.get("pipeline") == "builtin:text":
        workflow["package"] = str(package_root)

with tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", dir=config_path.parent, delete=False
) as temporary:
    os.chmod(temporary.name, 0o600)
    json.dump(config, temporary, indent=2)
    temporary.write("\n")
    temporary_path = temporary.name
os.replace(temporary_path, config_path)
print(f"Activated Gemma in {config_path}")
PY
  echo "Start a new AionUI conversation to load the new model."
fi

echo "Gemma Core AI package: $package_root"
echo "Linked workflow: $linked_workflow"
