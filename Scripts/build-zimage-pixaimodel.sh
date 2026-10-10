#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* ]]; then
  print -u2 "usage: $0 /absolute/external/build-root"
  exit 2
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
build_root=${1:A}
for forbidden_root in "$repository_root" "$HOME/source/pixeltje"; do
  if [[ "$build_root" == "$forbidden_root" || "$build_root" == "$forbidden_root"/* ]]; then
    print -u2 "error: build root must not be inside $forbidden_root"
    exit 2
  fi
done

model_revision=f332072aa78be7aecdf3ee76d5c247082da564a6
publisher_revision=26f23eda626ffadda020b04ff79488e1d72004cd
apple_revision=cc812078731871574c9b2eb620aa40734c4b89ee
model_source="$build_root/source/Z-Image-Turbo"
publisher_reference="$build_root/repos/Z-Image"
apple_reference="$build_root/repos/coreai-models"
reports="$build_root/reports"
staging="$build_root/z-image-turbo.pixaimodel.staging"
output="$build_root/z-image-turbo.pixaimodel"
validator="$repository_root/Tools/ZImagePixAIModel/pixaimodel.py"
lock="$repository_root/Tools/ZImagePixAIModel/source-lock.json"

mkdir -p "$build_root/source" "$build_root/repos" "$reports"

checkout_pinned() {
  local url=$1
  local revision=$2
  local destination=$3
  local skip_lfs=${4:-false}
  if [[ ! -d "$destination/.git" ]]; then
    if [[ "$skip_lfs" == true ]]; then
      GIT_LFS_SKIP_SMUDGE=1 git clone --no-checkout "$url" "$destination"
    else
      git clone --no-checkout "$url" "$destination"
    fi
  fi
  if ! git -C "$destination" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$destination" fetch --no-tags origin "$revision"
  fi
  if [[ "$skip_lfs" == true ]]; then
    GIT_LFS_SKIP_SMUDGE=1 git -C "$destination" checkout --detach "$revision"
  else
    git -C "$destination" checkout --detach "$revision"
  fi
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]]
}

checkout_pinned https://github.com/Tongyi-MAI/Z-Image.git "$publisher_revision" "$publisher_reference"
checkout_pinned https://github.com/apple/coreai-models.git "$apple_revision" "$apple_reference"
checkout_pinned https://huggingface.co/Tongyi-MAI/Z-Image-Turbo "$model_revision" "$model_source" true

lfs_include='text_encoder/model-00001-of-00003.safetensors,text_encoder/model-00002-of-00003.safetensors,text_encoder/model-00003-of-00003.safetensors,tokenizer/tokenizer.json,transformer/diffusion_pytorch_model-00001-of-00003.safetensors,transformer/diffusion_pytorch_model-00002-of-00003.safetensors,transformer/diffusion_pytorch_model-00003-of-00003.safetensors,vae/diffusion_pytorch_model.safetensors'
git -C "$model_source" lfs pull --include="$lfs_include" --exclude=''

/usr/bin/python3 "$validator" audit-source --source "$model_source" --lock "$lock"
/usr/bin/python3 "$validator" audit-references \
  --publisher-reference "$publisher_reference" \
  --apple-reference "$apple_reference" \
  --lock "$lock"

if [[ ! -x /opt/homebrew/bin/uv ]]; then
  print -u2 "error: the pinned environment requires /opt/homebrew/bin/uv"
  exit 1
fi
(cd "$apple_reference" && /opt/homebrew/bin/uv sync --frozen --no-default-groups)
python="$apple_reference/.venv/bin/python"
export PYTHONPATH="$apple_reference/python/src"
export PYTHONPYCACHEPREFIX="$build_root/python-cache"
export PIXELTJE_COREAI_COMPUTE=gpu-preferred

generated_outputs=(
  "$output"
  "$staging/Components/prompt-encoder.aimodel"
  "$staging/Components/denoiser.aimodel"
  "$staging/Components/vae-encoder.aimodel"
  "$staging/Components/vae-decoder.aimodel"
  "$staging/validation.json"
  "$staging/manifest.json"
  "$staging/provenance.json"
  "$staging/Pipelines"
  "$staging/Resources"
  "$staging/Licenses"
  "$reports/prompt-encoder-export.json"
  "$reports/denoiser-export.json"
  "$reports/vae-encoder-export.json"
  "$reports/vae-decoder-export.json"
  "$reports/glue-and-validator-tests.log"
  "$reports/prompt-encoder.json"
  "$reports/denoiser.json"
  "$reports/denoiser.stdout.log"
  "$reports/denoiser.stderr.log"
  "$reports/denoiser-subprocess.json"
  "$reports/vae-encoder.json"
  "$reports/vae-decoder.json"
  "$reports/vae-encoder-tiling.json"
  "$reports/vae-decoder-tiling.json"
  "$reports/text-to-image-pipeline.json"
  "$reports/validation.preassembly.json"
)
for generated_output in "${generated_outputs[@]}"; do
  if [[ -e "$generated_output" || -L "$generated_output" ]]; then
    print -u2 "error: refusing to replace prior build evidence/output: $generated_output"
    exit 1
  fi
done
mkdir -p "$staging/Components"

export_component() {
  local component=$1
  local precision=$2
  local asset="$staging/Components/$component.aimodel"
  local report="$reports/$component-export.json"
  if [[ -e "$asset" || -e "$report" ]]; then
    print -u2 "error: partial component output exists; move it aside before rebuilding: $asset"
    exit 1
  fi
  local smoke=(--eager-device mps)
  if [[ "$component" == denoiser ]]; then
    smoke=(--skip-eager)
  fi
  "$python" "$repository_root/Tools/ZImagePixAIModel/export_components.py" "$component" \
    --source "$model_source" --output "$asset" --report "$report" \
    --precision "$precision" "${smoke[@]}"
}

glue_log="$reports/glue-and-validator-tests.log"
glue_log_temp=$(/usr/bin/mktemp "$reports/.glue-and-validator-tests.XXXXXX")
cleanup_glue_log_temp() {
  if [[ -n "${glue_log_temp:-}" ]]; then
    /bin/rm -f -- "$glue_log_temp"
  fi
}
trap cleanup_glue_log_temp EXIT
"$python" -m unittest discover -s "$repository_root/Tools/ZImagePixAIModel/tests" -v \
  2>&1 | tee "$glue_log_temp"
/bin/ln "$glue_log_temp" "$glue_log"
/bin/rm -f -- "$glue_log_temp"
glue_log_temp=
trap - EXIT

export_component prompt-encoder float16
export_component denoiser bfloat16
export_component vae-encoder float32
export_component vae-decoder float32

required_shapes=(512x512 1024x1024 1280x720 720x1280 2048x1152 1152x2048 2048x2048)
direct_vae_shapes=(512x512 1024x1024 1280x720 720x1280 2048x1152 1152x2048)

"$python" "$repository_root/Tools/ZImagePixAIModel/validate_components.py" prompt-encoder \
  --asset "$staging/Components/prompt-encoder.aimodel" --source "$model_source" \
  --reference-device mps --keep-going --report "$reports/prompt-encoder.json"
"$python" "$repository_root/Tools/ZImagePixAIModel/run_validation_subprocess.py" \
  --asset "$staging/Components/denoiser.aimodel" \
  --child-report "$reports/denoiser.json" \
  --stdout-log "$reports/denoiser.stdout.log" \
  --stderr-log "$reports/denoiser.stderr.log" \
  --report "$reports/denoiser-subprocess.json" \
  --timeout-seconds 7200 -- \
  "$python" "$repository_root/Tools/ZImagePixAIModel/validate_components.py" denoiser \
    --asset "$staging/Components/denoiser.aimodel" --source "$model_source" \
    --publisher-reference "$publisher_reference" \
    --precision bfloat16 --reference-device mps \
    --shapes "${required_shapes[@]}" --keep-going \
    --report "$reports/denoiser.json"
"$python" "$repository_root/Tools/ZImagePixAIModel/validate_components.py" vae-encoder \
  --asset "$staging/Components/vae-encoder.aimodel" --source "$model_source" \
  --reference-device mps --shapes "${direct_vae_shapes[@]}" --keep-going \
  --report "$reports/vae-encoder.json"
"$python" "$repository_root/Tools/ZImagePixAIModel/validate_components.py" vae-decoder \
  --asset "$staging/Components/vae-decoder.aimodel" --source "$model_source" \
  --reference-device mps --shapes "${direct_vae_shapes[@]}" --keep-going \
  --report "$reports/vae-decoder.json"
"$python" "$repository_root/Tools/ZImagePixAIModel/validate_vae_tiling.py" vae-encoder \
  --asset "$staging/Components/vae-encoder.aimodel" --source "$model_source" \
  --reference-device mps --report "$reports/vae-encoder-tiling.json"
"$python" "$repository_root/Tools/ZImagePixAIModel/validate_vae_tiling.py" vae-decoder \
  --asset "$staging/Components/vae-decoder.aimodel" --source "$model_source" \
  --reference-device mps --report "$reports/vae-decoder-tiling.json"

pipeline_status=0
"$python" "$repository_root/Tools/ZImagePixAIModel/validate_pipeline.py" \
  --source "$model_source" \
  --publisher-reference "$publisher_reference" \
  --prompt-encoder "$staging/Components/prompt-encoder.aimodel" \
  --denoiser "$staging/Components/denoiser.aimodel" \
  --vae-decoder "$staging/Components/vae-decoder.aimodel" \
  --reference-device mps --glue-test-log "$glue_log" \
  --report "$reports/text-to-image-pipeline.json" || pipeline_status=$?
if (( pipeline_status != 0 )); then
  print -u2 "pipeline validation is incomplete; aggregating its strict report to preserve explicit blocked gates"
fi

"$python" "$repository_root/Tools/ZImagePixAIModel/make_validation_record.py" \
  --source "$model_source" --publisher-reference "$publisher_reference" \
  --apple-reference "$apple_reference" --lock "$lock" \
  --prompt-report "$reports/prompt-encoder.json" \
  --denoiser-report "$reports/denoiser.json" \
  --vae-encoder-report "$reports/vae-encoder.json" \
  --vae-decoder-report "$reports/vae-decoder.json" \
  --vae-encoder-tiling-report "$reports/vae-encoder-tiling.json" \
  --vae-decoder-tiling-report "$reports/vae-decoder-tiling.json" \
  --pipeline-report "$reports/text-to-image-pipeline.json" \
  --glue-test-log "$glue_log" \
  --prompt-export-report "$reports/prompt-encoder-export.json" \
  --denoiser-export-report "$reports/denoiser-export.json" \
  --vae-encoder-export-report "$reports/vae-encoder-export.json" \
  --vae-decoder-export-report "$reports/vae-decoder-export.json" \
  --output "$reports/validation.preassembly.json"

"$python" "$repository_root/Tools/ZImagePixAIModel/assemble.py" \
  --staging "$staging" --output "$output" --source "$model_source" \
  --publisher-reference "$publisher_reference" --apple-reference "$apple_reference" \
  --validation "$reports/validation.preassembly.json"

/usr/bin/python3 "$validator" validate-package "$output"
print "complete package: $output"
