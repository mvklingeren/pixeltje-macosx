#!/bin/sh
# Execute the ten Base Test Set graphs and two overrides, then verify their outputs.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_set="$project_root/Examples/BaseTestSet"
if [ "$#" -gt 1 ]; then
  echo "Usage: sh Scripts/run-base-test-set.sh [empty-output-directory]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  output_dir=$1
else
  output_dir=$(mktemp -d "${TMPDIR:-/tmp}/pixeltje-base-test-set-results.XXXXXX")
fi

command -v ffmpeg >/dev/null 2>&1 || {
  echo "ffmpeg is required for independent output verification." >&2
  exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
  echo "ffprobe is required for video output verification." >&2
  exit 1
}

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run --disable-sandbox --package-path "$project_root" \
  pixeltje-pipeline-run-base-test-set \
  --test-set "$test_set" --output-dir "$output_dir" \
  --override '06-json-status-decision:status-json={"status":"blocked"}' \
  --override '09-two-crop-batch:batch-index=1'
python3 "$project_root/Scripts/verify-base-test-set-results.py" \
  "$test_set" "$output_dir"
