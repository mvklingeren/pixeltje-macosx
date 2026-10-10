#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
catalog_dir="$script_dir"
if [[ ! -f "$catalog_dir/resources.tsv" ]]; then
  catalog_dir="$script_dir/../../Sources/PixeltjeMacKit/Resources/ComfyUI"
fi
catalog="$catalog_dir/resources.tsv"
workflow_map="$catalog_dir/workflow-resources.tsv"

usage() {
  printf 'Usage: %s WORKFLOW_ID [--models-dir PATH] [--download|--check|--list]\n' "$(basename "$0")"
  printf 'Checks one bundled Pixeltje ComfyUI workflow and optionally downloads missing model files.\n'
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi
workflow_id=$1
shift
models_dir=''
action=check
while (( $# > 0 )); do
  case "$1" in
    --models-dir)
      if (( $# < 2 )); then usage >&2; exit 2; fi
      models_dir=$2
      shift 2
      ;;
    --download|--check|--list)
      action=${1#--}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$catalog" || ! -f "$workflow_map" ]]; then
  printf 'The bundled ComfyUI resource catalog is missing.\n' >&2
  exit 2
fi

required_ids=()
while IFS=$'\t' read -r listed_workflow resource_id; do
  if [[ "$listed_workflow" == "$workflow_id" ]]; then
    required_ids+=("$resource_id")
  fi
done < "$workflow_map"
if (( ${#required_ids[@]} == 0 )); then
  printf 'Unknown workflow: %s\n' "$workflow_id" >&2
  exit 2
fi

if [[ "$action" != list ]]; then
  if [[ -z "$models_dir" ]]; then
    default_models_dir="$HOME/ComfyUI-Shared/models"
    printf 'I will use the directory ~/ComfyUI-Shared/models. Is that OK? [Y/n] '
    read -r answer
    case "$answer" in
      ''|y|Y|yes|YES|Yes)
        models_dir="$default_models_dir"
        ;;
      *)
        read -r -p 'ComfyUI models directory: ' models_dir
        ;;
    esac
  fi
  if [[ -d "$models_dir/models" && ! -d "$models_dir/diffusion_models" ]]; then
    models_dir="$models_dir/models"
  fi
  if [[ ! -d "$models_dir" ]]; then
    printf 'Models directory does not exist: %s\n' "$models_dir" >&2
    exit 2
  fi
  models_dir=$(CDPATH= cd -- "$models_dir" && pwd)
fi

printf 'Workflow: %s\n' "$workflow_id"
if [[ "$action" != list ]]; then
  printf 'Models directory: %s\n' "$models_dir"
fi

missing_records=()
different=0
for resource_id in "${required_ids[@]}"; do
  record=''
  while IFS= read -r line; do
    if [[ "${line%%$'\t'*}" == "$resource_id" ]]; then
      record=$line
      break
    fi
  done < "$catalog"
  if [[ -z "$record" ]]; then
    printf 'Resource catalog is missing: %s\n' "$resource_id" >&2
    exit 2
  fi
  IFS=$'\t' read -r listed_id relative_path size_label expected_sha download_url source_url <<< "$record"
  if [[ "$action" == list ]]; then
    printf 'Required: models/%s (%s)\n  Source: %s\n' "$relative_path" "$size_label" "$source_url"
    continue
  fi

  target="$models_dir/$relative_path"
  if [[ ! -f "$target" ]]; then
    printf 'MISSING: models/%s (%s)\n  Source: %s\n' "$relative_path" "$size_label" "$source_url"
    missing_records+=("$record")
    continue
  fi
  if [[ "$expected_sha" == '-' ]]; then
    printf 'FOUND (checksum unavailable): models/%s\n' "$relative_path"
    continue
  fi
  printf 'Checking SHA-256: models/%s\n' "$relative_path"
  actual_sha=$(shasum -a 256 -- "$target")
  actual_sha=${actual_sha%% *}
  if [[ "$actual_sha" == "$expected_sha" ]]; then
    printf 'VERIFIED: models/%s\n' "$relative_path"
  else
    printf 'DIFFERENT: models/%s\n  Expected: %s\n  Actual:   %s\n' \
      "$relative_path" "$expected_sha" "$actual_sha"
    different=$((different + 1))
  fi
done

if [[ "$action" == list ]]; then
  exit 0
fi
if (( different > 0 )); then
  printf 'Move or remove differing files yourself before retrying; this script never replaces them.\n' >&2
  exit 1
fi
if (( ${#missing_records[@]} == 0 )); then
  printf 'All listed files are present. Confirm that ComfyUI offers the models and nodes.\n'
  exit 0
fi
if [[ "$action" == check ]]; then
  printf '%d file(s) missing. Run this workflow script with --download to fetch them.\n' \
    "${#missing_records[@]}"
  exit 1
fi

printf '\nDownload %d missing file(s) into %s? [y/N] ' "${#missing_records[@]}" "$models_dir"
read -r answer
if [[ "$answer" != y && "$answer" != Y && "$answer" != yes && "$answer" != YES ]]; then
  printf 'No downloads started.\n'
  exit 1
fi

for record in "${missing_records[@]}"; do
  IFS=$'\t' read -r listed_id relative_path size_label expected_sha download_url source_url <<< "$record"
  target="$models_dir/$relative_path"
  partial="$target.pixeltje-partial"
  mkdir -p -- "$(dirname -- "$target")"
  printf '\nDownloading models/%s (%s)\nFrom: %s\n' \
    "$relative_path" "$size_label" "$source_url"
  curl --fail --location --retry 3 --retry-delay 2 \
    --proto '=https' --proto-redir '=https' \
    --continue-at - --output "$partial" "$download_url"
  if [[ ! -s "$partial" ]]; then
    printf 'The download is empty: %s\n' "$partial" >&2
    exit 1
  fi
  if [[ "$expected_sha" != '-' ]]; then
    printf 'Checking SHA-256...\n'
    actual_sha=$(shasum -a 256 -- "$partial")
    actual_sha=${actual_sha%% *}
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      printf 'Checksum differs for %s. The partial file was kept for inspection.\n' \
        "$relative_path" >&2
      exit 1
    fi
  else
    printf 'No publisher checksum is listed for this file; verify its source before use.\n'
  fi
  if [[ -e "$target" ]]; then
    printf 'The destination appeared during download; no file was replaced: %s\n' \
      "$target" >&2
    exit 1
  fi
  mv -- "$partial" "$target"
  printf 'Installed: models/%s\n' "$relative_path"
done
printf '\nDownload complete. Rescan or restart ComfyUI, then retry the workflow.\n'
