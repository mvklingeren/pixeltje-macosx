#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
example="$project_root/Examples/image_flux2_klein_text_to_image_4b_distilled-coreai.pixpipeline.json"
model_package=${PIXELTJE_FLUX2_KLEIN_MODEL_PATH:-"$HOME/coreai-models/exports/FLUX.2-klein-4B"}
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

if [[ ! -f "$example" ]]; then
  print -u2 "error: FLUX.2 Klein example is missing: $example"
  exit 1
fi

if [[ ! -d "$model_package" ]]; then
  print -u2 "error: FLUX.2 Klein model package is missing: $model_package"
  exit 1
fi

cd "$project_root"
DEVELOPER_DIR="$developer_directory" \
PIXELTJE_FLUX2_KLEIN_MODEL_PATH="$model_package" \
exec xcrun swift run PixeltjePipeline "$example"
